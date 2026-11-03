// SPDX-License-Identifier: GPL-3.0-or-later
// Teleprompter page of the island, after Textream (https://github.com/f/textream, MIT).

import SwiftUI

/// Edit the script, then read it right under the camera: spoken words light
/// up, the current line stays in view, and a click on any word jumps there.
struct NotchTeleprompterView: View {
    @ObservedObject var service: NotchService
    @ObservedObject private var prompter = TeleprompterService.shared

    var body: some View {
        Group {
            if prompter.isReading { reading } else { editing }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchBand(leading: { leadingControls }, trailing: { trailingControls })
    }

    // MARK: Editing

    private var editing: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(text: $prompter.script, fontSize: 13, textColor: .white,
                            textContainerInset: NSSize(width: 6, height: 6),
                            onCommandReturn: { prompter.start() }) { view in
                view.insertionPointColor = .white
            }
            if prompter.script.isEmpty {
                Text("Paste or type your script, then press ⌘↩ to start reading.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 6 + PlainTextEditor.lineFragmentPadding)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(NotchControlSurface(cornerRadius: 12, interactive: false))
    }

    // MARK: Reading

    private var reading: some View {
        let current = prompter.currentWord
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                TeleprompterFlow(spacing: prompter.fontSize * 0.3, lineSpacing: prompter.fontSize * 0.35) {
                    ForEach(Array(prompter.words.enumerated()), id: \.offset) { index, word in
                        Text(word)
                            .font(.system(size: prompter.fontSize, weight: .semibold))
                            .foregroundStyle(color(index, current: current))
                            .id(index)
                            .onTapGesture { prompter.jump(toWord: index) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 40)
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            .onChange(of: current) { _, word in
                withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(word, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = prompter.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.75))
                    .padding(6)
                    .background(.black.opacity(0.7), in: Capsule())
            }
        }
    }

    private func color(_ index: Int, current: Int) -> Color {
        if index < current { return .white.opacity(0.3) }
        if index == current { return .yellow }
        return .white
    }

    // MARK: Band

    @ViewBuilder private var leadingControls: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Mode", selection: $prompter.mode) {
                    ForEach(ListeningMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.inline)
                if prompter.mode != .wordTracking {
                    Picker("Speed", selection: $prompter.wordsPerMinute) {
                        ForEach([100.0, 120, 140, 160, 180, 200], id: \.self) { Text("\(Int($0)) words/min").tag($0) }
                    }
                }
                Picker("Text size", selection: $prompter.fontSize) {
                    ForEach([16.0, 20, 24, 28, 34], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
            } label: {
                Image(systemName: prompter.mode.icon).font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(prompter.isReading)
            .help(prompter.mode.label)
            if prompter.isReading {
                ProgressView(value: prompter.fraction)
                    .progressViewStyle(.linear)
                    .tint(.yellow)
                    .frame(width: 60)
            }
        }
    }

    @ViewBuilder private var trailingControls: some View {
        HStack(spacing: 4) {
            if prompter.isReading {
                NotchIconButton(symbol: "backward.fill", title: "Back") { prompter.nudge(words: -8) }
                NotchIconButton(symbol: prompter.isPaused ? "play.fill" : "pause.fill",
                                title: prompter.isPaused ? "Resume" : "Pause") { prompter.togglePause() }
                NotchIconButton(symbol: "stop.fill", title: "Stop") { prompter.stop() }
            } else {
                NotchIconButton(symbol: "play.fill", title: "Start reading") { prompter.start() }
                    .disabled(prompter.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// Words wrap like text, but each stays its own view so it can be scrolled to and clicked.
struct TeleprompterFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = arrange(subviews, width: width)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(arrange(subviews, width: bounds.width), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    // ponytail: lays out every word on each pass; fine for scripts of a few thousand words.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
