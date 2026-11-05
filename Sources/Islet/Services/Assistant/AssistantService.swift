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
    /// What the agent did, one line per action.
    var steps: [String] = []
    var stepCount = 0
    /// A question the agent is waiting on, shown with Do it and Stop.
    var gate: String?
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
    typealias Engine = AssistantEngine
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
    @AssistantPreference("geminiModel") private var storedGeminiModel = "gemini-flash-latest"
    // Agent
    @AssistantPreference("control") private var storedControl = true
    @AssistantPreference("askBeforeControl") private var storedAskBeforeControl = true
    @AssistantPreference("showsWhere") private var storedShowsWhere = true
    @AssistantPreference("maxSteps") private var storedMaxSteps = 20
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
    // Look
    @AssistantPreference("buddy") private var storedBuddy = true
    @AssistantPreference("screenGlow") private var storedGlow = true

    var engine: Engine {
        get { Engine(rawValue: engineRaw) ?? .claudeCode }
        set { objectWillChange.send(); engineRaw = newValue.rawValue; refreshConnection() }
    }
    var model: String { get { storedModel } set { objectWillChange.send(); storedModel = newValue } }
    var effort: String { get { storedEffort } set { objectWillChange.send(); storedEffort = newValue } }
    var historyTurns: Int { get { storedHistory } set { objectWillChange.send(); storedHistory = max(0, min(10, newValue)) } }
    var serverURL: String { get { storedServerURL } set { objectWillChange.send(); storedServerURL = newValue } }
    var serverModel: String { get { storedServerModel } set { objectWillChange.send(); storedServerModel = newValue } }
    var geminiModel: String { get { storedGeminiModel } set { objectWillChange.send(); storedGeminiModel = newValue } }
    var controlEnabled: Bool { get { storedControl } set { objectWillChange.send(); storedControl = newValue } }
    var asksBeforeControl: Bool { get { storedAskBeforeControl } set { objectWillChange.send(); storedAskBeforeControl = newValue } }
    var showsWhere: Bool { get { storedShowsWhere } set { objectWillChange.send(); storedShowsWhere = newValue } }
    var maxSteps: Int { get { storedMaxSteps } set { objectWillChange.send(); storedMaxSteps = max(3, min(50, newValue)) } }
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
    /// Clicky's companion cursor beside the pointer while the assistant is working.
    var buddyEnabled: Bool { get { storedBuddy } set { objectWillChange.send(); storedBuddy = newValue } }
    /// Light along the screen edges while it listens, thinks and works.
    var screenGlow: Bool { get { storedGlow } set { objectWillChange.send(); storedGlow = newValue } }

    /// Microphone loudness, 0…1, smoothed for the visuals.
    @Published private(set) var level: CGFloat = 0
    /// The words being spoken right now, so the reply can light them up.
    @Published private(set) var spokenRange: NSRange?
    @Published private(set) var spokenText = ""

    var anthropicKey: String {
        get { Keychain.read("anthropic") }
        set { objectWillChange.send(); Keychain.write("anthropic", newValue) }
    }
    var geminiKey: String {
        get { Keychain.read("gemini") }
        set { objectWillChange.send(); Keychain.write("gemini", newValue) }
    }
    var serverKey: String {
        get { Keychain.read("server") }
        set { objectWillChange.send(); Keychain.write("server", newValue) }
    }

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var agent: AssistantAgent?
    /// Changes whenever a request is started or stopped, so a late answer is dropped.
    private var brainToken = UUID()
    private var gateAnswer: ((Bool) -> Void)?
    /// Set while the agent points and waits for the person; "Next" calls it.
    @Published var waitingForPerson: (() -> Void)?
    private var monitors: [Any] = []
    private var holdWork: DispatchWorkItem?
    private var heldByHotkey = false
    private var lastWasVoice = false
    private var subscriptions: Set<AnyCancellable> = []

    private override init() {
        // Settings from the first build of the Assistant.
        let defaults = UserDefaults.standard
        if let old = defaults.object(forKey: "assistantSpeaks") as? Bool { defaults.set(old, forKey: "assistant.speaks"); defaults.removeObject(forKey: "assistantSpeaks") }
        if let old = defaults.string(forKey: "assistantModel") { defaults.set(old, forKey: "assistant.model"); defaults.removeObject(forKey: "assistantModel") }
        super.init()
        synthesizer.delegate = self
        // The screen's glow and the companion follow what the assistant is doing.
        $phase.removeDuplicates().receive(on: DispatchQueue.main).sink { phase in
            let stage = AssistantOverlay.shared
            switch phase {
            case .idle: stage.mood = .off; stage.level = 0
            case .listening: stage.mood = .listening
            case .thinking: if stage.mood != .acting { stage.mood = .thinking }
            case .speaking: stage.mood = .speaking
            }
        }.store(in: &subscriptions)
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
                // The shortcut stops a running task or a reply being read.
                if self.phase == .speaking || self.phase == .thinking { self.stop(); return }
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
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            request.append(buffer)
            // Loudness for the orb, the companion and the screen glow.
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let loud = CGFloat(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 52) / 42)))
            DispatchQueue.main.async {
                guard let self else { return }
                self.level = self.level * 0.55 + loud * 0.45
                AssistantOverlay.shared.level = self.level
            }
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
        agent?.cancel(); agent = nil
        gateAnswer?(false); gateAnswer = nil
        waitingForPerson = nil
        if let index = turns.indices.last, turns[index].gate != nil { turns[index].gate = nil }
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
        let history = turns.dropLast().suffix(historyTurns)
            .map { "Person: \($0.request)\nYou: \($0.reply)" }.joined(separator: "\n")
        let wantsScreen = screenMode == .always || (screenMode == .automatic && Self.isAboutScreen(text))
            || (screenMode != .never && Self.isTask(text))
        let token = UUID()
        brainToken = token
        let brain = AssistantBrain(config: brainConfig, system: AssistantAgent.systemPrompt(service: self))
        let agent = AssistantAgent(brain: brain, service: self, turnID: id)
        self.agent = agent
        Task { @MainActor in
            let last = await agent.run(text, history: history, wantsScreen: wantsScreen)
            guard self.brainToken == token else { return }
            self.agent = nil
            self.phase = .idle
            self.updateTurn(id) { turn in
                if turn.reply.isEmpty || last.hasPrefix("Stopped") || last.hasPrefix("I stopped") || last.hasPrefix("Okay") { turn.reply = last }
                turn.gate = nil
            }
            if case .claudeCode = self.engine, last.contains("Claude") { self.refreshConnection() }
            self.say(last)
        }
    }

    private var brainConfig: AssistantBrainConfig {
        AssistantBrainConfig(engine: engine, model: model, effort: effort, anthropicKey: anthropicKey,
                             geminiKey: geminiKey, geminiModel: geminiModel, serverURL: serverURL,
                             serverModel: serverModel, serverKey: serverKey)
    }

    /// Asks the person before the agent goes on; Stop answers no.
    @MainActor
    func ask(gate question: String, turnID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            gateAnswer?(false)
            updateTurn(turnID) { $0.gate = question }
            speak(question)
            gateAnswer = { [weak self] yes in
                self?.gateAnswer = nil
                self?.updateTurn(turnID) { $0.gate = nil }
                continuation.resume(returning: yes)
            }
        }
    }

    func answerGate(_ yes: Bool) { gateAnswer?(yes) }

    func updateTurn(_ id: UUID, _ change: (inout AssistantTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    /// Says something mid-task, when replies are read aloud.
    func speak(_ text: String) {
        guard speaksReplies, lastWasVoice, !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance(text))
    }

    /// Requests to operate the Mac, which need a look at the screen.
    static func isTask(_ text: String) -> Bool {
        text.range(of: #"^(please |can you |could you )?(click|press|type|fill|scroll|go to|navigate|select|drag|move|close|reply|write|send|book|buy|order|sign|add|change|turn|set|make|create|delete|rename|organize|tidy|show me|how do i|how can i|where)\b|\b(for me|on my screen|in this|on this)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
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
        case .geminiAPI:
            return geminiKey.isEmpty ? "Add your Gemini API key in Settings → Dynamic Island → Assistant. It's free from Google AI Studio." : nil
        case .geminiCLI:
            return AssistantBrain.geminiCLI == nil || !AssistantBrain.geminiSignedIn
                ? "Sign in with Google in Settings → Dynamic Island → Assistant." : nil
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

    /// Installs Gemini CLI if needed and starts it, which signs in with Google.
    func connectGemini() {
        let command = AssistantBrain.geminiCLI.map { "'" + $0.path + "'" }
            ?? "(command -v brew >/dev/null && brew install gemini-cli || npm install -g @google/gemini-cli) && gemini"
        let script = "tell application \"Terminal\"\nactivate\ndo script \(AssistantActions.quoted(command))\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil { NSWorkspace.shared.open(URL(string: "https://github.com/google-gemini/gemini-cli")!) }
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

    func utterance(_ text: String) -> AVSpeechUtterance {
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
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        DispatchQueue.main.async {
            self.spokenText = text
            self.spokenRange = characterRange
            // Each word gives the visuals a small beat.
            AssistantOverlay.shared.level = 0.45
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { if self.phase == .speaking { AssistantOverlay.shared.level = 0.12 } }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.spokenRange = nil }
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
