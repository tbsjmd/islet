// SPDX-License-Identifier: GPL-3.0-or-later
// Settings pages for Islet's three headline features.

import AppKit
import Speech
import SwiftUI

/// A page's title, what it is, and a button that opens it in the island.
private struct IsletPageHeader: View {
    let title: String
    let detail: String
    let module: NotchModule

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.bold())
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open in the Island") { NotchService.shared.open(module) }
        }
    }
}

struct AssistantSettingsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IsletPageHeader(title: "Assistant",
                                detail: "Hold ⌃ control + ⌥ option and ask out loud. It answers, shows you where things are, and clicks and types to do tasks for you.",
                                module: .assistant)
                AssistantSettingsControls()
            }
            .padding(22)
        }
    }
}

struct TeleprompterSettingsPage: View {
    @ObservedObject private var prompter = TeleprompterService.shared
    @AppStorage("teleprompterLocale") private var locale = Locale.current.identifier

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IsletPageHeader(title: "Teleprompter",
                                detail: "Read your script in the island, right under the camera. Paste it here or in the island, then press play.",
                                module: .teleprompter)
                SettingsCard(title: "Reading") {
                    SettingsChoiceRow(symbol: prompter.mode.icon, title: "Mode", selection: $prompter.mode) {
                        ForEach(ListeningMode.allCases) { Text($0.label).tag($0) }
                    }
                    Text(modeCaption).font(.caption).foregroundStyle(.secondary).padding(.leading, settingsRowTextInset)
                    if prompter.mode != .wordTracking {
                        SettingsRow(symbol: "speedometer", title: "Speed", caption: "\(Int(prompter.wordsPerMinute)) words a minute") {
                            Slider(value: $prompter.wordsPerMinute, in: 80...220, step: 10).frame(width: 180)
                        }
                    }
                    SettingsRow(symbol: "textformat.size", title: "Text size", caption: "\(Int(prompter.fontSize)) pt") {
                        Slider(value: $prompter.fontSize, in: 14...40, step: 1).frame(width: 180)
                    }
                    if prompter.mode != .classic {
                        SettingsRow(symbol: "globe", title: "Speech language") {
                            Picker("", selection: $locale) {
                                ForEach(SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted(), id: \.self) {
                                    Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
                SettingsCard(title: "Script") {
                    TextEditor(text: $prompter.script)
                        .font(.system(size: 13))
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    HStack {
                        Text("\(splitTextIntoWords(prompter.script).count) words").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Start Reading") { prompter.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(prompter.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(22)
        }
    }

    private var modeCaption: String {
        switch prompter.mode {
        case .wordTracking: return "Listens and highlights each word as you say it. Needs the microphone and Speech Recognition."
        case .classic: return "Scrolls at a steady pace. No microphone needed."
        case .silencePaused: return "Scrolls at your pace only while you're talking."
        }
    }
}

struct VideoDownloaderSettingsPage: View {
    @ObservedObject private var downloader = VideoDownloaderService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IsletPageHeader(title: "Video Downloader",
                                detail: "Paste a link from YouTube or 1,000+ other sites in the island to download it as video or audio.",
                                module: .videoDownloader)
                SettingsCard(title: "Downloads") {
                    SettingsChoiceRow(symbol: "film", title: "Download as", selection: $downloader.format) {
                        ForEach(VideoDownloadFormat.allCases) { Text($0.label).tag($0) }
                    }
                    SettingsChoiceRow(symbol: "sparkles.tv", title: "Video quality", selection: $downloader.quality) {
                        ForEach(VideoDownloadQuality.allCases) { Text($0.label).tag($0) }
                    }
                    SettingsRow(symbol: "folder", title: "Save to", caption: downloader.folder.path) {
                        Button("Choose…") { downloader.chooseFolder() }
                    }
                }
                SettingsCard(title: "Tools") {
                    let path = downloader.ytDlp?.path
                    let brew = path.map { $0.hasPrefix("/opt/homebrew") || $0.hasPrefix("/usr/local") } ?? false
                    SettingsRow(symbol: "terminal", title: "yt-dlp",
                                caption: path.map { brew ? "Using Homebrew's copy; update it with brew upgrade yt-dlp." : "Using \($0)" }
                                    ?? "Not installed yet.") {
                        if downloader.installing { ProgressView().controlSize(.small) }
                        else if !brew {
                            Button(path == nil ? "Get yt-dlp" : "Update") { downloader.installYtDlp() }
                        }
                    }
                    if let error = downloader.installError {
                        Text(error).font(.caption).foregroundStyle(.red).padding(.leading, settingsRowTextInset)
                    }
                    Text("With ffmpeg installed (brew install ffmpeg), video and audio are merged into one MP4 and audio is saved as M4A.")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, settingsRowTextInset)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
    }
}
