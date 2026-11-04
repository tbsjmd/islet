// SPDX-License-Identifier: GPL-3.0-or-later
// The island's voice assistant, after Atticus (https://github.com/SaarthurR/atticus-mac, MIT)
// and Plip (https://github.com/hussainn7/plip-oss, MIT): hold Control-Option and ask out
// loud; instant commands run with no AI, everything else goes to the Claude Code the
// person already signed in to (or an API key, or a local model server), with a look at
// the screen when the question is about it.

import AppKit
import AVFoundation
import Combine
import Foundation
import Security
import Speech

struct AssistantTurn: Identifiable, Equatable {
    let id = UUID()
    let request: String
    var reply = ""
    var files: [URL] = []
    var pending: [AssistantAction] = []
    var sawScreen = false
}

/// A setting kept in UserDefaults under `assistant.<name>`.
@propertyWrapper
struct AssistantPreference<Value> {
    let key: String
    let fallback: Value
    init(wrappedValue: Value, _ name: String) { key = "assistant." + name; fallback = wrappedValue }
    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? fallback }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AssistantService: NSObject, ObservableObject {
    static let shared = AssistantService()

    enum Phase: Equatable { case idle, listening, thinking, speaking }
    enum Engine: String, CaseIterable, Identifiable { case claudeCode, anthropicAPI, customServer; var id: String { rawValue } }
    enum ScreenMode: String, CaseIterable, Identifiable { case automatic, always, never; var id: String { rawValue } }
    enum HotkeyMode: String, CaseIterable, Identifiable { case hold, toggle; var id: String { rawValue } }
    enum Connection: Equatable {
        case checking, notInstalled, signedOut
        /// The account Claude Code is signed in with, as it reports it.
        case connected(account: String, plan: String?)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var turns: [AssistantTurn] = []
    @Published private(set) var error: String?
    @Published private(set) var connection: Connection = .checking

    // MARK: Settings, after Plip's and Atticus's

    // Brain
    @AssistantPreference("engine") private var engineRaw = Engine.claudeCode.rawValue
    @AssistantPreference("model") private var storedModel = "haiku"
    @AssistantPreference("effort") private var storedEffort = "low"
    @AssistantPreference("history") private var storedHistory = 6
    @AssistantPreference("serverURL") private var storedServerURL = "http://localhost:11434/v1"
    @AssistantPreference("serverModel") private var storedServerModel = ""
    // Voice in
    @AssistantPreference("hotkey") private var storedHotkey = true
    @AssistantPreference("hotkeyMode") private var hotkeyModeRaw = HotkeyMode.hold.rawValue
    @AssistantPreference("speechLocale") private var storedSpeechLocale = ""
    @AssistantPreference("instant") private var storedInstant = true
    @AssistantPreference("opensIsland") private var storedOpensIsland = true
    // Voice out
    @AssistantPreference("speaks") private var storedSpeaks = true
    @AssistantPreference("voice") private var storedVoice = ""
    @AssistantPreference("rate") private var storedRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    // Screen and safety
    @AssistantPreference("screen") private var screenRaw = ScreenMode.automatic.rawValue
    @AssistantPreference("actions") private var storedActions = true
    @AssistantPreference("confirmAll") private var storedConfirmAll = false
    @AssistantPreference("memory") private var storedMemory = true

    var engine: Engine {
        get { Engine(rawValue: engineRaw) ?? .claudeCode }
        set { objectWillChange.send(); engineRaw = newValue.rawValue; refreshConnection() }
    }
    var model: String { get { storedModel } set { objectWillChange.send(); storedModel = newValue } }
    var effort: String { get { storedEffort } set { objectWillChange.send(); storedEffort = newValue } }
    var historyTurns: Int { get { storedHistory } set { objectWillChange.send(); storedHistory = max(0, min(10, newValue)) } }
    var serverURL: String { get { storedServerURL } set { objectWillChange.send(); storedServerURL = newValue } }
    var serverModel: String { get { storedServerModel } set { objectWillChange.send(); storedServerModel = newValue } }
    var hotkeyEnabled: Bool { get { storedHotkey } set { objectWillChange.send(); storedHotkey = newValue } }
    var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: hotkeyModeRaw) ?? .hold }
        set { objectWillChange.send(); hotkeyModeRaw = newValue.rawValue }
    }
    /// Empty follows the system language.
    var speechLocale: String { get { storedSpeechLocale } set { objectWillChange.send(); storedSpeechLocale = newValue } }
    var instantCommands: Bool { get { storedInstant } set { objectWillChange.send(); storedInstant = newValue } }
    var opensIsland: Bool { get { storedOpensIsland } set { objectWillChange.send(); storedOpensIsland = newValue } }
    var speaksReplies: Bool { get { storedSpeaks } set { objectWillChange.send(); storedSpeaks = newValue } }
    /// Empty uses the system voice for the speech language.
    var voice: String { get { storedVoice } set { objectWillChange.send(); storedVoice = newValue } }
    var speechRate: Double { get { storedRate } set { objectWillChange.send(); storedRate = newValue } }
    var screenMode: ScreenMode {
        get { ScreenMode(rawValue: screenRaw) ?? .automatic }
        set { objectWillChange.send(); screenRaw = newValue.rawValue }
    }
    var actionsEnabled: Bool { get { storedActions } set { objectWillChange.send(); storedActions = newValue } }
    var confirmsEveryAction: Bool { get { storedConfirmAll } set { objectWillChange.send(); storedConfirmAll = newValue } }
    var remembers: Bool { get { storedMemory } set { objectWillChange.send(); storedMemory = newValue } }

    var anthropicKey: String {
        get { Keychain.read("anthropic") }
        set { objectWillChange.send(); Keychain.write("anthropic", newValue) }
    }
    var serverKey: String {
        get { Keychain.read("server") }
        set { objectWillChange.send(); Keychain.write("server", newValue) }
    }

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var brain: Process?
    private var brainTask: URLSessionTask?
    /// Changes whenever a request is started or stopped, so a late answer is dropped.
    private var brainToken = UUID()
    private var monitors: [Any] = []
    private var holdWork: DispatchWorkItem?
    private var heldByHotkey = false
    private var lastWasVoice = false

    private override init() {
        // Settings from the first build of the Assistant.
        let defaults = UserDefaults.standard
        if let old = defaults.object(forKey: "assistantSpeaks") as? Bool { defaults.set(old, forKey: "assistant.speaks"); defaults.removeObject(forKey: "assistantSpeaks") }
        if let old = defaults.string(forKey: "assistantModel") { defaults.set(old, forKey: "assistant.model"); defaults.removeObject(forKey: "assistantModel") }
        super.init()
        synthesizer.delegate = self
    }

    var isBusy: Bool { phase != .idle }

    // MARK: Hotkey

    /// Hold Control and Option together, alone, to talk. In hold mode letting
    /// go sends; in toggle mode the next press sends. Any other key or a click
    /// while they are down is someone's shortcut, so it cancels.
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
        refreshConnection()
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard hotkeyEnabled || heldByHotkey else { return }
        let held = flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        if held == [.control, .option] {
            guard holdWork == nil, !heldByHotkey else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.holdWork = nil
                if self.hotkeyMode == .toggle, self.phase == .listening {
                    self.finishListening()
                    return
                }
                self.heldByHotkey = self.hotkeyMode == .hold
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
        if opensIsland { NotchService.shared.open(.assistant, takeFocus: false) }
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
        let locale = speechLocale.isEmpty ? Locale.current : Locale(identifier: speechLocale)
        guard let speechRecognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              speechRecognizer.isAvailable else {
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
        brainToken = UUID()
        brain?.terminate(); brain = nil
        brainTask?.cancel(); brainTask = nil
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
        if instantCommands, let instant = AssistantActions.instant(text), allows(instant) {
            let action = AssistantAction(kind: instant)
            if needsConfirmation(action) {
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
        if let problem = brainProblem {
            turn.reply = problem
            turns.append(turn)
            return
        }
        turns.append(turn)
        phase = .thinking
        let id = turn.id
        let history = Array(turns.dropLast().suffix(historyTurns))
        let wantsScreen = screenMode == .always || (screenMode == .automatic && Self.isAboutScreen(text))
        let token = UUID()
        brainToken = token
        Task {
            let screenshot = wantsScreen ? await Self.screenshotPNG() : nil
            await MainActor.run {
                guard self.brainToken == token else { return }
                if let index = self.turns.firstIndex(where: { $0.id == id }) { self.turns[index].sawScreen = screenshot != nil }
                self.think(text: text, history: history, screenshot: screenshot, turnID: id, token: token)
            }
        }
    }

    private func allows(_ kind: AssistantAction.Kind) -> Bool {
        if case .remember = kind { return remembers }
        return actionsEnabled
    }

    private func needsConfirmation(_ action: AssistantAction) -> Bool {
        if case .remember = action.kind { return false }
        return confirmsEveryAction || action.needsConfirmation
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

    // MARK: Connection

    static var claudeCLI: URL? {
        [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         NSHomeDirectory() + "/.claude/local/claude"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Why a question can't reach a model right now, in words for the island.
    private var brainProblem: String? {
        switch engine {
        case .claudeCode:
            switch connection {
            case .notInstalled, .signedOut:
                return "Connect Claude in Settings → Dynamic Island → Assistant to answer that. It uses your Claude plan, no API key."
            default: return nil
            }
        case .anthropicAPI:
            return anthropicKey.isEmpty ? "Add your Anthropic API key in Settings → Dynamic Island → Assistant." : nil
        case .customServer:
            return URL(string: serverURL)?.host == nil || serverModel.isEmpty
                ? "Set the server address and model in Settings → Dynamic Island → Assistant." : nil
        }
    }

    /// An API key in the environment makes Claude Code bill it instead of
    /// the signed-in plan, which is the point of going through Claude Code.
    static func useClaudePlan(_ environment: inout [String: String]) {
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] {
            environment[key] = nil
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
    }

    /// Asks Claude Code who it is signed in as.
    func refreshConnection() {
        guard let claude = Self.claudeCLI else { connection = .notInstalled; return }
        if case .connected = connection {} else { connection = .checking }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = claude
            process.arguments = ["auth", "status"]
            var environment = ProcessInfo.processInfo.environment
            Self.useClaudePlan(&environment)
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var state = Connection.signedOut
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   status["loggedIn"] as? Bool == true {
                    state = .connected(account: status["email"] as? String ?? "Claude account",
                                       plan: (status["subscriptionType"] as? String)?.capitalized)
                }
            }
            DispatchQueue.main.async { self.connection = state }
        }
    }

    /// Installs Claude Code if needed and signs in, in a Terminal window the
    /// person can watch; sign-in finishes in the browser. Plip's Connect button.
    func connect() {
        let claude = Self.claudeCLI.map { "'" + $0.path + "'" }
        let command = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; "
            + (claude.map { "\($0) auth login" }
               ?? "curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude auth login")
        let script = "tell application \"Terminal\"\nactivate\ndo script \(AssistantActions.quoted(command))\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) }
    }

    func signOut() {
        guard let claude = Self.claudeCLI else { return }
        let process = Process()
        process.executableURL = claude
        process.arguments = ["auth", "logout"]
        var environment = ProcessInfo.processInfo.environment
        Self.useClaudePlan(&environment)
        process.environment = environment
        process.terminationHandler = { _ in DispatchQueue.main.async { self.refreshConnection() } }
        try? process.run()
    }

    // MARK: Brains

    static func isAboutScreen(_ text: String) -> Bool {
        text.range(of: #"\b(screen|this|that|these|here|window|page|tab|button|menu|icon|click|where|error|message|dialog|email|code|selected|highlighted|what am i|what's on|what is on|see|look at|read)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func systemPrompt() -> String {
        var prompt = """
        You are Islet, a voice assistant that lives in the Mac's Dynamic Island. Replies are read aloud and shown in a \
        small island, so answer in one to three short plain sentences: no markdown, no lists unless asked. \
        If a screenshot is attached it is the person's screen right now. Never claim you did something you didn't.
        """
        if actionsEnabled { prompt += "\n\n" + AssistantActions.promptReference }
        else { prompt += "\n\nYou can't take actions on the Mac; tell the person how to do things instead." }
        let facts = remembers ? AssistantMemory.facts : []
        if !facts.isEmpty { prompt += "\n\nWhat the person asked you to remember:\n- " + facts.joined(separator: "\n- ") }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        prompt += "\n\nFrontmost app: \(front). Local time: \(Date().formatted(date: .abbreviated, time: .shortened))."
        return prompt
    }

    private func userText(_ text: String, history: [AssistantTurn]) -> String {
        let earlier = history.map { "Person: \($0.request)\nYou: \($0.reply)" }.joined(separator: "\n")
        return (earlier.isEmpty ? "" : "Earlier in this chat:\n\(earlier)\n\n") + text
    }

    /// API model IDs for the three sizes the settings offer.
    static func apiModel(_ size: String) -> String {
        switch size {
        case "opus": return "claude-opus-5-5"
        case "sonnet": return "claude-sonnet-5-5"
        default: return "claude-haiku-5-5"
        }
    }

    private func think(text: String, history: [AssistantTurn], screenshot: Data?, turnID: UUID, token: UUID) {
        let prompt = userText(text, history: history)
        let done: (String?, String?) -> Void = { [weak self] reply, failure in
            DispatchQueue.main.async { self?.finish(turnID: turnID, reply: reply, failure: failure, token: token) }
        }
        switch engine {
        case .claudeCode: askClaudeCode(prompt, screenshot: screenshot, done: done)
        case .anthropicAPI: askAnthropic(prompt, screenshot: screenshot, done: done)
        case .customServer: askServer(prompt, screenshot: screenshot, done: done)
        }
    }

    private func askClaudeCode(_ prompt: String, screenshot: Data?, done: @escaping (String?, String?) -> Void) {
        guard let claude = Self.claudeCLI else { return done(nil, "Claude Code isn't installed.") }
        var content: [[String: Any]] = []
        if let screenshot {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                        "data": screenshot.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard let line = try? JSONSerialization.data(withJSONObject: message) else { return done(nil, nil) }

        let process = Process()
        process.executableURL = claude
        // No tools, settings, MCP servers or saved sessions: the reply comes
        // back as text and actions run only through Islet's own list.
        process.arguments = ["-p", "--model", model, "--effort", effort,
                             "--input-format", "stream-json", "--output-format", "stream-json",
                             "--verbose", "--tools", "", "--setting-sources", "", "--no-session-persistence",
                             "--strict-mcp-config", "--disable-slash-commands", "--system-prompt", systemPrompt()]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        Self.useClaudePlan(&environment)
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        brain = process
        process.terminationHandler = { _ in
            let reply = Self.result(from: output.fileHandleForReading.readDataToEndOfFile())
            done(reply, reply == nil ? "Claude didn't answer. Check the connection in Settings → Dynamic Island → Assistant." : nil)
        }
        do {
            try process.run()
            input.fileHandleForWriting.write(line + Data("\n".utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            done(nil, "Claude Code didn't start.")
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

    private func askAnthropic(_ prompt: String, screenshot: Data?, done: @escaping (String?, String?) -> Void) {
        var content: [[String: Any]] = []
        if let screenshot {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                        "data": screenshot.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt])
        let body: [String: Any] = ["model": Self.apiModel(model), "max_tokens": 1024, "system": systemPrompt(),
                                   "messages": [["role": "user", "content": content]]]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(anthropicKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90
        send(request, done: done) { json in
            (json["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
    }

    /// Any OpenAI-compatible server: Ollama, LM Studio, llama.cpp or a hosted one.
    private func askServer(_ prompt: String, screenshot: Data?, done: @escaping (String?, String?) -> Void) {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else { return done(nil, "The server address isn't valid.") }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let screenshot {
            content.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + screenshot.base64EncodedString()]])
        }
        let body: [String: Any] = ["model": serverModel,
                                   "messages": [["role": "system", "content": systemPrompt()],
                                                ["role": "user", "content": content]]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !serverKey.isEmpty { request.setValue("Bearer " + serverKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180
        send(request, done: done) { json in
            ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
    }

    private func send(_ request: URLRequest, done: @escaping (String?, String?) -> Void,
                      reply: @escaping ([String: Any]) -> String?) {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if let text = reply(json), (response as? HTTPURLResponse)?.statusCode == 200 { return done(text, nil) }
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? error?.localizedDescription
                ?? "The model didn't answer (\((response as? HTTPURLResponse)?.statusCode ?? 0))."
            done(nil, message)
        }
        brainTask = task
        task.resume()
    }

    private func finish(turnID: UUID, reply: String?, failure: String?, token: UUID) {
        guard brainToken == token else { return }   // stopped or replaced
        brain = nil
        brainTask = nil
        phase = .idle
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        guard let reply else {
            turns[index].reply = failure ?? "The model didn't answer."
            if engine == .claudeCode { refreshConnection() }
            return
        }
        let parsed = AssistantActions.parse(reply: reply)
        turns[index].reply = parsed.text
        for kind in parsed.actions where allows(kind) {
            let action = AssistantAction(kind: kind)
            if needsConfirmation(action) {
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

    /// Voices for the speech language, best quality first.
    static var voices: [AVSpeechSynthesisVoice] {
        let language = String((AssistantService.shared.speechLocale.isEmpty
                               ? Locale.current.identifier : AssistantService.shared.speechLocale).prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    func preview() {
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance("Hi, I'm Islet. Hold control and option to ask me anything."))
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if !voice.isEmpty { utterance.voice = AVSpeechSynthesisVoice(identifier: voice) }
        utterance.rate = Float(speechRate)
        return utterance
    }

    private func say(_ text: String) {
        guard speaksReplies, lastWasVoice, !text.isEmpty else { return }
        phase = .speaking
        synthesizer.speak(utterance(text))
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

/// API keys live in the login keychain, never in preferences.
private enum Keychain {
    private static let service = "com.islet.assistant"

    static func read(_ account: String) -> String {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
