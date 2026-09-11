import Foundation

/// A read of a session's JSONL transcript. Incremental: full file on first sight, then only the
/// bytes appended since last time. Only ever touched from SessionStore's background queue.
final class TranscriptReader {
    let sessionId: String
    private(set) var path: String?
    private var offset: UInt64 = 0
    private var leftover = ""

    // Signals folded from the record stream.
    private(set) var idle = false                 // last turn ended (real end_turn with text)
    private(set) var idleSince: Double = 0        // epoch seconds of that end_turn (the "doneAt")
    private(set) var title: String?
    private(set) var lastEventTime: Double = 0
    private(set) var errored = false              // api_error not yet superseded by a new turn
    private(set) var endedWithQuestion = false    // idle turn that ends by asking you something
    private(set) var lastToolName = ""
    private(set) var toolUnanswered = false        // a tool_use with no matching tool_result yet
    private(set) var lastToolUseTime: Double = 0
    private(set) var permissionModeIsAuto = false  // "auto"/"bypassPermissions"/"acceptEdits"

    /// Directory holding this session's sub-agent transcripts, once the main file is located.
    var subagentsDirectory: String? {
        guard let path else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        return "\(dir)/\(sessionId)/subagents"
    }

    init(sessionId: String) { self.sessionId = sessionId }

    private func locate() -> String? {
        if let path, FileManager.default.fileExists(atPath: path) { return path }
        let projects = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        guard let slugs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return nil }
        for slug in slugs {
            let candidate = "\(projects)/\(slug)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: candidate) { path = candidate; return candidate }
        }
        return nil
    }

    func refresh() {
        guard let path = locate(), let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; leftover = "" }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        let text = leftover + chunk
        leftover = ""
        if let lastNewline = text.lastIndex(of: "\n") {
            let complete = text[..<lastNewline]
            leftover = String(text[text.index(after: lastNewline)...])
            for line in complete.split(separator: "\n", omittingEmptySubsequences: true) { consume(String(line)) }
        } else {
            leftover = text
        }
    }

    private func consume(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        var recordTime: Double = 0
        if let ts = obj["timestamp"] as? String, let epoch = Self.epoch(ts) {
            recordTime = epoch
            lastEventTime = max(lastEventTime, epoch)
        }

        switch type {
        case "custom-title":
            if let t = obj["customTitle"] as? String, !t.isEmpty { title = t }
        case "ai-title":
            if let t = obj["aiTitle"] as? String, !t.isEmpty, title == nil { title = t }
        case "user":
            // A new prompt or a returned tool result: Claude has more to do.
            idle = false
            idleSince = 0
            errored = false
            endedWithQuestion = false
            if let mode = obj["permissionMode"] as? String { setPermissionMode(mode) }
            if isToolResult(obj) { toolUnanswered = false }
        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return }
            let stop = message["stop_reason"] as? String
            let content = message["content"] as? [[String: Any]] ?? []
            let blockTypes = Set(content.compactMap { $0["type"] as? String })

            if let tool = content.last(where: { $0["type"] as? String == "tool_use" }),
               let name = tool["name"] as? String {
                lastToolName = name.lowercased()
                toolUnanswered = true
                lastToolUseTime = lastEventTime
                if name == "AskUserQuestion" { endedWithQuestion = true }
            }

            if stop == "tool_use" {
                idle = false
                idleSince = 0
            } else if stop == "end_turn" {
                // A thinking-only end_turn is an intermediate extended-thinking event, not the real
                // end of a turn — ignore it so the crab doesn't flip to idle mid-thought.
                let realEnd = blockTypes.contains("text") || !blockTypes.isSubset(of: ["thinking"])
                if realEnd {
                    idle = true
                    idleSince = recordTime > 0 ? recordTime : lastEventTime
                    if blockTypes.contains("text") {
                        endedWithQuestion = endedWithQuestion || Self.lastTextIsQuestion(content)
                    }
                }
            }
        case "system":
            if obj["subtype"] as? String == "api_error" {
                errored = true
                if !idle { idle = true; idleSince = recordTime > 0 ? recordTime : lastEventTime }
            }
        default:
            break
        }
    }

    private func setPermissionMode(_ mode: String) {
        permissionModeIsAuto = ["auto", "bypassPermissions", "acceptEdits", "plan"].contains(mode)
    }

    private func isToolResult(_ obj: [String: Any]) -> Bool {
        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            return content.contains { $0["type"] as? String == "tool_result" }
        }
        return false
    }

    private static func lastTextIsQuestion(_ content: [[String: Any]]) -> Bool {
        guard let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private static func epoch(_ iso: String) -> Double? {
        if let d = formatter.date(from: iso) { return d.timeIntervalSince1970 }
        return ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970
    }
}
