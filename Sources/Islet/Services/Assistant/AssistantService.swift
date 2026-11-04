// SPDX-License-Identifier: GPL-3.0-or-later
// The island's voice assistant, after Atticus (https://github.com/SaarthurR/atticus-mac, MIT)
// and Plip (https://github.com/hussainn7/plip-oss, MIT): hold Control-Option and ask out
// loud; instant commands run with no AI, everything else goes to the Claude Code the
// person already signed in to, with a look at the screen when the question is about it.

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

struct AssistantTurn: Identifiable, Equatable {
    let id = UUID()
    let request: String
    var reply = ""
    var files: [URL] = []
    var pending: [AssistantAction] = []
    var sawScreen = false
}

final class AssistantService: NSObject, ObservableObject {
    static let shared = AssistantService()

    enum Phase: Equatable { case idle, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var turns: [AssistantTurn] = []
    @Published private(set) var error: String?
    @Published var speaksReplies: Bool {
        didSet { UserDefaults.standard.set(speaksReplies, forKey: "assistantSpeaks") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "assistantModel") }
    }

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var brain: Process?
    private var monitors: [Any] = []
    private var holdWork: DispatchWorkItem?
    private var heldByHotkey = false
    private var lastWasVoice = false

    private override init() {
        let defaults = UserDefaults.standard
        speaksReplies = defaults.object(forKey: "assistantSpeaks") as? Bool ?? true
        model = defaults.string(forKey: "assistantModel") ?? "haiku"
        super.init()
        synthesizer.delegate = self
    }

    var isBusy: Bool { phase != .idle }

    // MARK: Hotkey

