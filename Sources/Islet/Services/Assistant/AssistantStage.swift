// SPDX-License-Identifier: GPL-3.0-or-later
// Everything the assistant draws over the screen: a glow around the display edges
// while it listens, thinks and works; a companion cursor that follows the pointer and
// flies to what it explains, after Clicky (https://github.com/farzaa/clicky, MIT,
// Copyright (c) 2026 Farza); annotations that draw themselves in; and ripples where
// it clicks. Nothing here takes a click, and none of it shows in screenshots.

import AppKit
import Combine
import SwiftUI

final class AssistantOverlay: ObservableObject {
    static let shared = AssistantOverlay()

    /// A spot the agent points at, in global top-left screen coordinates.
    struct Mark: Identifiable, Equatable {
        let id = UUID()
        let rect: CGRect
        let label: String
        var flash = false
    }

    enum Mood: Equatable { case off, listening, thinking, speaking, acting }

    struct Annotation: Identifiable, Equatable {
        enum Kind: Equatable {
            case arrow(from: CGPoint, to: CGPoint)
            case ring(CGRect)
            case box(CGRect)
            case underline(CGRect)
            case highlight(CGRect)
            case text(CGPoint)
            case scribble([CGPoint])
        }
        let id = UUID()
        let kind: Kind
        let label: String
        let color: Color
        let order: Int
    }

    struct Ripple: Identifiable { let id = UUID(); let point: CGPoint }

    @Published var mood: Mood = .off
    /// Microphone loudness, 0…1, while listening.
    @Published var level: CGFloat = 0
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var ripples: [Ripple] = []
    /// The companion cursor, in global top-left coordinates.
    @Published private(set) var buddy: CGPoint = .zero
    @Published private(set) var buddyAngle: Double = -35
    @Published private(set) var buddyScale: CGFloat = 1
    @Published private(set) var flying = false
    @Published private(set) var bubble = ""

    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var follow: Timer?
    private var flight: Timer?
    private var parked: CGPoint?
    private var bubbleWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        buddy = Self.mouse()
        // The stage is on screen while there is something to show.
        Publishers.CombineLatest($mood, $annotations.map(\.isEmpty))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mood, empty in self?.sync(visible: mood != .off || !empty) }
            .store(in: &cancellables)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Agent API

    /// Points at spots: rings with labels, and the companion flies to the first.
    func show(_ marks: [Mark]) {
        annotate(marks.enumerated().map { index, mark in
            Annotation(kind: .ring(mark.rect), label: mark.label, color: Self.accent, order: index)
        })
        if let first = marks.first { fly(to: CGPoint(x: first.rect.maxX + 10, y: first.rect.maxY + 6), say: first.label) }
    }

    /// A ripple where the agent clicked, with the companion beside it.
    func flash(at point: CGPoint) {
        let ripple = Ripple(point: point)
        ripples.append(ripple)
        fly(to: CGPoint(x: point.x + 10, y: point.y + 10), say: nil, quick: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.ripples.removeAll { $0.id == ripple.id } }
    }

    func annotate(_ list: [Annotation]) {
        annotations = list
    }

    /// Lets an answer's drawings linger, then fades them, unless something new replaced them.
    func fade(after seconds: TimeInterval) {
        let shown = annotations.map(\.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.annotations.map(\.id) == shown else { return }
            withAnimation(.easeOut(duration: 0.5)) { self.clear() }
        }
    }

    func clear() {
        annotations = []
        bubble = ""
        parked = nil
        if !flying { returnToPointer() }
    }

    /// The companion's speech bubble, streamed a character at a time as Clicky does.
    func say(_ text: String, hold: TimeInterval = 6) {
        bubbleWork?.cancel()
        bubble = ""
        let characters = Array(text.prefix(140))
        var index = 0
        func next() {
            guard index < characters.count else {
                let work = DispatchWorkItem { [weak self] in self?.bubble = "" }
                bubbleWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
                return
            }
            bubble.append(characters[index]); index += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.reduceMotion ? 0 : .random(in: 0.012...0.03))) { next() }
        }
        next()
    }

    static let accent = Color(red: 0.62, green: 0.52, blue: 1)

    // MARK: Companion motion

    private static func mouse() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: CGDisplayBounds(CGMainDisplayID()).height - p.y)
    }

    private func startFollowing() {
        guard follow == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self, !self.flying, self.parked == nil else { return }
            let m = Self.mouse()
            let target = CGPoint(x: m.x + 26, y: m.y + 22)
            // A soft spring toward the pointer, Clicky's follow without its jitter.
            self.buddy = CGPoint(x: self.buddy.x + (target.x - self.buddy.x) * 0.22,
                                 y: self.buddy.y + (target.y - self.buddy.y) * 0.22)
        }
        RunLoop.main.add(timer, forMode: .common)
        follow = timer
    }

    private func stopFollowing() { follow?.invalidate(); follow = nil }

    /// Clicky's flight: a quadratic arc, facing along the curve, swelling mid-air.
    func fly(to destination: CGPoint, say text: String?, quick: Bool = false) {
        flight?.invalidate()
        parked = destination
        let start = buddy, end = destination
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 2, !Self.reduceMotion else {
            buddy = end; if let text, !text.isEmpty { say(text) }; return
        }
        let duration = quick ? min(max(distance / 1600, 0.28), 0.55) : min(max(distance / 900, 0.5), 1.2)
        let control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - min(distance * 0.22, 90))
        let began = CACurrentMediaTime()
        flying = true
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let linear = min(1, (CACurrentMediaTime() - began) / duration)
            let t = linear * linear * (3 - 2 * linear)
            let u = 1 - t
            self.buddy = CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                                 y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
            let dx = 2 * u * (control.x - start.x) + 2 * t * (end.x - control.x)
            let dy = 2 * u * (control.y - start.y) + 2 * t * (end.y - control.y)
            self.buddyAngle = atan2(dy, dx) * 180 / .pi + 90
            self.buddyScale = 1 + sin(linear * .pi) * 0.35
            if linear >= 1 {
                timer.invalidate()
                self.flying = false
                self.buddyScale = 1
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { self.buddyAngle = -35 }
                if let text, !text.isEmpty { self.say(text) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flight = timer
    }

    private func returnToPointer() {
        parked = nil
        let m = Self.mouse()
        fly(to: CGPoint(x: m.x + 26, y: m.y + 22), say: nil, quick: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.parked = nil }
    }

    // MARK: Panels

    private func sync(visible: Bool) {
        guard visible else {
            panels.values.forEach { $0.orderOut(nil) }
            stopFollowing()
            return
        }
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if panels[id] == nil { panels[id] = makePanel(for: id, screen: screen) }
        }
        panels.values.forEach { $0.orderFrontRegardless() }
        if follow == nil { buddy = CGPoint(x: Self.mouse().x + 26, y: Self.mouse().y + 22) }
        startFollowing()
    }

    private func makePanel(for display: CGDirectDisplayID, screen: NSScreen) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none   // never in the agent's own screenshots
        let bounds = CGDisplayBounds(display)
        panel.contentView = NSHostingView(rootView: AssistantStageView(stage: self, origin: bounds.origin, size: bounds.size,
                                                                       hasNotch: screen.safeAreaInsets.top > 0))
        return panel
    }
}

