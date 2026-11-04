// SPDX-License-Identifier: GPL-3.0-or-later
// The assistant's hands, after Atticus (https://github.com/SaarthurR/atticus-mac, MIT)
// and Plip (https://github.com/hussainn7/plip-oss, MIT): a small, fixed set of Mac
// actions. Anything that closes, runs or changes something waits for a yes.

import AppKit
import Foundation

struct AssistantAction: Equatable, Identifiable {
    enum Kind: Equatable {
        case openApp(String), quitApp(String), openURL(URL), webSearch(String)
        case findFiles(String), openFile(URL)
        case volume(Int), mute(Bool), darkMode(Bool), media(NotchPlaybackCommand)
        case timer(minutes: Int), runShortcut(String), remember(String)
        case reminder(title: String, minutes: Int?)
    }

    let id = UUID()
    let kind: Kind

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind }

    /// Closing apps, running shortcuts, opening programs and writing to
    /// Reminders ask first; everything else is quick to undo.
    var needsConfirmation: Bool {
        switch kind {
        case .quitApp, .runShortcut, .reminder: return true
        case .openFile(let url): return AssistantActions.runsCode(url)
        default: return false
        }
    }

    var summary: String {
        switch kind {
        case .openApp(let name): return "Open \(name)"
        case .quitApp(let name): return "Quit \(name)"
        case .openURL(let url): return "Open \(url.host ?? url.absoluteString)"
        case .webSearch(let query): return "Search the web for “\(query)”"
        case .findFiles(let query): return "Find “\(query)”"
        case .openFile(let url): return "Open \(url.lastPathComponent)"
        case .volume(let level): return "Volume \(level)%"
        case .mute(let on): return on ? "Mute" : "Unmute"
        case .darkMode(let on): return on ? "Dark mode on" : "Dark mode off"
        case .media(let command):
            switch command {
            case .next: return "Next track"
            case .previous: return "Previous track"
            default: return "Play/pause"
            }
        case .timer(let minutes): return "\(minutes)-minute timer"
        case .runShortcut(let name): return "Run the “\(name)” shortcut"
        case .remember(let fact): return "Remember: \(fact)"
        case .reminder(let title, let minutes):
            return "Reminder: \(title)" + (minutes.map { " in \($0) min" } ?? "")
        }
    }
}

enum AssistantActions {
    // MARK: Instant commands

