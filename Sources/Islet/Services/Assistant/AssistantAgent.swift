// SPDX-License-Identifier: GPL-3.0-or-later
// The assistant's agent loop, after Plip (https://github.com/hussainn7/plip-oss, MIT) and
// Atticus (https://github.com/SaarthurR/atticus-mac, MIT): look at the screen, decide, act
// or point, look again, until the task is done. Steps that send, buy, delete or can't be
// undone wait for a yes; Escape or the shortcut stops it at any point.

import AppKit
import Foundation

final class AssistantAgent {
    enum Gate { case control, step(String) }

    private let brain: AssistantBrain
    private let service: AssistantService
    private let turnID: UUID
    private var cancelled = false
    private var controlApproved = false
    private var display: CGDirectDisplayID?
    private var escape: Any?
    private var clickWatch: Any?

    init(brain: AssistantBrain, service: AssistantService, turnID: UUID) {
        self.brain = brain
        self.service = service
        self.turnID = turnID
    }

    func cancel() {
        cancelled = true
        brain.close()
        DispatchQueue.main.async {
            AssistantOverlay.shared.clear()
            self.stopWatching()
        }
    }

    /// Runs the task to the end and returns what to say last.
    @MainActor
    func run(_ request: String, history: String, wantsScreen: Bool) async -> String {
        escape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { DispatchQueue.main.async { self?.service.stop() } }
        }
        defer { stopWatching(); AssistantOverlay.shared.clear() }