// MARK: - The stage

private struct AssistantStageView: View {
    @ObservedObject var stage: AssistantOverlay
    @ObservedObject private var service = AssistantService.shared
    let origin: CGPoint
    let size: CGSize
    let hasNotch: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if stage.mood != .off && service.screenGlow {
                EdgeGlow(mood: stage.mood, level: stage.level, cornerRadius: hasNotch ? 14 : 10)
                    .transition(.opacity)
            }
            ForEach(stage.annotations) { annotation in
                AnnotationView(annotation: annotation, origin: origin)
            }
            ForEach(stage.ripples) { ripple in
                RippleView().position(x: ripple.point.x - origin.x, y: ripple.point.y - origin.y)
            }
            if service.buddyEnabled, stage.mood != .off || !stage.annotations.isEmpty {
                Companion(stage: stage)
                    .position(x: stage.buddy.x - origin.x, y: stage.buddy.y - origin.y)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.45), value: stage.mood)
        .allowsHitTesting(false)
    }
}

/// The palette for each state: violet and blue to listen, a turning aurora to think,
/// warm gold while it works on the screen.
private enum Palette {
    static func colors(_ mood: AssistantOverlay.Mood) -> [Color] {
        switch mood {
        case .listening: return [.init(red: 0.45, green: 0.4, blue: 1), .init(red: 0.2, green: 0.75, blue: 1), .init(red: 0.75, green: 0.45, blue: 1)]
        case .thinking: return [.init(red: 0.98, green: 0.45, blue: 0.75), .init(red: 0.55, green: 0.45, blue: 1), .init(red: 0.2, green: 0.8, blue: 0.95), .init(red: 1, green: 0.72, blue: 0.35)]
        case .speaking: return [.init(red: 0.35, green: 0.9, blue: 0.8), .init(red: 0.45, green: 0.6, blue: 1), .init(red: 0.85, green: 0.6, blue: 1)]
        case .acting: return [.init(red: 1, green: 0.65, blue: 0.25), .init(red: 1, green: 0.4, blue: 0.5), .init(red: 1, green: 0.85, blue: 0.45)]
        case .off: return [.clear]
        }
    }
}

