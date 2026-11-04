// SPDX-License-Identifier: GPL-3.0-or-later
// The assistant's page of the island, after Atticus and Plip (MIT).

import AppKit
import SwiftUI

struct NotchAssistantView: View {
    @ObservedObject private var assistant = AssistantService.shared
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if assistant.turns.isEmpty && assistant.phase != .listening { hints }
                        ForEach(assistant.turns) { turn in
                            NotchAssistantTurnView(turn: turn).id(turn.id)
                        }
                        if assistant.phase == .listening {
                            Text(assistant.transcript.isEmpty ? "Listening…" : assistant.transcript)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(assistant.transcript.isEmpty ? .white.opacity(0.45) : .white)
                                .id("live")
                        }
                        if assistant.phase == .thinking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            }
                            .id("live")
                        }
                        if let error = assistant.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .scrollIndicators(.hidden)
                .onChange(of: assistant.turns.last?.reply) { _, _ in scrollDown(proxy) }
                .onChange(of: assistant.phase) { _, _ in scrollDown(proxy) }
            }
            field
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchBand(leading: { leadingControls }, trailing: { trailingControls })
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if assistant.phase == .idle, let last = assistant.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            else { proxy.scrollTo("live", anchor: .bottom) }
        }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hold ⌃ control + ⌥ option and ask out loud.")
                .font(.system(size: 13, weight: .semibold))
            ForEach(["“What's this error on my screen?”", "“Open Spotify” · “Volume 30” · “Dark mode on”",
                     "“Find my lease PDF”", "“Remind me to call Sam in 20 minutes”",
                     "“Remember I prefer aisle seats”"], id: \.self) {
                Text($0).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white)
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField("", text: $typed, prompt: Text("Ask anything").foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit {
                    assistant.ask(typed)
                    typed = ""
                }
            Button {
                assistant.phase == .listening ? assistant.finishListening() : assistant.listen()
            } label: {
                Image(systemName: assistant.phase == .listening ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(assistant.phase == .listening ? .red : .white)
            }
            .buttonStyle(.plain)
            .help(assistant.phase == .listening ? "Send" : "Talk")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .modifier(NotchControlSurface(cornerRadius: 12, interactive: false))
    }

    private var leadingControls: some View {
        Menu {
            Picker("Model", selection: $assistant.model) {
                Text("Haiku · fastest").tag("haiku")
                Text("Sonnet · smarter").tag("sonnet")
                Text("Opus · most capable").tag("opus")
            }
            .pickerStyle(.inline)
            let facts = AssistantMemory.facts
            if !facts.isEmpty {
                Menu("Remembered") {
                    ForEach(facts, id: \.self) { fact in
                        Button("Forget “\(fact)”") { AssistantMemory.remove(fact) }
                    }
                }
            }
        } label: {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Assistant model and memory")
    }

    private var trailingControls: some View {
        HStack(spacing: 4) {
            NotchIconButton(symbol: assistant.speaksReplies ? "speaker.wave.2.fill" : "speaker.slash",
                            title: assistant.speaksReplies ? "Read replies aloud: on" : "Read replies aloud: off",
                            selected: assistant.speaksReplies) { assistant.speaksReplies.toggle() }
            if assistant.isBusy {
                NotchIconButton(symbol: "stop.fill", title: "Stop") { assistant.stop() }
            } else if !assistant.turns.isEmpty {
                NotchIconButton(symbol: "trash", title: "Clear chat") { assistant.clear() }
            }
        }
    }
}

private struct NotchAssistantTurnView: View {
    let turn: AssistantTurn
    @ObservedObject private var assistant = AssistantService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                if turn.sawScreen { Image(systemName: "eye").font(.system(size: 10)) }
                Text(turn.request).font(.system(size: 12)).lineLimit(2)
            }
            .foregroundStyle(.white.opacity(0.5))
            if !turn.reply.isEmpty {
                Text(turn.reply)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(turn.pending) { action in
                HStack(spacing: 6) {
                    Text(action.summary).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    Spacer(minLength: 4)
                    NotchPillButton(title: "Not now") { assistant.decline(action, in: turn.id) }
                    NotchPillButton(title: "Do it", prominent: true) { assistant.confirm(action, in: turn.id) }
                }
                .padding(8)
                .modifier(NotchControlSurface(cornerRadius: 10, interactive: false))
            }
            ForEach(turn.files, id: \.self) { file in
                Button {
                    if AssistantActions.runsCode(file) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    else { NSWorkspace.shared.open(file) }
                } label: {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 16, height: 16)
                        Text(file.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(file.path)
            }
        }
    }
}