    /// Commands that need no AI, as both projects run them: matched whole, so
    /// "open Safari and find flights" still goes to the model.
    static func instant(_ text: String) -> AssistantAction.Kind? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"^(please |hey |can you |could you )+"#, with: "", options: [.regularExpression, .caseInsensitive])
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: .caseInsensitive),
                  let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: t).map { String(t[$0]) } ?? ""
            }
        }
        if let m = match(#"(?:open|launch|start) (?:the )?(.+?)(?: app)?"#), app(named: m[1]) != nil { return .openApp(m[1]) }
        if let m = match(#"(?:quit|close) (?:the )?(.+?)(?: app)?"#), app(named: m[1]) != nil { return .quitApp(m[1]) }
        if let m = match(#"(?:set )?(?:the )?volume (?:to )?(\d{1,3})(?: ?%| percent)?"#), let level = Int(m[1]) { return .volume(min(100, level)) }
        if match(#"mute(?: the)?(?: sound| volume| audio)?"#) != nil { return .mute(true) }
        if match(#"unmute(?: the)?(?: sound| volume| audio)?"#) != nil { return .mute(false) }
        if match(#"(?:turn on|enable|switch to) dark mode|dark mode on"#) != nil { return .darkMode(true) }
        if match(#"(?:turn off|disable) dark mode|dark mode off|(?:turn on|switch to) light mode"#) != nil { return .darkMode(false) }
        if let m = match(#"(?:search|google|look up)(?: the web)?(?: for)? (.+)"#) { return .webSearch(m[1]) }
        if match(#"(?:play|pause|resume)(?: (?:the )?music)?"#) != nil { return .media(.toggle) }
        if match(#"(?:next|skip)(?: (?:song|track))?"#) != nil { return .media(.next) }
        if match(#"(?:previous|last|go back a)(?: (?:song|track))?"#) != nil { return .media(.previous) }
        if let m = match(#"(?:set |start )?(?:a )?(\d{1,3})[ -]minutes?(?: timer)?|(?:set |start )?(?:a )?timer for (\d{1,3}) minutes?"#),
           let minutes = Int(m[1].isEmpty ? m[2] : m[1]), minutes > 0 { return .timer(minutes: minutes) }
        if let m = match(#"remember (?:that )?(.+)"#) { return .remember(m[1]) }
        if let m = match(#"run (?:my )?(?:the )?(.+?) shortcut"#) { return .runShortcut(m[1]) }
        if let m = match(#"find (?:my |the )(.+)"#) { return .findFiles(m[1]) }
        if let m = match(#"remind me to (.+?) in (\d{1,4}) minutes?"#) { return .reminder(title: m[1], minutes: Int(m[2])) }
        return nil
    }

    // MARK: Model replies

    /// The model lists actions in a fenced ```actions block of JSON objects.
    static func parse(reply: String) -> (text: String, actions: [AssistantAction.Kind]) {
        guard let start = reply.range(of: "```actions"),
              let end = reply.range(of: "```", range: start.upperBound..<reply.endIndex) else {
            return (reply.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let json = String(reply[start.upperBound..<end.lowerBound])
        let text = (String(reply[..<start.lowerBound]) + String(reply[end.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objects = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        return (text, objects.compactMap(kind(from:)))
    }

    static func kind(from object: [String: Any]) -> AssistantAction.Kind? {
        let s = { (key: String) in (object[key] as? String)?.trimmingCharacters(in: .whitespaces) }
        let n = { (key: String) in (object[key] as? NSNumber)?.intValue ?? (object[key] as? String).flatMap { Int($0) } }
        switch s("do") ?? "" {
        case "open_app": return s("name").map { .openApp($0) }
        case "quit_app": return s("name").map { .quitApp($0) }
        case "open_url":
            guard let url = s("url").flatMap(URL.init(string:)),
                  ["http", "https", "spotify", "music", "maps"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            return .openURL(url)
        case "web_search": return s("query").map { .webSearch($0) }
        case "find_files": return s("query").map { .findFiles($0) }
        case "open_file":
            guard let path = s("path") else { return nil }
            return .openFile(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        case "volume": return n("level").map { .volume(max(0, min(100, $0))) }
        case "mute": return .mute((object["on"] as? Bool) ?? true)
        case "dark_mode": return .darkMode((object["on"] as? Bool) ?? true)
        case "media":
            switch s("command") {
            case "next": return .media(.next)
            case "previous": return .media(.previous)
            default: return .media(.toggle)
            }
        case "timer": return n("minutes").flatMap { $0 > 0 ? .timer(minutes: min($0, 999)) : nil }
        case "run_shortcut": return s("name").map { .runShortcut($0) }
        case "remember": return s("fact").map { .remember($0) }
        case "reminder": return s("title").map { .reminder(title: $0, minutes: n("minutes")) }
        default: return nil
        }
    }

    static let promptReference = """
    Actions you can take, as a JSON array in a fenced ```actions block after your reply:
    {"do":"open_app","name":"Safari"} · {"do":"quit_app","name":"Slack"} · {"do":"open_url","url":"https://…"}
    {"do":"web_search","query":"…"} · {"do":"find_files","query":"lease pdf"} · {"do":"open_file","path":"~/…"}
    {"do":"volume","level":40} · {"do":"mute","on":true} · {"do":"dark_mode","on":true}
    {"do":"media","command":"play_pause|next|previous"} · {"do":"timer","minutes":10}
    {"do":"run_shortcut","name":"…"} · {"do":"remember","fact":"…"} · {"do":"reminder","title":"…","minutes":30}
    Use actions only when the person asked for something to happen. Include every action they asked for: Islet shows a "Do it" button for quitting apps, shortcuts and reminders, so never hold those back. open_url takes https, spotify:, music: or maps: links.
    """

    // MARK: Running

    static let appAliases = [
        "chrome": "Google Chrome", "vscode": "Visual Studio Code", "vs code": "Visual Studio Code",
        "code": "Visual Studio Code", "settings": "System Settings", "system preferences": "System Settings",
        "preferences": "System Settings", "word": "Microsoft Word", "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint", "outlook": "Microsoft Outlook", "teams": "Microsoft Teams",
        "imessage": "Messages", "texts": "Messages", "itunes": "Music", "files": "Finder", "browser": "Safari",
    ]

    /// The installed app a spoken name means: exact name, alias, then prefix.
    static func app(named spoken: String) -> URL? {
        let wanted = (appAliases[spoken.lowercased()] ?? spoken).lowercased()
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        let apps = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        }
        let name = { (url: URL) in url.deletingPathExtension().lastPathComponent.lowercased() }
        return apps.first { name($0) == wanted } ?? apps.first { name($0).hasPrefix(wanted) && wanted.count >= 3 }
    }

    static func runsCode(_ url: URL) -> Bool {
        ["app", "command", "sh", "pkg", "dmg", "workflow", "scpt", "terminal", "tool"].contains(url.pathExtension.lowercased())
    }

    /// Spotlight, by name first and then by content.
    static func findFiles(_ query: String) -> [URL] {
        func mdfind(_ args: [String]) -> [URL] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", NSHomeDirectory()] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
                .filter { !$0.path.contains("/Library/") && !$0.path.contains("/.") }
        }
        let words = query.split(separator: " ").filter { !["file", "files", "document", "the", "my"].contains($0.lowercased()) }
        let name = words.joined(separator: " ")
        let byName = mdfind(["-name", name])
        return Array((byName.isEmpty ? mdfind([name]) : byName).prefix(6))
    }

    /// Runs one action and says what happened, in a few words.
    @discardableResult
    static func run(_ kind: AssistantAction.Kind) -> (message: String, files: [URL]) {
        switch kind {
        case .openApp(let name):
            guard let url = app(named: name) else { return ("I couldn't find \(name).", []) }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return ("Opened \(url.deletingPathExtension().lastPathComponent).", [])
        case .quitApp(let name):
            let wanted = (appAliases[name.lowercased()] ?? name).lowercased()
            let running = NSWorkspace.shared.runningApplications.filter {
                ($0.localizedName?.lowercased()).map { $0 == wanted || $0.hasPrefix(wanted) } == true
            }
            running.forEach { $0.terminate() }
            return (running.isEmpty ? "\(name) isn't running." : "Quit \(running[0].localizedName ?? name).", [])
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            return ("Opened \(url.host ?? "the link").", [])
        case .webSearch(let query):
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            NSWorkspace.shared.open(components.url!)
            return ("Searching for “\(query)”.", [])
        case .findFiles(let query):
            let files = findFiles(query)
            return (files.isEmpty ? "Nothing on your Mac matches “\(query)”." : "Found \(files.count).", files)
        case .openFile(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { return ("That file is gone.", []) }
            NSWorkspace.shared.open(url)
            return ("Opened \(url.lastPathComponent).", [])
        case .volume(let level):
            appleScript("set volume output volume \(level) without output muted")
            return ("Volume \(level)%.", [])
        case .mute(let on):
            appleScript("set volume output muted \(on)")
            return (on ? "Muted." : "Unmuted.", [])
        case .darkMode(let on):
            let ok = appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
            return (ok ? (on ? "Dark mode is on." : "Dark mode is off.") : "macOS didn't let me change the appearance.", [])
        case .media(let command):
            _ = NotchMusicService.shared.send(command)
            return ("Done.", [])
        case .timer(let minutes):
            NotchTimerService.shared.start(mode: .timer, minutes: minutes)
            return ("Timer set for \(minutes) minute\(minutes == 1 ? "" : "s").", [])
        case .runShortcut(let name):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            do { try process.run() } catch { return ("Shortcuts couldn't run “\(name)”.", []) }
            return ("Running “\(name)”.", [])
        case .remember(let fact):
            AssistantMemory.add(fact)
            return ("Got it, I'll remember that.", [])
        case .reminder(let title, let minutes):
            let due = minutes.map { ", remind me date:((current date) + \($0) * minutes)" } ?? ""
            let ok = appleScript("tell application \"Reminders\" to make new reminder with properties {name:\(quoted(title))\(due)}")
            return (ok ? "Added to Reminders." : "Reminders didn't accept it.", [])
        }
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @discardableResult
    private static func appleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}

/// What the model returns each step.
struct AssistantPlan {
    var say: String
    var steps: [[String: Any]]
    var done: Bool

    /// The JSON object the prompt asks for, wherever it sits in the reply. A
    /// reply that isn't one is a plain answer, with any old ```actions block.
    static func parse(_ reply: String) -> AssistantPlan {
        let cleaned = reply.replacingOccurrences(of: "```json", with: "```")
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end,
           let object = try? JSONSerialization.jsonObject(with: Data(cleaned[start...end].utf8)) as? [String: Any] {
            return AssistantPlan(say: (object["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                 steps: object["actions"] as? [[String: Any]] ?? [],
                                 done: object["done"] as? Bool ?? true)
        }
        let old = AssistantActions.parse(reply: reply)
        return AssistantPlan(say: old.text, steps: [], done: true)
    }
}

/// What the person asked the assistant to remember, fed into every request.
enum AssistantMemory {
    private static let key = "assistantMemory"

    static var facts: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ fact: String) {
        // ponytail: last 50 facts, plain list; summarize if people keep more.
        UserDefaults.standard.set(Array((facts + [fact]).suffix(50)), forKey: key)
    }

    static func remove(_ fact: String) {
        UserDefaults.standard.set(facts.filter { $0 != fact }, forKey: key)
    }
}
