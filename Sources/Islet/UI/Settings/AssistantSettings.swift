// SPDX-License-Identifier: GPL-3.0-or-later
// The Assistant's settings, after Plip's and Atticus's: which model answers, how you
// talk to it and how it talks back, what it may see and do, and what it remembers.

import AVFoundation
import Speech
import SwiftUI

struct AssistantSettingsControls: View {
    @ObservedObject private var assistant = AssistantService.shared
    @State private var facts = AssistantMemory.facts
    @State private var anthropicKey = ""
    @State private var serverKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            brain
            Divider()
            voiceIn
            Divider()
            voiceOut
            Divider()
            screenAndSafety
            Divider()
            memory
        }
        .toggleStyle(TrailingSwitchToggleStyle())
        .onAppear {
            assistant.refreshConnection()
            facts = AssistantMemory.facts
            anthropicKey = assistant.anthropicKey
            serverKey = assistant.serverKey
        }
    }

    // MARK: Brain

    private var brain: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Brain", "Instant commands never use AI. Everything else goes to the model you pick here.")
            SettingsChoiceRow(symbol: "brain", title: "Answers come from", selection: $assistant.engine) {
                Text("Claude plan").tag(AssistantService.Engine.claudeCode)
                Text("API key").tag(AssistantService.Engine.anthropicAPI)
                Text("Local or custom").tag(AssistantService.Engine.customServer)
            }
            switch assistant.engine {
            case .claudeCode: claudeConnection
            case .anthropicAPI:
                secureField("Anthropic API key", text: $anthropicKey, prompt: "sk-ant-…") { assistant.anthropicKey = $0 }
                caption("Billed to your Anthropic Console account. Get a key at console.anthropic.com. It's kept in your keychain.")
            case .customServer:
                field("Server", text: $assistant.serverURL, prompt: "http://localhost:11434/v1")
                field("Model", text: $assistant.serverModel, prompt: "llama3.2-vision")
                secureField("API key (optional)", text: $serverKey, prompt: "Only if the server needs one") { assistant.serverKey = $0 }
                caption("Any OpenAI-compatible server: Ollama, LM Studio, llama.cpp or a hosted one. Pick a vision model for questions about the screen.")
            }
            if assistant.engine != .customServer {
                SettingsChoiceRow(symbol: "gauge.with.dots.needle.50percent", title: "Model", selection: $assistant.model) {
                    Text("Haiku").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                caption("Haiku is fastest and uses the least of your plan; Opus is the most capable.")
            }
            if assistant.engine == .claudeCode {
                SettingsChoiceRow(symbol: "dial.medium", title: "Effort", selection: $assistant.effort) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
            }
            SettingsRow(symbol: "text.bubble", title: "Follow-up memory",
                        caption: assistant.historyTurns == 0 ? "Each question stands alone."
                            : "Sends your last \(assistant.historyTurns) exchanges with each question.") {
                Stepper("", value: $assistant.historyTurns, in: 0...10).labelsHidden()
            }
        }
    }

    @ViewBuilder private var claudeConnection: some View {
        SettingsRow(symbol: "person.crop.circle.badge.checkmark", title: "Claude", caption: connectionCaption) {
            switch assistant.connection {
            case .checking: ProgressView().controlSize(.small)
            case .connected:
                HStack(spacing: 6) {
                    Button("Check again", action: assistant.refreshConnection)
                    Button("Sign out", action: assistant.signOut)
                }
                .controlSize(.small)
            case .notInstalled, .signedOut:
                HStack(spacing: 6) {
                    Button("Check again", action: assistant.refreshConnection).controlSize(.small)
                    Button("Connect", action: assistant.connect).buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        if case .connected = assistant.connection {} else {
            caption(assistant.connection == .notInstalled
                ? "Connect installs Claude Code in Terminal, then opens your browser to sign in with your Claude account. No API key, and it runs on your Pro or Max plan."
                : "Connect opens Terminal and then your browser to sign in with your Claude account. Come back and click Check again.")
        }
    }

    private var connectionCaption: String {
        switch assistant.connection {
        case .checking: return "Checking Claude Code…"
        case .notInstalled: return "Claude Code isn't installed."
        case .signedOut: return "Claude Code is installed but signed out."
        case .connected(let account, let plan):
            return "Connected as \(account)" + (plan.map { " · \($0) plan" } ?? "") + ". No API key needed."
        }
    }

    // MARK: Voice in

    private var voiceIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Talking to it", "Speech is recognized on your Mac; audio isn't uploaded.")
            SettingsRow(symbol: "keyboard", title: "⌃ control + ⌥ option shortcut",
                        caption: "Hold both keys alone for a moment to start listening.") {
                Toggle("", isOn: $assistant.hotkeyEnabled).labelsHidden().toggleStyle(.switch)
            }
            if assistant.hotkeyEnabled {
                SettingsChoiceRow(symbol: "hand.tap", title: "Shortcut behavior", selection: $assistant.hotkeyMode) {
                    Text("Hold to talk").tag(AssistantService.HotkeyMode.hold)
                    Text("Press to toggle").tag(AssistantService.HotkeyMode.toggle)
                }
                caption(assistant.hotkeyMode == .hold ? "Talk while holding; letting go sends."
                        : "Press once to start and again to send; pauses keep listening.")
            }
            SettingsRow(symbol: "globe", title: "Speech language") {
                Picker("", selection: $assistant.speechLocale) {
                    Text("System (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "default"))").tag("")
                    ForEach(Self.speechLocales, id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                    }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow(symbol: "bolt", title: "Instant commands",
                        caption: "Open apps, volume, dark mode, timers, search and more run without AI. They understand English.") {
                Toggle("", isOn: $assistant.instantCommands).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(symbol: "rectangle.topthird.inset.filled", title: "Open the island while listening",
                        caption: "Off: only the closed island shows Listening, Thinking and Talking.") {
                Toggle("", isOn: $assistant.opensIsland).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private static let speechLocales: [String] = SFSpeechRecognizer.supportedLocales()
        .map(\.identifier)
        .sorted { (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1) }

    // MARK: Voice out

    private var voiceOut: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Talking back", nil)
            SettingsRow(symbol: "speaker.wave.2", title: "Read replies aloud", caption: "After questions you asked out loud.") {
                Toggle("", isOn: $assistant.speaksReplies).labelsHidden().toggleStyle(.switch)
            }
            if assistant.speaksReplies {
                SettingsRow(symbol: "person.wave.2", title: "Voice") {
                    HStack(spacing: 6) {
                        Picker("", selection: $assistant.voice) {
                            Text("System voice").tag("")
                            ForEach(AssistantService.voices, id: \.identifier) { voice in
                                Text(voice.name + (voice.quality == .premium ? " (Premium)" : voice.quality == .enhanced ? " (Enhanced)" : ""))
                                    .tag(voice.identifier)
                            }
                        }
                        .labelsHidden().fixedSize()
                        Button("Play", action: assistant.preview).controlSize(.small)
                    }
                }
                SettingsRow(symbol: "hare", title: "Speaking rate") {
                    Slider(value: $assistant.speechRate, in: 0.35...0.65).frame(width: 160)
                }
                caption("More natural voices: System Settings → Accessibility → Spoken Content → System voice → Manage Voices.")
            }
        }
    }

    // MARK: Screen and safety

    private var screenAndSafety: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Screen and safety", "It can only run Islet's own short list of actions, never commands or scripts.")
            SettingsChoiceRow(symbol: "eye", title: "Look at the screen", selection: $assistant.screenMode) {
                Text("When asked").tag(AssistantService.ScreenMode.automatic)
                Text("Always").tag(AssistantService.ScreenMode.always)
                Text("Never").tag(AssistantService.ScreenMode.never)
            }
            caption(screenCaption)
            if assistant.screenMode != .never, !CGPreflightScreenCaptureAccess() {
                HStack(spacing: 8) {
                    caption("Needs Screen Recording permission.")
                    Button("Allow") { CGRequestScreenCaptureAccess() }.controlSize(.small)
                }
            }
            SettingsRow(symbol: "hand.raised", title: "Let it take actions",
                        caption: "Open apps and links, search, set volume, appearance and timers, find files, run Shortcuts and add reminders.") {
                Toggle("", isOn: $assistant.actionsEnabled).labelsHidden().toggleStyle(.switch)
            }
            if assistant.actionsEnabled {
                SettingsChoiceRow(symbol: "checkmark.shield", title: "Ask before", selection: $assistant.confirmsEveryAction) {
                    Text("Risky actions").tag(false)
                    Text("Every action").tag(true)
                }
                caption(assistant.confirmsEveryAction ? "Every action waits for your Do it."
                        : "Quitting apps, running Shortcuts, adding reminders and opening programs wait for your Do it.")
            }
        }
    }

    private var screenCaption: String {
        switch assistant.screenMode {
        case .automatic: return "Attaches a picture of your screen only to questions about it, like “what's this error?”"
        case .always: return "Every AI question includes a picture of the screen your pointer is on."
        case .never: return "No screenshots are ever sent."
        }
    }

    // MARK: Memory

    private var memory: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Memory", nil)
            SettingsRow(symbol: "brain.head.profile", title: "Remember what I tell it",
                        caption: "Say “remember…” and it's included with every question after that.") {
                Toggle("", isOn: $assistant.remembers).labelsHidden().toggleStyle(.switch)
            }
            if facts.isEmpty {
                caption("Nothing remembered yet.")
            } else {
                ForEach(facts, id: \.self) { fact in
                    HStack {
                        Text(fact).font(.callout).lineLimit(2)
                        Spacer()
                        Button { AssistantMemory.remove(fact); facts = AssistantMemory.facts } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget")
                    }
                    .padding(.leading, settingsRowTextInset)
                }
                Button("Forget everything") {
                    facts.forEach(AssistantMemory.remove)
                    facts = []
                }
                .controlSize(.small)
                .padding(.leading, settingsRowTextInset)
            }
        }
    }

    // MARK: Pieces

    private func heading(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, settingsRowTextInset)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        SettingsRow(symbol: title == "Model" ? "cpu" : "server.rack", title: title) {
            TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).frame(width: 240)
        }
    }

    private func secureField(_ title: String, text: Binding<String>, prompt: String,
                             save: @escaping (String) -> Void) -> some View {
        SettingsRow(symbol: "key", title: title) {
            SecureField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit { save(text.wrappedValue) }
                .onChange(of: text.wrappedValue) { _, value in save(value) }
        }
    }
}
