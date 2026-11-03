// SPDX-License-Identifier: GPL-3.0-or-later
// Video and audio downloader page of the island, after Parabolic
// (https://github.com/NickvisionApps/Parabolic, GPL-3.0).

import AppKit
import SwiftUI

/// Paste a link, pick video or audio, and the download runs in the island:
/// its progress shows on the closed island and the finished file is a click away.
struct NotchVideoDownloaderView: View {
    @ObservedObject private var downloader = VideoDownloaderService.shared
    @State private var link = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if downloader.ytDlp == nil {
                setup
            } else {
                field
                if downloader.jobs.isEmpty {
                    NotchEmptyView(symbol: "arrow.down.to.line.circle",
                                   message: "Paste a link from YouTube or 1,000+ other sites.") { EmptyView() }
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 6) {
                            ForEach(downloader.jobs) { NotchVideoDownloadRow(job: $0) }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .notchBand(leading: { options }, trailing: { actions })
        .onAppear {
            // A link already on the clipboard is almost always the one to fetch.
            if link.isEmpty, let copied = NSPasteboard.general.string(forType: .string),
               let copiedLink = VideoDownloaderService.link(from: copied) {
                link = copiedLink
            }
            fieldFocused = true
        }
    }

    private var setup: some View {
        NotchEmptyView(symbol: "arrow.down.circle",
                       message: downloader.installError.map { "Couldn't get yt-dlp: \($0)" }
                           ?? "Downloads use yt-dlp. Get it once and you're set.") {
            if downloader.installing {
                ProgressView().controlSize(.small)
            } else {
                NotchPillButton(title: "Get yt-dlp", prominent: true, action: downloader.installYtDlp)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "link").foregroundStyle(.white.opacity(0.5))
            TextField("", text: $link, prompt: Text("Paste a video link").foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 18))
                    .foregroundStyle(VideoDownloaderService.link(from: link) == nil ? .white.opacity(0.25) : .white)
            }
            .buttonStyle(.plain)
            .disabled(VideoDownloaderService.link(from: link) == nil)
            .help("Download")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .modifier(NotchControlSurface(cornerRadius: 12, interactive: false))
    }

    private func submit() {
        guard VideoDownloaderService.link(from: link) != nil else { return }
        downloader.download(link)
        link = ""
    }

    private var options: some View {
        HStack(spacing: 4) {
            Picker("", selection: $downloader.format) {
                ForEach(VideoDownloadFormat.allCases) { Image(systemName: $0.symbol).help($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if downloader.format == .video {
                Menu {
                    Picker("Quality", selection: $downloader.quality) {
                        ForEach(VideoDownloadQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(downloader.quality.label).font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            NotchIconButton(symbol: "folder", title: "Save to \(downloader.folder.lastPathComponent)") {
                downloader.chooseFolder()
            }
            if downloader.jobs.contains(where: { !$0.isActive }) {
                NotchIconButton(symbol: "trash", title: "Clear finished") { downloader.clearFinished() }
            }
        }
    }
}

private struct NotchVideoDownloadRow: View {
    @ObservedObject var job: VideoDownloadJob
    @ObservedObject private var downloader = VideoDownloaderService.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: job.format.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if job.isActive {
                    ProgressView(value: job.fraction ?? 0).progressViewStyle(.linear).tint(.white)
                }
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if job.isActive {
                NotchIconButton(symbol: "xmark", title: "Cancel") { downloader.cancel(job) }
            } else {
                if job.status == .finished {
                    NotchIconButton(symbol: "magnifyingglass", title: "Show in Finder") { downloader.reveal(job) }
                }
                NotchIconButton(symbol: "minus.circle", title: "Remove") { downloader.remove(job) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .modifier(NotchControlSurface(cornerRadius: 12, interactive: false))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if job.status == .finished, let file = job.file { NSWorkspace.shared.open(file) }
        }
    }

    private var detail: String {
        switch job.status {
        case .starting: return "Starting…"
        case .processing: return "Finishing up…"
        case .finished: return job.file?.lastPathComponent ?? "Done"
        case .cancelled: return "Cancelled"
        case .failed(let message): return message
        case .downloading:
            var parts: [String] = []
            if let fraction = job.fraction { parts.append("\(Int(fraction * 100))%") }
            if let speed = job.speed { parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s") }
            if let eta = job.eta, eta > 0 { parts.append("\(Int(eta) / 60):" + String(format: "%02d", Int(eta) % 60) + " left") }
            return parts.joined(separator: " · ")
        }
    }
}
