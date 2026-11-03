// SPDX-License-Identifier: GPL-3.0-or-later
// Video and audio downloader of the island, after Parabolic
// (https://github.com/NickvisionApps/Parabolic, GPL-3.0): a front end for yt-dlp.

import AppKit
import Combine
import Foundation

enum VideoDownloadFormat: String, CaseIterable, Identifiable {
    case video, audio
    var id: String { rawValue }
    var label: String { self == .video ? "Video" : "Audio" }
    var symbol: String { self == .video ? "film" : "music.note" }
}

enum VideoDownloadQuality: String, CaseIterable, Identifiable {
    case best, p1080, p720, p480
    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: return "Best"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
    var maxHeight: Int? {
        switch self {
        case .best: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

final class VideoDownloadJob: ObservableObject, Identifiable {
    enum Status: Equatable { case starting, downloading, processing, finished, failed(String), cancelled }

    let id = UUID()
    let url: String
    let format: VideoDownloadFormat
    @Published var title: String
    @Published var fraction: Double?
    @Published var speed: Double?
    @Published var eta: Double?
    @Published var status: Status = .starting
    @Published var file: URL?
    fileprivate var process: Process?
    fileprivate var lastError = ""

    init(url: String, format: VideoDownloadFormat) {
        self.url = url
        self.format = format
        title = url
    }

    var isActive: Bool {
        switch status {
        case .starting, .downloading, .processing: return true
        default: return false
        }
    }
}

/// Runs yt-dlp for each queued link and reports progress to the island.
/// Uses an installed yt-dlp when there is one, otherwise fetches the
/// standalone build into Application Support on first use.
final class VideoDownloaderService: ObservableObject {
    static let shared = VideoDownloaderService()

    @Published private(set) var jobs: [VideoDownloadJob] = []
    @Published private(set) var installing = false
    @Published private(set) var installError: String?
    @Published var format: VideoDownloadFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "videoDownloaderFormat") }
    }
    @Published var quality: VideoDownloadQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "videoDownloaderQuality") }
    }
    @Published var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "videoDownloaderFolder") }
    }

    private var cancellables: [UUID: AnyCancellable] = [:]
    /// The island refreshes its live activity and announces finished files.
    var onFinish: ((VideoDownloadJob) -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        format = VideoDownloadFormat(rawValue: defaults.string(forKey: "videoDownloaderFormat") ?? "") ?? .video
        quality = VideoDownloadQuality(rawValue: defaults.string(forKey: "videoDownloaderQuality") ?? "") ?? .best
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        folder = defaults.string(forKey: "videoDownloaderFolder").map { URL(fileURLWithPath: $0) } ?? downloads
    }

    var activeJob: VideoDownloadJob? { jobs.first { $0.isActive } }

    // MARK: Tools

    private static var bundledToolURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
            .appendingPathComponent("yt-dlp")
    }

    private static func installed(_ name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var ytDlp: URL? {
        Self.installed("yt-dlp") ?? (FileManager.default.isExecutableFile(atPath: Self.bundledToolURL.path)
            ? Self.bundledToolURL : nil)
    }

    private var ffmpeg: URL? { Self.installed("ffmpeg") }

    func installYtDlp() {
        guard !installing else { return }
        installing = true
        installError = nil
        let source = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        URLSession.shared.downloadTask(with: source) { [weak self] temp, response, error in
            var failure = error?.localizedDescription
            if failure == nil, let temp, (response as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    let target = Self.bundledToolURL
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temp, to: target)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                } catch { failure = error.localizedDescription }
            } else if failure == nil {
                failure = "Download failed"
            }
            DispatchQueue.main.async {
                self?.installing = false
                self?.installError = failure
            }
        }.resume()
    }

    // MARK: Jobs

    /// Accepts anything that reads as a web link; yt-dlp decides whether it can fetch it.
    static func link(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return trimmed
    }

    func download(_ text: String) {
        guard let link = Self.link(from: text), let tool = ytDlp else { return }
        let job = VideoDownloadJob(url: link, format: format)
        // Nested published objects don't reach SwiftUI on their own.
        cancellables[job.id] = job.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        jobs.insert(job, at: 0)
        run(job, tool: tool)
    }

    func cancel(_ job: VideoDownloadJob) {
        guard job.isActive else { return }
        job.status = .cancelled
        if let process = job.process { process.terminate() } else { onFinish?(job) }
    }

    func remove(_ job: VideoDownloadJob) {
        cancel(job)
        jobs.removeAll { $0.id == job.id }
        cancellables[job.id] = nil
    }

    func clearFinished() {
        for job in jobs where !job.isActive { cancellables[job.id] = nil }
        jobs.removeAll { !$0.isActive }
    }

    func reveal(_ job: VideoDownloadJob) {
        if let file = job.file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func arguments(for job: VideoDownloadJob) -> [String] {
        var args = ["--no-colors", "--newline", "--progress", "--no-playlist", "--no-simulate",
                    "--print", "before_dl:TITLE %(title)s",
                    "--print", "after_move:FILE %(filepath)s",
                    "--progress-template",
                    "download:PROG %(progress.downloaded_bytes)s %(progress.total_bytes,total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
                    "-P", folder.path, "-o", "%(title).180B [%(id)s].%(ext)s"]
        let merges = ffmpeg != nil
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        switch job.format {
        case .audio:
            args += ["-f", "ba/b"]
            if merges { args += ["-x", "--audio-format", "m4a"] }
        case .video:
            let cap = quality.maxHeight.map { "[height<=\($0)]" } ?? ""
            args += ["-f", merges ? "bv*\(cap)+ba/b\(cap)/b" : "b\(cap)/b"]
            if merges { args += ["--merge-output-format", "mp4"] }
        }
        return args + ["--", job.url]
    }

    private func run(_ job: VideoDownloadJob, tool: URL) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments(for: job)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        job.process = process

        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                DispatchQueue.main.async { Self.apply(line, to: job) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: chunk, as: UTF8.self)
            if let line = text.split(separator: "\n").last(where: { $0.contains("ERROR") }) {
                DispatchQueue.main.async { job.lastError = String(line) }
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                job.process = nil
                defer { self?.onFinish?(job) }
                guard job.status != .cancelled else { return }
                if process.terminationStatus == 0 {
                    job.status = .finished
                    job.fraction = 1
                } else {
                    let message = job.lastError.replacingOccurrences(of: "ERROR: ", with: "")
                    job.status = .failed(message.isEmpty ? "yt-dlp exited with \(process.terminationStatus)" : message)
                }
            }
        }
        do {
            try process.run()
        } catch {
            job.status = .failed(error.localizedDescription)
        }
    }

    /// One line of yt-dlp's templated output.
    static func apply(_ line: String, to job: VideoDownloadJob) {
        if line.hasPrefix("TITLE ") {
            job.title = String(line.dropFirst(6))
        } else if line.hasPrefix("FILE ") {
            job.file = URL(fileURLWithPath: String(line.dropFirst(5)))
        } else if line.hasPrefix("PROG ") {
            let parts = line.split(separator: " ").dropFirst().map { Double($0) }
            guard parts.count == 4, job.status != .cancelled else { return }
            job.status = .downloading
            if let done = parts[0], let total = parts[1], total > 0 { job.fraction = min(1, done / total) }
            job.speed = parts[2]
            job.eta = parts[3]
            if job.fraction == 1 { job.status = .processing }
        } else if line.contains("[Merger]") || line.contains("[ExtractAudio]") {
            job.status = .processing
        }
    }
}
