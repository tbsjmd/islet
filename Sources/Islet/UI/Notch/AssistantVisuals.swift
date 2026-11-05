// SPDX-License-Identifier: GPL-3.0-or-later
// The assistant's look in the island: a living orb that breathes at rest, swells with
// your voice, swirls while it thinks and beats with each spoken word; replies that
// arrive a word at a time out of a blur; and text that shimmers while it works.

import SwiftUI

/// Liquid light in a glass bead. Three coloured lobes orbit and blend; rings turn
/// while it thinks; sparks circle while it works on the screen.
struct AssistantOrb: View {
    var phase: AssistantService.Phase
    var level: CGFloat
    var acting = false
    var size: CGFloat = 44

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: AssistantOverlay.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let colors = palette
            let speed: Double = phase == .thinking ? 2.4 : phase == .listening ? 1.4 : 0.6
            let swell = 1 + level * (phase == .listening ? 0.55 : 0.3) + (phase == .idle ? 0.04 * sin(t * 1.2) : 0)
            Canvas { canvas, box in
                let centre = CGPoint(x: box.width / 2, y: box.height / 2)
                let r = size * 0.36 * swell
                canvas.addFilter(.blur(radius: size * 0.09))
                canvas.blendMode = .plusLighter
                for (i, color) in colors.enumerated() {
                    let a = t * speed + Double(i) * 2.1
                    let wobble = r * (0.32 + 0.12 * sin(t * 1.7 + Double(i)))
                    let p = CGPoint(x: centre.x + cos(a) * wobble, y: centre.y + sin(a * 1.13) * wobble)
                    let lobe = r * (0.95 + 0.15 * sin(t * 2.3 + Double(i) * 1.4))
                    canvas.fill(Path(ellipseIn: CGRect(x: p.x - lobe, y: p.y - lobe, width: lobe * 2, height: lobe * 2)),
                                with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: p, startRadius: 0, endRadius: lobe))
                }
            }
            .frame(width: size * 1.6, height: size * 1.6)
            .overlay {
                // The glass: a bright rim and a highlight, so it reads as a bead, not a smudge.
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .frame(width: size * 0.78 * swell, height: size * 0.78 * swell)
                    .blendMode(.plusLighter)
                Ellipse().fill(.white.opacity(0.35)).frame(width: size * 0.22, height: size * 0.12)
                    .offset(x: -size * 0.13, y: -size * 0.2).blur(radius: 1.5)
                if phase == .thinking {
                    ForEach(0..<2, id: \.self) { ring in
                        Circle()
                            .trim(from: 0, to: ring == 0 ? 0.62 : 0.35)
                            .stroke(AngularGradient(colors: colors + [.clear], center: .center), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .frame(width: size * (1.02 + Double(ring) * 0.22), height: size * (1.02 + Double(ring) * 0.22))
                            .rotationEffect(.radians(t * (ring == 0 ? 3.1 : -2.2)))
                    }
                }
                if acting {
                    ForEach(0..<4, id: \.self) { i in
                        let a = t * 2.6 + Double(i) * .pi / 2
                        Circle().fill(.white).frame(width: 3, height: 3)
                            .shadow(color: .orange, radius: 4)
                            .offset(x: cos(a) * size * 0.62, y: sin(a) * size * 0.62)
                    }
                }
            }
            .shadow(color: colors[0].opacity(0.55), radius: size * 0.3)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .accessibilityHidden(true)
    }

    private var palette: [Color] {
        if acting { return [Color(red: 1, green: 0.62, blue: 0.25), Color(red: 1, green: 0.4, blue: 0.55), Color(red: 1, green: 0.85, blue: 0.45)] }
        switch phase {
        case .listening: return [Color(red: 0.42, green: 0.38, blue: 1), Color(red: 0.2, green: 0.78, blue: 1), Color(red: 0.78, green: 0.45, blue: 1)]
        case .thinking: return [Color(red: 1, green: 0.45, blue: 0.78), Color(red: 0.55, green: 0.45, blue: 1), Color(red: 0.2, green: 0.82, blue: 0.95)]
        case .speaking: return [Color(red: 0.3, green: 0.92, blue: 0.82), Color(red: 0.45, green: 0.6, blue: 1), Color(red: 0.86, green: 0.6, blue: 1)]
        case .idle: return [Color(red: 0.5, green: 0.44, blue: 1), Color(red: 0.25, green: 0.65, blue: 0.95), Color(red: 0.9, green: 0.55, blue: 0.85)]
        }
    }
}

/// Text with a band of light sweeping across it.
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: AssistantOverlay.reduceMotion)) { context in
            let phase = (context.date.timeIntervalSinceReferenceDate * 0.7).truncatingRemainder(dividingBy: 1)
            Text(text)
                .font(.system(size: size, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .overlay {
                    Text(text)
                        .font(.system(size: size, weight: .medium, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.clear, .white, Color(red: 0.8, green: 0.72, blue: 1), .clear],
                                                        startPoint: UnitPoint(x: phase * 2.4 - 1.2, y: 0.5),
                                                        endPoint: UnitPoint(x: phase * 2.4 - 0.4, y: 0.5)))
                }
        }
    }
}

/// A reply that arrives a word at a time out of a soft blur, with the word being
/// spoken lit in the assistant's colours.
struct RevealText: View {
    let text: String
    var spoken: NSRange?
    var size: CGFloat = 14
    /// Older replies are already read; only the newest arrives word by word.
    var animate = true
    @State private var shown = 0

    private var words: [(word: String, range: NSRange)] {
        var result: [(String, NSRange)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, _, enclosing, _ in
            let piece = ns.substring(with: enclosing).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append((piece, enclosing)) }
        }
        return result.isEmpty ? [(text, NSRange(location: 0, length: ns.length))] : result
    }

    var body: some View {
        let words = self.words
        TeleprompterFlow(spacing: size * 0.28, lineSpacing: size * 0.32) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, item in
                let visible = index < shown
                let lit = spoken.map { NSIntersectionRange($0, item.range).length > 0 } ?? false
                Text(item.word)
                    .font(.system(size: size, weight: lit ? .semibold : .regular))
                    .foregroundStyle(lit ? AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.75, green: 0.68, blue: 1)], startPoint: .top, endPoint: .bottom))
                                         : AnyShapeStyle(Color.white))
                    .shadow(color: lit ? AssistantOverlay.accent.opacity(0.9) : .clear, radius: 6)
                    .opacity(visible ? 1 : 0)
                    .blur(radius: visible ? 0 : 6)
                    .offset(y: visible ? 0 : 5)
                    .animation(.spring(response: 0.42, dampingFraction: 0.85), value: visible)
                    .animation(.easeOut(duration: 0.15), value: lit)
            }
        }
        .textSelection(.enabled)
        .task(id: text) {
            guard animate, !AssistantOverlay.reduceMotion else { shown = words.count; return }
            shown = 0
            for index in 0..<words.count {
                shown = index + 1
                try? await Task.sleep(for: .milliseconds(28))
                if Task.isCancelled { return }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
