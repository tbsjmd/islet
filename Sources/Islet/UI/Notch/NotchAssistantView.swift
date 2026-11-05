// SPDX-License-Identifier: GPL-3.0-or-later
// The assistant's page of the island, after Atticus and Plip (MIT).

import AppKit
import SwiftUI

struct NotchAssistantView: View {
    @ObservedObject private var assistant = AssistantService.shared
    @ObservedObject private var stage = AssistantOverlay.shared
    @State private var typed = ""
    @State private var hintsShown = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if assistant.turns.isEmpty && assistant.phase != .listening { hints }
                        ForEach(assistant.turns) { turn in
                            NotchAssistantTurnView(turn: turn, newest: turn.id == assistant.turns.last?.id)
                                .id(turn.id)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                        }
                        if assistant.phase == .listening {
                            HStack(alignment: .center, spacing: 12) {
                                AssistantOrb(phase: .listening, level: assistant.level, size: 34)
                                Text(assistant.transcript.isEmpty ? "Listening…" : assistant.transcript)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(assistant.transcript.isEmpty ? .white.opacity(0.45) : .white)
                                    .contentTransition(.interpolate)
                                    .animation(.easeOut(duration: 0.18), value: assistant.transcript)
                            }
                            .id("live")
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                        }
                        if assistant.phase == .thinking {
                            HStack(spacing: 10) {
                                AssistantOrb(phase: .thinking, level: 0, acting: stage.mood == .acting, size: 24)
                                ShimmerText(text: assistant.waitingForPerson != nil ? "Your turn: click the highlighted spot."
                                            : stage.mood == .acting ? "Working on it… step \((assistant.turns.last?.stepCount ?? 0) + 1)"
                                            : (assistant.turns.last?.stepCount ?? 0) > 0 ? "Looking again…" : "Thinking…")
                                if assistant.waitingForPerson != nil {
                                    NotchPillButton(title: "Next") { assistant.waitingForPerson?() }
                                }
                            }
                            .id("live")
                            .transition(.opacity.combined(with: .offset(y: 6)))
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
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: assistant.phase)
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: assistant.turns.count)
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
        let examples = ["“What's this error on my screen?”", "“How do I export this as a PDF?” (it draws on screen)",
                        "“Explain how DNS works” (a live diagram)", "“Show me a 3D model of a jet engine”",
                        "“Reply to this email saying Thursday works” (it types, you send)",
                        "“Open Spotify” · “Volume 30” · “Dark mode on”", "“Remember I prefer aisle seats”"]
        return HStack(alignment: .top, spacing: 14) {
            AssistantOrb(phase: .idle, level: 0, size: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text("Hold ⌃ control + ⌥ option and ask out loud.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                ForEach(Array(examples.enumerated()), id: \.offset) { index, example in
                    Text(example).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                        .opacity(hintsShown ? 1 : 0).offset(x: hintsShown ? 0 : -8).blur(radius: hintsShown ? 0 : 3)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05 + Double(index) * 0.05), value: hintsShown)
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { hintsShown = true }
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
                ZStack {
                    if assistant.phase == .listening {
                        Circle().fill(AssistantOverlay.accent.opacity(0.35)).frame(width: 30, height: 30)
                            .scaleEffect(1 + assistant.level * 0.6).blur(radius: 4)
                    }
                    Image(systemName: assistant.phase == .listening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(assistant.phase == .listening ? AnyShapeStyle(Color.white)
                                         : AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.78, green: 0.72, blue: 1)], startPoint: .top, endPoint: .bottom)))
                        .symbolEffect(.bounce, value: assistant.phase == .listening)
                }
            }
            .buttonStyle(.plain)
            .help(assistant.phase == .listening ? "Send" : "Talk")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .modifier(NotchControlSurface(cornerRadius: 12, interactive: false))
        .overlay { if assistant.isBusy { AuroraBorder(cornerRadius: 12, lineWidth: 1).transition(.opacity) } }
        .animation(.easeInOut(duration: 0.3), value: assistant.isBusy)
    }

    private var leadingControls: some View {
        Menu {
            Picker("Model", selection: $assistant.model) {
                Text("Haiku · fastest").tag("haiku")
                Text("Sonnet · smarter").tag("sonnet")
                Text("Opus · most capable").tag("opus")
            }
            .pickerStyle(.inline)
            Button("Assistant Settings…") { NotchService.shared.openSettings(showing: .assistant) }
            Divider()
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
    var newest = false
    @ObservedObject private var assistant = AssistantService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                if turn.sawScreen { Image(systemName: "eye").font(.system(size: 10)) }
                Text(turn.request).font(.system(size: 12)).lineLimit(2)
            }
            .foregroundStyle(.white.opacity(0.5))
            if !turn.steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(turn.steps.suffix(6).enumerated()), id: \.offset) { _, step in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.4), Color(red: 1, green: 0.5, blue: 0.55)], startPoint: .top, endPoint: .bottom))
                            Text(step).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: turn.steps.count)
            }
            if let gate = turn.gate {
                HStack(spacing: 6) {
                    Text(gate).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    NotchPillButton(title: "Stop") { assistant.answerGate(false) }
                    NotchPillButton(title: "Do it", prominent: true) { assistant.answerGate(true) }
                }
                .padding(8)
                .modifier(NotchControlSurface(cornerRadius: 10, interactive: false))
                .overlay(AuroraBorder(cornerRadius: 10))
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            if !turn.reply.isEmpty {
                RevealText(text: turn.reply,
                           spoken: assistant.spokenText == turn.reply ? assistant.spokenRange : nil,
                           animate: newest)
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