    /// Hold Control and Option together, alone, to talk; let go to send.
    /// Any other key or a click while they are down is someone's shortcut, so it cancels.
    func startHotkey() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] event in self?.modifiersChanged(event.modifierFlags) }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.holdWork?.cancel(); self?.holdWork = nil }
        // A click with the keys down is a modifier-drag, such as Window Layout's.
        [NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
         NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: keys)]
            .compactMap { $0 }.forEach { monitors.append($0) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) {
            monitors.append(local)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        if held == [.control, .option] {
            guard holdWork == nil, !heldByHotkey else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.holdWork = nil
                self.heldByHotkey = true
                if self.phase == .speaking || self.phase == .thinking { self.stop() }
                self.listen()
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            holdWork?.cancel()
            holdWork = nil
            if heldByHotkey {
                heldByHotkey = false
                finishListening()
            }
        }
    }

    // MARK: Listening

    func listen() {
        guard phase == .idle || phase == .speaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        error = nil
        transcript = ""
        NotchService.shared.open(.assistant, takeFocus: false)
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.error = "Turn on Speech Recognition for Islet in System Settings → Privacy & Security."
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.error = "Turn on the microphone for Islet in System Settings → Privacy & Security."
                            return
                        }
                        self.beginRecognition()
                    }
                }
            }
        }
    }

    private func beginRecognition() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognition isn't available right now."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Audio stays on the Mac, as both originals promise.
        if speechRecognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            self.error = "The microphone didn't start."
            return
        }
        phase = .listening
        task = speechRecognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            DispatchQueue.main.async { self?.transcript = result.bestTranscription.formattedString }
        }
    }

    /// Ends listening and asks what was heard. A press without words just closes.
    func finishListening() {
        guard phase == .listening else { return }
        stopAudio()
        phase = .idle
        // The final words land a moment after the audio stops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.task?.finish()
            self.task = nil
            let heard = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty else { return }
            self.ask(heard, byVoice: true)
        }
    }

    private func stopAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
    }

    /// Stops listening, thinking and talking.
    func stop() {
        stopAudio()
        task?.cancel(); task = nil
        brain?.terminate(); brain = nil
        synthesizer.stopSpeaking(at: .immediate)
        phase = .idle
    }

    // MARK: Asking

    func ask(_ text: String, byVoice: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastWasVoice = byVoice
        error = nil
        transcript = ""
        var turn = AssistantTurn(request: text)
        if let instant = AssistantActions.instant(text) {
            let action = AssistantAction(kind: instant)
            if action.needsConfirmation {
                turn.reply = "\(action.summary)?"
                turn.pending = [action]
            } else {
                let result = AssistantActions.run(instant)
                turn.reply = result.message
                turn.files = result.files
            }
            turns.append(turn)
            say(turn.reply)
            return
        }
        guard let claude = Self.claudeCLI else {
            turn.reply = "I need Claude Code for that. Install it from claude.com/claude-code and sign in once; Islet uses your plan, no API key."
            turns.append(turn)
            return
        }
        turns.append(turn)
        phase = .thinking
        let id = turn.id
        let history = Array(turns.dropLast().suffix(6))
        let wantsScreen = Self.isAboutScreen(text)
        Task {
            let screenshot = wantsScreen ? await Self.screenshotPNG() : nil
            await MainActor.run {
                if let index = self.turns.firstIndex(where: { $0.id == id }) { self.turns[index].sawScreen = screenshot != nil }
                self.runBrain(claude, text: text, history: history, screenshot: screenshot, turnID: id)
            }
        }
    }

    func confirm(_ action: AssistantAction, in turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].pending.removeAll { $0.id == action.id }
        let result = AssistantActions.run(action.kind)
        turns[index].reply += (turns[index].reply.isEmpty ? "" : "\n") + result.message
        turns[index].files += result.files
    }

    func decline(_ action: AssistantAction, in turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].pending.removeAll { $0.id == action.id }
    }

    func clear() {
        stop()
        turns = []
        error = nil
    }

    // MARK: Brain

    static var claudeCLI: URL? {
        [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         NSHomeDirectory() + "/.claude/local/claude"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func isAboutScreen(_ text: String) -> Bool {
        text.range(of: #"\b(screen|this|that|these|here|window|page|tab|button|menu|icon|click|where|error|message|dialog|email|code|selected|highlighted|what am i|what's on|what is on|see|look at|read)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func systemPrompt() -> String {
        var prompt = """
        You are Islet, a voice assistant that lives in the Mac's Dynamic Island. Replies are read aloud and shown in a \
        small island, so answer in one to three short plain sentences: no markdown, no lists unless asked. \
        If a screenshot is attached it is the person's screen right now. Never claim you did something you didn't.

        \(AssistantActions.promptReference)
        """
        let facts = AssistantMemory.facts
        if !facts.isEmpty { prompt += "\n\nWhat the person asked you to remember:\n- " + facts.joined(separator: "\n- ") }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        prompt += "\n\nFrontmost app: \(front). Local time: \(Date().formatted(date: .abbreviated, time: .shortened))."
        return prompt
    }

    private func runBrain(_ claude: URL, text: String, history: [AssistantTurn], screenshot: Data?, turnID: UUID) {
        var content: [[String: Any]] = []
        if let screenshot {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                        "data": screenshot.base64EncodedString()]])
        }
        let earlier = history.map { "Person: \($0.request)\nYou: \($0.reply)" }.joined(separator: "\n")
        content.append(["type": "text", "text": (earlier.isEmpty ? "" : "Earlier in this chat:\n\(earlier)\n\n") + text])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard let line = try? JSONSerialization.data(withJSONObject: message) else { return }

        let process = Process()
        process.executableURL = claude
        // No tools, settings, MCP servers or saved sessions: the reply comes
        // back as text and actions run only through Islet's own list.
        process.arguments = ["-p", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json",
                             "--verbose", "--tools", "", "--setting-sources", "", "--no-session-persistence",
                             "--strict-mcp-config", "--disable-slash-commands", "--system-prompt", systemPrompt()]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        brain = process
        process.terminationHandler = { [weak self] _ in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let reply = Self.result(from: data)
            DispatchQueue.main.async { self?.finish(turnID: turnID, reply: reply, process: process) }
        }
        do {
            try process.run()
            input.fileHandleForWriting.write(line + Data("\n".utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            finish(turnID: turnID, reply: nil, process: process)
        }
    }

    /// The final `result` event of Claude Code's stream.
    static func result(from data: Data) -> String? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["type"] as? String == "result" else { continue }
            if event["is_error"] as? Bool == true { return nil }
            return event["result"] as? String
        }
        return nil
    }

    private func finish(turnID: UUID, reply: String?, process: Process) {
        guard brain === process else { return }   // stopped or replaced
        brain = nil
        phase = .idle
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        guard let reply else {
            turns[index].reply = "Claude Code didn't answer. Open Terminal and run claude once to sign in."
            return
        }
        let parsed = AssistantActions.parse(reply: reply)
        turns[index].reply = parsed.text
        for kind in parsed.actions {
            let action = AssistantAction(kind: kind)
            if action.needsConfirmation {
                turns[index].pending.append(action)
            } else {
                let result = AssistantActions.run(kind)
                turns[index].files += result.files
                if turns[index].reply.isEmpty { turns[index].reply = result.message }
            }
        }
        say(turns[index].reply)
    }

    // MARK: Screen and voice

    /// The display under the pointer, scaled down: enough to read, cheap to send.
    static func screenshotPNG() async -> Data? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let image = await ScreenshotCaptureEngine.captureDisplay(CGDirectDisplayID(number.uint32Value),
                                                                     includePointer: true, hideIsletWindows: true,
                                                                     protectedWindowIDs: [])
        else { return nil }
        let scale = min(1, 1600 / CGFloat(max(image.width, 1)))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func say(_ text: String) {
        guard speaksReplies, lastWasVoice, !text.isEmpty else { return }
        phase = .speaking
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
}

extension AssistantService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.phase == .speaking { self.phase = .idle } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.phase == .speaking { self.phase = .idle } }
    }
}