/// Apple Intelligence-style light along the display edges: a turning gradient in three
/// layers of bloom that breathes, and swells with the voice while listening.
private struct EdgeGlow: View {
    let mood: AssistantOverlay.Mood
    let level: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: AssistantOverlay.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let colors = Palette.colors(mood)
            let gradient = AngularGradient(colors: colors + [colors[0]], center: .center,
                                           angle: .degrees((t * (mood == .thinking ? 70 : 32)).truncatingRemainder(dividingBy: 360)))
            let breathe = 0.75 + 0.25 * sin(t * (mood == .thinking ? 3.2 : 1.6))
            let swell = 1 + level * 2.4
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape.strokeBorder(gradient, lineWidth: 22 * swell).blur(radius: 26).opacity(0.55 * breathe)
                shape.strokeBorder(gradient, lineWidth: 9 * swell).blur(radius: 9).opacity(0.8 * breathe)
                shape.strokeBorder(gradient, lineWidth: 2.5).blur(radius: 0.6).opacity(0.95)
            }
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}

/// Clicky's glowing cursor, dressed for Islet: a gem-cut pointer with a halo, and
/// beside it what the assistant is doing.
private struct Companion: View {
    @ObservedObject var stage: AssistantOverlay

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: AssistantOverlay.reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [AssistantOverlay.accent.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 26))
                        .frame(width: 52, height: 52)
                        .scaleEffect(1 + 0.12 * sin(t * 2.4) + stage.level * 0.8)
                    Pointer()
                        .fill(LinearGradient(colors: [.white, Color(red: 0.72, green: 0.66, blue: 1), Color(red: 0.36, green: 0.78, blue: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Pointer().stroke(.white.opacity(0.9), lineWidth: 0.8))
                        .frame(width: 15, height: 19)
                        .shadow(color: AssistantOverlay.accent, radius: 6 + (stage.buddyScale - 1) * 30)
                        .rotationEffect(.degrees(stage.buddyAngle))
                        .scaleEffect(stage.buddyScale)
                    if stage.mood == .thinking {
                        Circle()
                            .trim(from: 0, to: 0.72)
                            .stroke(AngularGradient(colors: Palette.colors(.thinking) + [.clear], center: .center),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 34, height: 34)
                            .rotationEffect(.degrees(t * 260))
                    }
                }
            }
            .frame(width: 52, height: 52)

            accessory
                .offset(x: 34, y: 30)
        }
        .frame(width: 52, height: 52)
    }

    @ViewBuilder private var accessory: some View {
        if !stage.bubble.isEmpty {
            Text(stage.bubble)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.82))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(LinearGradient(colors: Palette.colors(.listening), startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                        .shadow(color: AssistantOverlay.accent.opacity(0.5), radius: 14)
                )
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
        } else if stage.mood == .listening {
            WaveBars(level: stage.level)
        }
    }
}

private struct Pointer: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.32))
        p.closeSubpath()
        return p
    }
}

/// Five bars that move with the voice.
struct WaveBars: View {
    var level: CGFloat
    var count = 5
    var height: CGFloat = 16
    var color: Color = AssistantOverlay.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: AssistantOverlay.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<count, id: \.self) { i in
                    let wobble = 0.35 + 0.65 * abs(sin(t * 7 + Double(i) * 1.3))
                    Capsule()
                        .fill(LinearGradient(colors: [.white, color], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: max(3, height * (0.2 + min(1, level * 3) * CGFloat(wobble))))
                }
            }
            .frame(height: height)
            .shadow(color: color.opacity(0.8), radius: 5)
        }
    }
}

/// An annotation drawing itself in: the stroke traces, then its label slides up.
private struct AnnotationView: View {
    let annotation: AssistantOverlay.Annotation
    let origin: CGPoint
    @State private var drawn: CGFloat = 0
    @State private var labelShown = false

