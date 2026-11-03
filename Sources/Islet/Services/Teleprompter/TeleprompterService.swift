// SPDX-License-Identifier: GPL-3.0-or-later
// Teleprompter page of the island, after Textream (https://github.com/f/textream, MIT).

import AppKit
import Combine
import Foundation

enum ListeningMode: String, CaseIterable, Identifiable {
    case wordTracking, classic, silencePaused

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return "Classic"
        case .silencePaused: return "Voice-Activated"
        case .wordTracking: return "Word Tracking"
        }
    }

    var icon: String {
        switch self {
        case .classic: return "arrow.down.circle"
        case .silencePaused: return "waveform.circle"
        case .wordTracking: return "text.word.spacing"
        }
    }
}

/// The three values Textream's recognizer reads from its settings.
final class TeleprompterSettings {
    static let shared = TeleprompterSettings()
    private let defaults = UserDefaults.standard

    var listeningMode: ListeningMode {
        get { ListeningMode(rawValue: defaults.string(forKey: "teleprompterMode") ?? "") ?? .wordTracking }
        set { defaults.set(newValue.rawValue, forKey: "teleprompterMode") }
    }
    /// Empty means the system's default input.
    var selectedMicUID: String { defaults.string(forKey: "teleprompterMicUID") ?? "" }
    var speechLocale: String { defaults.string(forKey: "teleprompterLocale") ?? Locale.current.identifier }
}

/// Holds the script and drives the reading. Word tracking follows the
/// recognizer; classic scrolls at a fixed pace; voice-activated scrolls at
/// that pace only while the microphone hears speech. Reading pins the island
/// open so the script stays under the camera.
final class TeleprompterService: ObservableObject {
    static let shared = TeleprompterService()

    @Published var script: String {
        didSet { UserDefaults.standard.set(script, forKey: "teleprompterScript") }
    }
    @Published var mode: ListeningMode {
        didSet { TeleprompterSettings.shared.listeningMode = mode }
    }
    @Published var wordsPerMinute: Double {
        didSet { UserDefaults.standard.set(wordsPerMinute, forKey: "teleprompterWPM") }
    }
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "teleprompterFontSize") }
    }
    @Published private(set) var isReading = false
    @Published private(set) var isPaused = false
    /// Characters read, in the collapsed text the recognizer matches against.
    @Published private(set) var progress = 0
    @Published private(set) var error: String?
    @Published private(set) var isSpeaking = false

    private(set) var words: [String] = []
    /// Collapsed-text offset where each word starts.
    private(set) var wordStarts: [Int] = []
    private var total = 0
    private var exactProgress = 0.0
    private let recognizer = SpeechRecognizer()
    private var timer: Timer?
    private var lastTick = Date()

    private init() {
        let defaults = UserDefaults.standard
        script = defaults.string(forKey: "teleprompterScript") ?? ""
        mode = TeleprompterSettings.shared.listeningMode
        wordsPerMinute = defaults.object(forKey: "teleprompterWPM") as? Double ?? 140
        fontSize = defaults.object(forKey: "teleprompterFontSize") as? Double ?? 20
    }

    var fraction: Double { total == 0 ? 0 : min(1, Double(progress) / Double(total)) }

    /// Index of the word being read.
    var currentWord: Int {
        guard !wordStarts.isEmpty else { return 0 }
        var low = 0, high = wordStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if wordStarts[mid] <= progress { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func start() {
        words = splitTextIntoWords(script)
        guard !words.isEmpty else { return }
        var offset = 0
        wordStarts = words.map { word in defer { offset += word.count + 1 }; return offset }
        total = max(0, offset - 1)
        progress = 0
        exactProgress = 0
        error = nil
        isReading = true
        isPaused = false
        beginListening(fresh: true)
        startTimer()
        NotchService.shared.open(.teleprompter, pinned: true, takeFocus: false)
    }

    func togglePause() {
        guard isReading else { return }
        isPaused.toggle()
        if isPaused {
            recognizer.stop()
        } else {
            beginListening(fresh: false)
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        recognizer.forceStop()
        isReading = false
        isPaused = false
        isSpeaking = false
        NotchService.shared.pinned = false
    }

    func jump(toWord index: Int) {
        guard wordStarts.indices.contains(index) else { return }
        progress = wordStarts[index]
        exactProgress = Double(progress)
        if mode == .wordTracking { recognizer.jumpTo(charOffset: progress) }
    }

    /// Steps back or forward a few words from the keyboard or the band.
    func nudge(words delta: Int) { jump(toWord: max(0, min(words.count - 1, currentWord + delta))) }

    private func beginListening(fresh: Bool) {
        guard mode != .classic else { return }
        let text = words.joined(separator: " ")
        if fresh || mode != .wordTracking {
            recognizer.start(with: text)
            if mode == .wordTracking, progress > 0 { recognizer.jumpTo(charOffset: progress) }
        } else {
            recognizer.resume()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        lastTick = Date()
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now
        if let message = recognizer.error, message != error { error = message }
        let speaking = recognizer.isSpeaking
        if speaking != isSpeaking { isSpeaking = speaking }
        guard !isPaused else { return }
        switch mode {
        case .wordTracking:
            if recognizer.recognizedCharCount != progress {
                progress = recognizer.recognizedCharCount
                exactProgress = Double(progress)
            }
        case .classic, .silencePaused:
            guard mode == .classic || speaking else { return }
            let charsPerWord = Double(total) / Double(max(1, words.count))
            exactProgress += wordsPerMinute / 60 * charsPerWord * elapsed
            let next = Int(exactProgress)
            if next != progress { progress = next }
        }
        if progress >= total {
            // Hold the last line a moment before the island lets go.
            timer?.invalidate(); timer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.isReading, self.progress >= self.total else { return }
                self.stop()
            }
        }
    }
}
