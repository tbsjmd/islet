// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The closed island while the teleprompter reads or a video downloads: the
/// feature's mark on the left of the camera and its progress on the right,
/// laid out like the Keep Awake strip. A click opens the page.
enum NotchHeadlineActivity {
    static func symbol(_ activity: NotchCompactActivity) -> String {
        switch activity {
        case .assistant: return "waveform"
        case .teleprompter: return "text.viewfinder"
        default: return "arrow.down.to.line.circle.fill"
        }
    }

    static func tint(_ activity: NotchCompactActivity) -> Color {
        switch activity {
        case .assistant: return Color(red: 0.7, green: 0.6, blue: 1)
        case .teleprompter: return .orange
        default: return .cyan
        }
    }

    static func reading(_ activity: NotchCompactActivity) -> String {
        if activity == .assistant {
            switch AssistantService.shared.phase {
            case .listening: return "Listening"
            case .thinking:
                let step = AssistantService.shared.turns.last?.stepCount ?? 0
                return AssistantService.shared.waitingForPerson != nil ? "Your turn" : step > 0 ? "Step \(step + 1)" : "Thinking"
            case .speaking: return "Talking"
            case .idle: return ""
            }
        }
        if activity == .teleprompter {
            let prompter = TeleprompterService.shared
            return prompter.isPaused ? "Paused" : "\(Int(prompter.fraction * 100))%"
        }
        guard let fraction = VideoDownloaderService.shared.activeJob?.fraction else { return "…" }
        return "\(Int(fraction * 100))%"
    }

    static func stripWing(_ activity: NotchCompactActivity, in geometry: NotchGeometry) -> CGFloat {
        let provisional = geometry.compactTimerGeometry(showsDownloads: false,
                                                        wing: NotchTimerSupport.stripWingRange.lowerBound)
        let height = provisional.compactActivityContentHeight
        let textSize = NotchTimerSupport.stripTextSize(height: height)
        let text = (NotchAgentSupport.readingShape(reading(activity)) as NSString)
            .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .medium)])
            .width.rounded(.up)
        let iconSize = NotchTimerSupport.stripIconSize(height: height)
        let mark = NotchKeepAwakeSupport.symbolWidth(symbol(activity), size: iconSize)
            + provisional.compactActivityEdgeInset(boxHeight: iconSize, radius: iconSize / 2)
        return max(text + provisional.compactActivityEdgeInset(boxHeight: textSize * 0.72, radius: 0), mark)
            + NotchTimerSupport.stripCameraGap
    }
}

/// Redraws the strips as progress moves.
final class NotchHeadlineTicker: ObservableObject {
    static let shared = NotchHeadlineTicker()
    @Published var now = Date()
    private init() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard AssistantService.shared.isBusy || TeleprompterService.shared.isReading
                    || VideoDownloaderService.shared.activeJob != nil else { return }
            self?.now = Date()
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Beside a camera housing.
struct NotchHeadlineStrip: View {
    @ObservedObject var service: NotchService
    let activity: NotchCompactActivity
    var displayGeometry: NotchGeometry? = nil
    @ObservedObject private var ticker = NotchHeadlineTicker.shared

    var body: some View {
        let geometry = displayGeometry ?? service.compactActivityGeometry
        let height = geometry.compactActivityContentHeight
        let wing = geometry.compactActivityWingWidth
        let iconSize = NotchTimerSupport.stripIconSize(height: height)
        let textSize = NotchTimerSupport.stripTextSize(height: height)
        let reading = NotchHeadlineActivity.reading(activity)
        Button { service.openActivity(activity.module) } label: {
            HStack(spacing: 0) {
                Image(systemName: NotchHeadlineActivity.symbol(activity))
                    .font(.system(size: iconSize, weight: .medium))
                    .padding(.leading, geometry.compactActivityEdgeInset(boxHeight: iconSize, radius: iconSize / 2))
                    .frame(width: wing, height: height, alignment: .leading)
                Color.clear.frame(width: geometry.compactActivityCameraGap)
                Text(reading)
                    .font(.system(size: textSize, weight: .medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .padding(.trailing, geometry.compactActivityEdgeInset(boxHeight: textSize * 0.72, radius: 0))
                    .frame(width: wing, height: height, alignment: .trailing)
                    .onChange(of: NotchAgentSupport.readingShape(reading)) { _, _ in
                        DispatchQueue.main.async { service.refreshPresentation() }
                    }
            }
            .foregroundStyle(NotchHeadlineActivity.tint(activity))
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, geometry.compactActivityHorizontalPadding)
        .padding(.top, geometry.compactActivityTopPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.title(.enUS))
        .accessibilityValue(reading)
    }
}