    var body: some View {
        let color = annotation.color
        ZStack(alignment: .topLeading) {
            shape
                .trim(from: 0, to: drawn)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .shadow(color: color, radius: 8)
                .shadow(color: color.opacity(0.6), radius: 18)
            if case .highlight(let rect) = annotation.kind {
                let r = rect.offsetBy(dx: -origin.x, dy: -origin.y)
                RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.22 * drawn))
                    .frame(width: r.width + 8, height: r.height + 6)
                    .position(x: r.midX, y: r.midY)
            }
            if !annotation.label.isEmpty {
                Text(annotation.label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.82))
                        .overlay(Capsule().strokeBorder(color.opacity(0.9), lineWidth: 1.2))
                        .shadow(color: color.opacity(0.6), radius: 12))
                    .fixedSize()
                    .position(labelPoint)
                    .opacity(labelShown ? 1 : 0)
                    .offset(y: labelShown ? 0 : 8)
                    .blur(radius: labelShown ? 0 : 4)
            }
        }
        .onAppear {
            let delay = Double(annotation.order) * 0.18
            if AssistantOverlay.reduceMotion { drawn = 1; labelShown = true; return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.75).delay(delay)) { drawn = 1 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75).delay(delay + 0.45)) { labelShown = true }
        }
    }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    private var shape: Path {
        var path = Path()
        switch annotation.kind {
        case .arrow(let from, let to):
            let a = local(from), b = local(to)
            let control = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * 0.18, y: (a.y + b.y) / 2 - (b.x - a.x) * 0.18)
            path.move(to: a)
            path.addQuadCurve(to: b, control: control)
            let angle = atan2(b.y - control.y, b.x - control.x)
            for side in [-0.5, 0.5] {
                path.move(to: b)
                path.addLine(to: CGPoint(x: b.x - 16 * cos(angle + side), y: b.y - 16 * sin(angle + side)))
            }
        case .ring(let rect):
            let r = local(rect).insetBy(dx: -12, dy: -10)
            path.addEllipse(in: r.width < 50 ? CGRect(x: r.midX - 30, y: r.midY - 30, width: 60, height: 60) : r)
        case .box(let rect):
            path.addRoundedRect(in: local(rect).insetBy(dx: -6, dy: -6), cornerSize: CGSize(width: 10, height: 10))
        case .underline(let rect):
            let r = local(rect)
            path.move(to: CGPoint(x: r.minX - 4, y: r.maxY + 5))
            path.addQuadCurve(to: CGPoint(x: r.maxX + 4, y: r.maxY + 3), control: CGPoint(x: r.midX, y: r.maxY + 10))
        case .highlight(let rect):
            let r = local(rect)
            path.move(to: CGPoint(x: r.minX, y: r.maxY + 3)); path.addLine(to: CGPoint(x: r.maxX, y: r.maxY + 3))
        case .text:
            break
        case .scribble(let points):
            guard let first = points.first else { break }
            path.move(to: local(first))
            points.dropFirst().forEach { path.addLine(to: local($0)) }
        }
        return path
    }

    private var labelPoint: CGPoint {
        switch annotation.kind {
        case .arrow(let from, _): let a = local(from); return CGPoint(x: a.x, y: a.y - 22)
        case .ring(let rect), .box(let rect):
            let r = local(rect); return CGPoint(x: r.midX, y: r.maxY + max(r.height, 40) / 2 + 22)
        case .underline(let rect), .highlight(let rect): let r = local(rect); return CGPoint(x: r.midX, y: r.maxY + 28)
        case .text(let p): return local(p)
        case .scribble(let points): return local(points.first ?? .zero).applying(.init(translationX: 0, y: -22))
        }
    }
}

/// Rings that spread from a click.
private struct RippleView: View {
    @State private var spread = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .strokeBorder(Color(red: 1, green: 0.75, blue: 0.4).opacity(spread ? 0 : 0.9), lineWidth: 2)
                    .frame(width: spread ? 90 : 10, height: spread ? 90 : 10)
                    .animation(.easeOut(duration: 0.9).delay(Double(i) * 0.12), value: spread)
            }
            Circle().fill(.white).frame(width: 7, height: 7).shadow(color: .orange, radius: 8)
                .opacity(spread ? 0 : 1).animation(.easeOut(duration: 0.6), value: spread)
        }
        .onAppear { spread = true }
    }
}