        var message = (history.isEmpty ? "" : "Earlier in this chat:\n\(history)\n\n") + "Request: " + request
        var lastSay = ""
        let maxSteps = service.maxSteps
        for step in 1...maxSteps {
            guard !cancelled else { return "Stopped." }
            let view = wantsScreen || step > 1 ? await AssistantHands.look(display: display) : nil
            if let view {
                display = display ?? AssistantHands.displayUnderPointer()
                service.updateTurn(turnID) { $0.sawScreen = true }
                message += "\n\nScreenshot: \(Int(view.pixelSize.width))×\(Int(view.pixelSize.height)) pixels. "
                    + "Front app: \(AssistantHands.targetApp?.localizedName ?? "none").\nElements you can use by number:\n" + view.elementMap
            } else if step == 1 {
                message += "\n\n(No screenshot with this request.)"
            }
            let reply: String
            do { reply = try await brain.send(message, image: view?.png) } catch {
                return cancelled ? "Stopped." : error.localizedDescription
            }
            guard !cancelled else { return "Stopped." }
            let plan = AssistantPlan.parse(reply)
            if !plan.say.isEmpty {
                lastSay = plan.say
                service.updateTurn(turnID) { $0.reply = plan.say }
                if !plan.done { service.speak(plan.say) }
            }
            if plan.steps.isEmpty, !plan.done, view == nil {
                // It wants to see before it acts.
                message = "Here is the screen."
                continue
            }
            var results: [String] = []
            var pointed: [AssistantOverlay.Mark] = []
            for object in plan.steps {
                guard !cancelled else { return "Stopped." }
                let outcome = await perform(object, view: view, marks: &pointed)
                results.append(outcome)
                service.updateTurn(turnID) { $0.steps.append(outcome) }
                if outcome.hasPrefix("Stopped") { return "Okay, I stopped." }
            }
            if !pointed.isEmpty {
                AssistantOverlay.shared.show(pointed)
                let followed = await waitForClick(in: pointed.map(\.rect))
                AssistantOverlay.shared.clear()
                guard !cancelled else { return "Stopped." }
                results.append(followed ? "The person clicked the spot you showed." : "The person didn't click it yet.")
            }
            if plan.done { return lastSay.isEmpty ? "Done." : lastSay }
            guard step < maxSteps else { break }
            try? await Task.sleep(for: .milliseconds(pointed.isEmpty ? 700 : 400))
            message = "Step \(step) results:\n- " + (results.isEmpty ? "nothing was done" : results.joined(separator: "\n- "))
                + "\nHere is the screen now. Continue, or finish with done: true."
            service.updateTurn(turnID) { $0.stepCount = step }
        }
        return "I stopped after \(maxSteps) steps. Ask me to keep going if it isn't finished."
    }

    private func stopWatching() {
        if let escape { NSEvent.removeMonitor(escape) }
        if let clickWatch { NSEvent.removeMonitor(clickWatch) }
        escape = nil; clickWatch = nil
    }

    /// Plip's "moves on when you've done a step": a click near a mark, or a minute.
    @MainActor
    private func waitForClick(in rects: [CGRect]) async -> Bool {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Bool) -> Void = { clicked in
                guard !finished else { return }
                finished = true
                self.service.waitingForPerson = nil
                if let watch = self.clickWatch { NSEvent.removeMonitor(watch); self.clickWatch = nil }
                continuation.resume(returning: clicked)
            }
            clickWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                let point = CGEvent(source: nil)?.location ?? .zero
                let hit = rects.contains { $0.insetBy(dx: -30, dy: -30).contains(point) }
                // Give the app a moment to react before the next look.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish(hit) }
            }
            service.waitingForPerson = { finish(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { finish(false) }
            Task { while !finished { if self.cancelled { finish(false) }; try? await Task.sleep(for: .milliseconds(200)) } }
        }
    }

    // MARK: One action

    private func point(_ object: [String: Any], view: AssistantView?) -> CGPoint? {
        if let id = object["element"] as? Int ?? (object["element"] as? String).flatMap(Int.init),
           let element = view?.elements.first(where: { $0.id == id }) {
            return CGPoint(x: element.frame.midX, y: element.frame.midY)
        }
        guard let view, let x = (object["x"] as? NSNumber)?.doubleValue, let y = (object["y"] as? NSNumber)?.doubleValue else { return nil }
        return view.screenPoint(x: x, y: y)
    }

    private func element(_ object: [String: Any], view: AssistantView?) -> AssistantElement? {
        guard let id = object["element"] as? Int ?? (object["element"] as? String).flatMap(Int.init) else { return nil }
        return view?.elements.first { $0.id == id }
    }

    private func describe(_ object: [String: Any], view: AssistantView?) -> String {
        let target = element(object, view: view).map { "“\($0.label.isEmpty ? $0.role : $0.label)”" } ?? "the spot"
        switch object["do"] as? String ?? "" {
        case "click": return "\(object["double"] as? Bool == true ? "Double-click" : object["right"] as? Bool == true ? "Right-click" : "Click") \(target)"
        case "type": return "Type “\(String((object["text"] as? String ?? "").prefix(60)))”"
        case "key": return "Press \(object["keys"] as? String ?? "")"
        case "scroll": return "Scroll \(object["direction"] as? String ?? "down")"
        case "drag": return "Drag"
        case "point": return "Show \(target)"
        case "wait": return "Wait"
        default: return AssistantActions.kind(from: object).map { AssistantAction(kind: $0).summary } ?? "Something I can't do"
        }
    }

    @MainActor
    private func perform(_ object: [String: Any], view: AssistantView?, marks: inout [AssistantOverlay.Mark]) async -> String {
        let kind = object["do"] as? String ?? ""
        let summary = describe(object, view: view)
        let controls = ["click", "type", "key", "scroll", "drag"].contains(kind)

        if kind == "point" {
            guard service.showsWhere, let at = point(object, view: view) else { return "Couldn't show that spot." }
            let rect = element(object, view: view)?.frame ?? CGRect(x: at.x - 20, y: at.y - 20, width: 40, height: 40)
            marks.append(.init(rect: rect, label: object["label"] as? String ?? ""))
            return summary
        }
        if kind == "wait" {
            try? await Task.sleep(for: .seconds(min(10, max(0.2, (object["seconds"] as? NSNumber)?.doubleValue ?? 1))))
            return "Waited."
        }
        if controls {
            guard service.controlEnabled else { return "Not allowed to control the screen; show the person instead." }
            if service.asksBeforeControl, !controlApproved {
                guard await service.ask(gate: "Let Islet use your mouse and keyboard for this task?", turnID: turnID) else { return "Stopped." }
                controlApproved = true
            }
        }
        let risky = object["confirm"] as? Bool == true || service.confirmsEveryAction
            || (kind == "key" && AssistantHands.riskyKeys(object["keys"] as? String ?? ""))
            || AssistantActions.kind(from: object).map { AssistantAction(kind: $0).needsConfirmation } == true
        if risky {
            guard await service.ask(gate: summary + "?", turnID: turnID) else { return "Stopped." }
        }
        if controls, NotchService.shared.expanded { NotchService.shared.collapse(); try? await Task.sleep(for: .milliseconds(250)) }

        do {
            switch kind {
            case "click":
                if let target = element(object, view: view), object["double"] as? Bool != true, object["right"] as? Bool != true {
                    AssistantOverlay.shared.flash(at: CGPoint(x: target.frame.midX, y: target.frame.midY))
                    try AssistantHands.press(target)
                } else if let at = point(object, view: view) {
                    AssistantOverlay.shared.flash(at: at)
                    try AssistantHands.click(at, double: object["double"] as? Bool == true, right: object["right"] as? Bool == true)
                } else { return "No spot to click." }
            case "type":
                if let target = element(object, view: view) { try AssistantHands.focus(target) }
                try AssistantHands.type(object["text"] as? String ?? "")
                if object["submit"] as? Bool == true { try AssistantHands.press(keys: "return") }
            case "key":
                try AssistantHands.press(keys: object["keys"] as? String ?? "")
            case "scroll":
                let at = point(object, view: view) ?? CGEvent(source: nil)?.location ?? .zero
                try AssistantHands.scroll(object["direction"] as? String ?? "down", at: at,
                                          amount: (object["amount"] as? NSNumber)?.doubleValue ?? 1)
            case "drag":
                guard let view, let from = object["from"] as? [NSNumber], let to = object["to"] as? [NSNumber],
                      from.count == 2, to.count == 2 else { return "No path to drag." }
                try AssistantHands.drag(from: view.screenPoint(x: from[0].doubleValue, y: from[1].doubleValue),
                                        to: view.screenPoint(x: to[0].doubleValue, y: to[1].doubleValue))
            default:
                guard let action = AssistantActions.kind(from: object) else { return "Unknown action “\(kind)”." }
                if case .remember = action, !service.remembers { return "Memory is off." }
                let result = AssistantActions.run(action)
                if !result.files.isEmpty { service.updateTurn(turnID) { $0.files += result.files } }
                return result.message
            }
        } catch {
            return "\(summary) failed: \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .milliseconds(250))
        return summary
    }

    // MARK: Prompt

    static func systemPrompt(service: AssistantService) -> String {
        var prompt = """
        You are Islet, an assistant that lives in the Mac's Dynamic Island. You can answer, show the person where things \
        are on screen, and operate the Mac for them, one step at a time.

        Every reply is ONE JSON object and nothing else:
        {"say": "what to tell the person, one or two short spoken sentences", "actions": [ ... ], "done": true or false}

        Each step you may get a screenshot and a numbered list of the front app's elements with their centres in \
        screenshot pixels. Prefer elements by number; use x/y pixels only for things not in the list.

        Screen actions:
        {"do":"click","element":12} · {"do":"click","x":640,"y":380,"double":true} · {"do":"click","element":4,"right":true}
        {"do":"type","text":"hello","element":7,"submit":true} · {"do":"key","keys":"cmd+s"} · {"do":"scroll","direction":"down","x":600,"y":500}
        {"do":"drag","from":[100,200],"to":[400,200]} · {"do":"wait","seconds":1}
        {"do":"point","element":12,"label":"Click Export"} (draws a ring there and waits for the person to click it)

        """
        prompt += AssistantActions.promptReference
        prompt += """


        How to work:
        - A plain question: answer in "say", no actions, done true.
        - "How do I…" or "where is…": show, don't do. Point at one spot per step with a short label, done false; you'll get \
        the next screen once they click it. Finish with done true.
        - "Do this for me": act. Take a few actions per step, then look again (done false) until it's finished; then done \
        true with a one-line summary. Open apps with open_app rather than clicking the Dock.
        - Add "confirm": true to any action that sends, posts, buys, pays, deletes, submits a form or can't be undone; Islet \
        asks the person first.
        - Never type passwords, card numbers or codes; ask the person to do that part.
        - If something didn't work, look at the new screen and try another way, at most twice, then explain.
        - Plain text in "say": no markdown.
        """
        if !service.controlEnabled { prompt += "\n- Screen control is off: don't click, type, key, scroll or drag. Point instead." }
        if !service.actionsEnabled { prompt += "\n- Mac actions (open_app and the rest) are off: only screen actions and pointing." }
        let facts = service.remembers ? AssistantMemory.facts : []
        if !facts.isEmpty { prompt += "\n\nWhat the person asked you to remember:\n- " + facts.joined(separator: "\n- ") }
        prompt += "\n\nLocal time: \(Date().formatted(date: .abbreviated, time: .shortened))."
        return prompt
    }
}
