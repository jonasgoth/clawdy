import Foundation

/// Finds a session's currently-active sub-agents. Each sub-agent has its own transcript at
/// <session>/subagents/agent-*.jsonl. We treat one as active while its file is still being
/// appended to (recent modification time); a finished sub-agent's file goes quiet.
enum SubagentWatcher {
    static let activeWindow: TimeInterval = 15   // seconds since last write to count as running

    static func activeAgents(in directory: String, now: Double) -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var out: [String] = []
        for file in files where file.hasPrefix("agent-") && file.hasSuffix(".jsonl") {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            if now - modified <= activeWindow {
                out.append(String(file.dropLast(6)))   // strip ".jsonl"
            }
        }
        return out
    }
}
