// SPDX-License-Identifier: GPL-3.0-or-later
// The agent's eyes and hands. Key parsing and the front-of-screen mouse and wheel
// events are adapted from Atticus (https://github.com/SaarthurR/atticus-mac, MIT,
// Copyright (c) 2026 SaarthurR); the element map and pointing follow Plip
// (https://github.com/hussainn7/plip-oss, MIT).

import AppKit
import ApplicationServices
import SwiftUI

/// One display as the agent sees it: a scaled screenshot, and where that
/// picture sits in global (top-left origin) screen coordinates.
struct AssistantView {
    let png: Data
    let pixelSize: CGSize
    let displayBounds: CGRect
    let elements: [AssistantElement]

    /// A point in the picture, in global screen coordinates.
    func screenPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: displayBounds.minX + x / pixelSize.width * displayBounds.width,
                y: displayBounds.minY + y / pixelSize.height * displayBounds.height)
    }

    /// A screen rectangle, in the picture's pixels.
    func pixels(_ rect: CGRect) -> CGRect {
        let sx = pixelSize.width / displayBounds.width, sy = pixelSize.height / displayBounds.height
        return CGRect(x: (rect.minX - displayBounds.minX) * sx, y: (rect.minY - displayBounds.minY) * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    /// The map the model reads: one line per element, in the picture's pixels.
    var elementMap: String {
        guard !elements.isEmpty else { return "No accessible elements were found in the front window." }
        return elements.map { e in
            let r = pixels(e.frame)
            return "[\(e.id)] \(e.role) \"\(e.label)\" at \(Int(r.midX)),\(Int(r.midY)) size \(Int(r.width))x\(Int(r.height))"
                + (e.secure ? " (password field)" : "")
        }.joined(separator: "\n")
    }
}

struct AssistantElement {
    let id: Int
    let role: String
    let label: String
    let frame: CGRect
    let secure: Bool
    let element: AXUIElement
}

enum AssistantHands {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: Seeing

    /// The display under the pointer (or `display`), with the front app's elements.
    static func look(display: CGDirectDisplayID? = nil) async -> AssistantView? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let id = display ?? displayUnderPointer()
        guard let image = await ScreenshotCaptureEngine.captureDisplay(id, includePointer: true, hideIsletWindows: true,
                                                                     protectedWindowIDs: []) else { return nil }
        let scale = min(1, 1440 / CGFloat(max(image.width, 1)))
        let size = CGSize(width: (CGFloat(image.width) * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let bounds = CGDisplayBounds(id)
        return AssistantView(png: png, pixelSize: size, displayBounds: bounds, elements: elements(on: bounds))
    }

    static func displayUnderPointer() -> CGDirectDisplayID {
        let point = CGEvent(source: nil)?.location ?? .zero
        var id = CGMainDisplayID(), count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        return count > 0 ? id : CGMainDisplayID()
    }

    /// The app the person is working in: the front one, unless that is Islet.
    static var targetApp: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { return front }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !$0.isHidden
        }
    }

    private static let actionable: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXSlider", "AXTab", "AXMenuItem", "AXMenuBarItem",
        "AXCell", "AXRow", "AXDisclosureTriangle", "AXIncrementor", "AXSegmentedControl", "AXStaticText", "AXImage",
    ]

    /// A breadth-first walk of the front window and menu bar, Plip's "text map
    /// of the buttons": enough for the model to click by number, not by guess.
    static func elements(on display: CGRect, limit: Int = 140) -> [AssistantElement] {
        guard let app = targetApp else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var starts: [AXUIElement] = []
        if let window = axElement(root, kAXFocusedWindowAttribute) { starts.append(window) }
        if let bar = axElement(root, kAXMenuBarAttribute) { starts.append(bar) }
        var queue = starts, index = 0, found: [AssistantElement] = []
        let deadline = Date().addingTimeInterval(0.6)
        while index < queue.count, found.count < limit, index < 4000, Date() < deadline {
            let element = queue[index]; index += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let frame = frame(of: element)
            if actionable.contains(role), frame.width > 2, frame.height > 2, display.intersects(frame) {
                let label = name(element)
                if !label.isEmpty || role != "AXStaticText" && role != "AXImage" {
                    let subrole = attribute(element, kAXSubroleAttribute) as? String
                    found.append(AssistantElement(id: found.count + 1, role: role.replacingOccurrences(of: "AX", with: ""),
                                                  label: String(label.prefix(80)), frame: frame,
                                                  secure: subrole == "AXSecureTextField", element: element))
                }
            }
            // Menus only one level down: the bar's titles, not every item.
            if role == "AXMenuBarItem" { continue }
            queue += children(element)
        }
        return found
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func name(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
            if let text = attribute(element, key) as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        if let value = attribute(element, kAXValueAttribute) as? String,
           attribute(element, kAXSubroleAttribute) as? String != "AXSecureTextField" { return value }
        return ""
    }

    static func frame(of element: AXUIElement) -> CGRect {
        var point = CGPoint.zero, size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
        if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return CGRect(origin: point, size: size)
    }

    /// The focused text field is a password field.
    static var typingIntoSecureField: Bool {
        let system = AXUIElementCreateSystemWide()
        guard let focused = axElement(system, kAXFocusedUIElementAttribute) else { return false }
        return attribute(focused, kAXSubroleAttribute) as? String == "AXSecureTextField"
    }

    // MARK: Hands

    /// Presses an element through accessibility when it can, else clicks its centre.
    static func press(_ element: AssistantElement) throws {
        guard !element.secure else { throw Failure(message: "That's a password field; I won't touch it.") }
        if ["Button", "Link", "MenuItem", "MenuBarItem", "CheckBox", "RadioButton", "PopUpButton", "MenuButton", "Tab"].contains(element.role),
           AXUIElementPerformAction(element.element, kAXPressAction as CFString) == .success { return }
        try click(CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    /// Focuses a text element before typing into it.
    static func focus(_ element: AssistantElement) throws {
        guard !element.secure else { throw Failure(message: "That's a password field; I won't type in it.") }
        if AXUIElementSetAttributeValue(element.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success {
            try click(CGPoint(x: element.frame.midX, y: element.frame.midY))
        }
        usleep(120_000)
    }

    /// A real click at a global point, as Atticus's front-of-screen mouse does.
    static func click(_ point: CGPoint, double: Bool = false, right: Bool = false) throws {
        guard let source = CGEventSource(stateID: .privateState) else { throw Failure(message: "Couldn't create a mouse event.") }
        let button: CGMouseButton = right ? .right : .left
        func post(_ type: CGEventType, _ count: Int) throws {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            else { throw Failure(message: "Couldn't create a mouse event.") }
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            event.post(tap: .cghidEventTap)
        }
        try post(.mouseMoved, 0)
        usleep(40_000)
        for count in 1...(double ? 2 : 1) {
            try post(right ? .rightMouseDown : .leftMouseDown, count)
            usleep(30_000)
            try post(right ? .rightMouseUp : .leftMouseUp, count)
            usleep(60_000)
        }
    }

    static func drag(from: CGPoint, to: CGPoint) throws {
        guard let source = CGEventSource(stateID: .privateState) else { throw Failure(message: "Couldn't create a mouse event.") }
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, from); usleep(40_000)
        post(.leftMouseDown, from); usleep(60_000)
        for i in 1...20 {
            let t = Double(i) / 20
            post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            usleep(10_000)
        }
        post(.leftMouseUp, to)
    }

    static func scroll(_ direction: String, at point: CGPoint, amount: Double = 1) throws {
        guard let source = CGEventSource(stateID: .privateState) else { throw Failure(message: "Couldn't create a scroll event.") }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
        let vertical = ["down", "up"].contains(direction)
        let pixels = Int32(((["down", "right"].contains(direction) ? -400.0 : 400.0) * max(0.2, min(amount, 5))).rounded())
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: vertical ? pixels : 0, wheel2: vertical ? 0 : pixels, wheel3: 0)
        else { throw Failure(message: "Couldn't create a scroll event.") }
        event.post(tap: .cghidEventTap)
    }

    /// Types text into whatever has keyboard focus, never into a password field.
    static func type(_ text: String) throws {
        guard !typingIntoSecureField else { throw Failure(message: "The cursor is in a password field; I won't type there.") }
        guard let source = CGEventSource(stateID: .privateState) else { throw Failure(message: "Couldn't create a key event.") }
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event.post(tap: .cghidEventTap)
            }
            usleep(12_000)
            start += 16
        }
    }

    static func press(keys text: String) throws {
        let (code, flags) = try keys(text)
        guard let source = CGEventSource(stateID: .privateState) else { throw Failure(message: "Couldn't create a key event.") }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    /// "cmd+shift+s" → key code and modifiers. From Atticus.
    static func keys(_ text: String) throws -> (CGKeyCode, CGEventFlags) {
        let input = text.lowercased().replacingOccurrences(of: " ", with: "")
        var parts = (input.hasSuffix("++") ? String(input.dropLast()) + "=" : input).split(separator: "+").map(String.init)
        var flags: CGEventFlags = []
        guard let key = parts.popLast(), !key.isEmpty else { throw Failure(message: "Unknown key.") }
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw Failure(message: "Unknown modifier: \(part)")
            }
        }
        let names: [String: CGKeyCode] = ["return": 36, "enter": 36, "esc": 53, "escape": 53, "tab": 48, "space": 49, "delete": 51,
            "backspace": 51, "forwarddelete": 117, "pagedown": 121, "pageup": 116, "home": 115, "end": 119, "left": 123, "right": 124,
            "down": 125, "up": 126, "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39,
            "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, "f1": 122, "f2": 120, "f3": 99,
            "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111]
        guard let code = names[["plus": "=", "minus": "-"][key] ?? key] else { throw Failure(message: "Unknown key: \(key)") }
        return (code, flags)
    }

    /// Keys that quit, close, delete or force-quit: always confirmed. From Atticus.
    static func riskyKeys(_ text: String) -> Bool {
        guard let (code, flags) = try? keys(text) else { return false }
        return (flags.contains(.maskCommand) && [12, 13, 36, 51, 117].contains(code))
            || (flags.contains([.maskCommand, .maskShift]) && code == 2)
            || (flags.contains([.maskCommand, .maskAlternate]) && code == 53)
    }
}
