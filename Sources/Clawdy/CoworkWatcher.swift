import Foundation

/// Cowork sessions run in a sandbox and do NOT appear in ~/.claude/sessions. They live under
/// ~/Library/Application Support/Claude/local-agent-mode-sessions/<acct>/<org>/local_*.json, with
/// a sibling folder holding audit.jsonl. Hooks don't fire for them, so status comes from the audit
/// log. We only show a crab while a session is genuinely active, to avoid ghosts from old runs.
enum CoworkWatcher {
    struct Session { let sessionId: String; let title: String; let projectName: String; let status: CrabStatus }

    /// A Cowork crab is only shown if its audit log changed this recently.
    static let liveWindow: TimeInterval = 300

    static var baseDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    static func scan(now: Double = Date().timeIntervalSince1970) -> [Session] {
        let fm = FileManager.default
        guard let metas = metadataFiles() else { return [] }
        var out: [Session] = []

        for meta in metas {
            guard let data = fm.contents(atPath: meta),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = (obj["cliSessionId"] as? String) ?? (obj["sessionId"] as? String) else { continue }
            if obj["isArchived"] as? Bool == true { continue }

            // audit.jsonl sits in the folder named like the metadata file (minus .json).
            let folder = String(meta.dropLast(5))
            let audit = "\(folder)/audit.jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: audit),
                  let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  now - modified <= liveWindow else { continue }

            let tail = tailString(ofPath: audit, maxBytes: 48_000)
            let outcome = interpret(tail: tail)
            if outcome.ended { continue }        // session finished — no crab

            let title = (obj["title"] as? String) ?? "Cowork"
            out.append(Session(sessionId: "cowork:\(sessionId)", title: title,
                               projectName: "cowork-\(title)", status: outcome.status))
        }
        return out
    }

    private static func metadataFiles() -> [String]? {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(atPath: baseDir) else { return nil }
        var files: [String] = []
        for account in accounts {
            let accountPath = "\(baseDir)/\(account)"
            guard let orgs = try? fm.contentsOfDirectory(atPath: accountPath) else { continue }
            for org in orgs {
                let orgPath = "\(accountPath)/\(org)"
                guard let entries = try? fm.contentsOfDirectory(atPath: orgPath) else { continue }
                for entry in entries where entry.hasPrefix("local_") && entry.hasSuffix(".json") {
                    files.append("\(orgPath)/\(entry)")
                }
            }
        }
        return files
    }

    /// Read status from the audit tail: pending permission, ended, or working/done.
    private static func interpret(tail: String) -> (status: CrabStatus, ended: Bool) {
        var pendingPermission = false
        var ended = false
        var erroredEnd = false
        var lastWasAssistantText = false

        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "system":
                switch obj["subtype"] as? String {
                case "permission_request": pendingPermission = true
                case "permission_response", "permission_auto_approved": pendingPermission = false
                default: break
                }
                lastWasAssistantText = false
            case "result":
                ended = true
                erroredEnd = (obj["is_error"] as? Bool == true) || (obj["stop_reason"] as? String == "error")
            case "assistant":
                if let message = obj["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    lastWasAssistantText = content.contains { $0["type"] as? String == "text" }
                }
            case "user":
                lastWasAssistantText = false
            default:
                break
            }
        }

        if ended { return (erroredEnd ? .error : .doneUnseen, true) }
        if pendingPermission { return (.needsPermission, false) }
        if lastWasAssistantText { return (.doneUnseen, false) }
        return (.working, false)
    }

    private static func tailString(ofPath path: String, maxBytes: Int) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        var text = String(data: data, encoding: .utf8) ?? ""
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])   // drop the partial first line
        }
        return text
    }
}
