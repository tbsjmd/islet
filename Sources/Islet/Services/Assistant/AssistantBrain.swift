// SPDX-License-Identifier: GPL-3.0-or-later
// The models the assistant can think with, as Plip's engines and Atticus's clients:
// the Claude plan through Claude Code, a Claude API key, Gemini with a free or paid
// API key or a Google sign-in through Gemini CLI, and any OpenAI-compatible server.
// One session lives for one task, so every step keeps the conversation so far.

import Foundation

enum AssistantEngine: String, CaseIterable, Identifiable {
    case claudeCode, anthropicAPI, geminiAPI, geminiCLI, customServer
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude plan"
        case .anthropicAPI: return "Claude API key"
        case .geminiAPI: return "Gemini API key"
        case .geminiCLI: return "Google sign-in"
        case .customServer: return "Local or custom"
        }
    }
}

struct AssistantBrainConfig {
    var engine: AssistantEngine
    var model: String
    var effort: String
    var anthropicKey: String
    var geminiKey: String
    var geminiModel: String
    var serverURL: String
    var serverModel: String
    var serverKey: String
}

final class AssistantBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    private let config: AssistantBrainConfig
    private let system: String
    /// API engines: the conversation so far, with only the newest picture kept.
    private var messages: [[String: Any]] = []
    /// Gemini CLI has no session to keep, so the transcript is resent.
    private var transcript: [String] = []
    private var claude: ClaudeCodeSession?
    private var task: URLSessionTask?
    private var process: Process?

    init(config: AssistantBrainConfig, system: String) {
        self.config = config
        self.system = system
    }

    func close() {
        claude?.close()
        task?.cancel()
        process?.terminate()
    }

    /// One turn: the text, with a screenshot when there is one.
    func send(_ text: String, image: Data?) async throws -> String {
        switch config.engine {
        case .claudeCode:
            if claude == nil { claude = try ClaudeCodeSession(model: config.model, effort: config.effort, system: system) }
            return try await claude!.send(text, image: image)
        case .anthropicAPI: return try await anthropic(text, image: image)
        case .geminiAPI: return try await gemini(text, image: image)
        case .geminiCLI: return try await geminiCLI(text, image: image)
        case .customServer: return try await openAICompatible(text, image: image)
        }
    }

    static func claudeModel(_ size: String) -> String {
        switch size {
        case "opus": return "claude-opus-5-5"
        case "sonnet": return "claude-sonnet-5-5"
        default: return "claude-haiku-5-5"
        }
    }

    // MARK: HTTP engines

    private func anthropic(_ text: String, image: Data?) async throws -> String {
        dropOldImages(key: "content", isImage: { $0["type"] as? String == "image" })
        var content: [[String: Any]] = []
        if let image { content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.base64EncodedString()]]) }
        content.append(["type": "text", "text": text])
        messages.append(["role": "user", "content": content])
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.setValue(config.anthropicKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let reply = try await post(request, body: ["model": Self.claudeModel(config.model), "max_tokens": 2048,
                                                   "system": system, "messages": messages]) { json in
            (json["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
        messages.append(["role": "assistant", "content": reply])
        return reply
    }

    private func gemini(_ text: String, image: Data?) async throws -> String {
        dropOldImages(key: "parts", isImage: { $0["inline_data"] != nil })
        var parts: [[String: Any]] = []
        if let image { parts.append(["inline_data": ["mime_type": "image/png", "data": image.base64EncodedString()]]) }
        parts.append(["text": text])
        messages.append(["role": "user", "parts": parts])
        let model = config.geminiModel.isEmpty ? "gemini-flash-latest" : config.geminiModel
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.setValue(config.geminiKey, forHTTPHeaderField: "x-goog-api-key")
        let reply = try await post(request, body: ["systemInstruction": ["parts": [["text": system]]], "contents": messages,
                                                   "generationConfig": ["maxOutputTokens": 2048]]) { json in
            (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined()
        }
        messages.append(["role": "model", "parts": [["text": reply]]])
        return reply
    }

    private func openAICompatible(_ text: String, image: Data?) async throws -> String {
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions"), url.host != nil else { throw Failure(message: "The server address isn't valid.") }
        if messages.isEmpty { messages.append(["role": "system", "content": system]) }
        dropOldImages(key: "content", isImage: { $0["type"] as? String == "image_url" })
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let image { content.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + image.base64EncodedString()]]) }
        messages.append(["role": "user", "content": content])
        var request = URLRequest(url: url)
        if !config.serverKey.isEmpty { request.setValue("Bearer " + config.serverKey, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 300
        let reply = try await post(request, body: ["model": config.serverModel, "messages": messages]) { json in
            ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        messages.append(["role": "assistant", "content": reply])
        return reply
    }

    /// Pictures from earlier steps cost tokens and say nothing new.
    private func dropOldImages(key: String, isImage: ([String: Any]) -> Bool) {
        for index in messages.indices {
            guard var parts = messages[index][key] as? [[String: Any]] else { continue }
            parts.removeAll(where: isImage)
            messages[index][key] = parts
        }
    }

    private func post(_ base: URLRequest, body: [String: Any], reply: @escaping ([String: Any]) -> String?) async throws -> String {
        var request = base
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if request.timeoutInterval == 60 { request.timeoutInterval = 120 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let text = reply(json) { return continuation.resume(returning: text) }
                let detail = (json["error"] as? [String: Any])?["message"] as? String
                    ?? error?.localizedDescription ?? "The model didn't answer (\(status))."
                continuation.resume(throwing: Failure(message: detail))
            }
            self.task = task
            task.resume()
        }
    }

    // MARK: Gemini CLI

    static var geminiCLI: URL? {
        [NSHomeDirectory() + "/.local/bin/gemini", "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini",
         NSHomeDirectory() + "/.npm-global/bin/gemini"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Gemini CLI keeps a Google sign-in here once someone has signed in.
    static var geminiSignedIn: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.gemini/oauth_creds.json")
    }

    private func geminiCLI(_ text: String, image: Data?) async throws -> String {
        guard let cli = Self.geminiCLI else { throw Failure(message: "Gemini CLI isn't installed.") }
        var prompt = system + "\n\n" + transcript.joined(separator: "\n\n") + "\n\nPerson: " + text
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("islet-gemini", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let image {
            let file = folder.appendingPathComponent("screen.png")
            try image.write(to: file)
            prompt += "\n\nThe screen right now: @screen.png"
        }
        let model = config.geminiModel.isEmpty ? "gemini-flash-latest" : config.geminiModel
        let output = try await run(cli, ["-m", model, "-p", prompt, "--output-format", "json"], in: folder)
        let json = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
        let reply = (json?["response"] as? String) ?? output
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Gemini didn't answer. Sign in again in Settings → Dynamic Island → Assistant.")
        }
        transcript.append("Person: \(text)\nYou: \(reply)")
        return reply
    }

    private func run(_ tool: URL, _ arguments: [String], in folder: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.currentDirectoryURL = folder
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                continuation.resume(returning: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
            do { try process.run(); self.process = process } catch {
                continuation.resume(throwing: Failure(message: "Gemini CLI didn't start."))
            }
        }
    }
}

/// `claude -p` kept open for a whole task, as Atticus starts it: each step is
/// one more user message on stdin and ends at Claude Code's `result` event, so
/// the conversation stays in one session and the startup cost is paid once.
final class ClaudeCodeSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var waiting: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    init(model: String, effort: String, system: String) throws {
        guard let claude = AssistantService.claudeCLI else { throw AssistantBrain.Failure(message: "Claude Code isn't installed.") }
        process.executableURL = claude
        // No tools, settings, MCP servers or saved sessions: Islet's own list
        // of actions is the only way anything happens on the Mac.
        process.arguments = ["-p", "--model", model, "--effort", effort,
                             "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--tools", "", "--setting-sources", "", "--no-session-persistence",
                             "--strict-mcp-config", "--disable-slash-commands", "--system-prompt", system]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        AssistantService.useClaudePlan(&environment)
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { handle.readabilityHandler = nil; self.resume(.failure(AssistantBrain.Failure(message: "Claude Code stopped."))); return }
            self.lock.lock(); self.buffer.append(chunk); self.lock.unlock()
            self.drain()
        }
        try process.run()
    }

    func send(_ text: String, image: Data?) async throws -> String {
        var content: [[String: Any]] = []
        if let image { content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.base64EncodedString()]]) }
        content.append(["type": "text", "text": text])
        let line = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": content]])
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); waiting = continuation; lock.unlock()
            input.fileHandleForWriting.write(line + Data("\n".utf8))
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        resume(.failure(AssistantBrain.Failure(message: "Stopped.")))
    }

    private func drain() {
        lock.lock()
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[..<newline])
            buffer.removeSubrange(...newline)
        }
        lock.unlock()
        for line in lines {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  event["type"] as? String == "result" else { continue }
            if event["is_error"] as? Bool == true {
                resume(.failure(AssistantBrain.Failure(message: (event["result"] as? String)
                    ?? "Claude couldn't answer. Check the connection in Settings → Dynamic Island → Assistant.")))
            } else {
                resume(.success(event["result"] as? String ?? ""))
            }
        }
    }

    private func resume(_ result: Result<String, Error>) {
        lock.lock(); let continuation = waiting; waiting = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}
