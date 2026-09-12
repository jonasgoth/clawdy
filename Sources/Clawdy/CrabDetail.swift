import Foundation

/// What the hover bubble says about a session beyond its status: where it lives, which tool it
/// has in hand, and when its current state began. Built by SessionStore, read by CrabNode.
struct CrabDetail: Equatable {
    /// Project folder name, e.g. "clawdy".
    var project = ""
    /// Where the session runs: "Terminal", "Claude app" or "Cowork".
    var source = ""
    /// The tool running or waiting for approval, in its own spelling ("Bash", "Edit").
    /// Nil while Claude is thinking or the turn is over.
    var tool: String?
    /// Epoch seconds when the current state began: the turn started, the tool asked for approval,
    /// or the turn ended. 0 when unknown.
    var since: Double = 0
    /// Auto / accept-edits / bypass permission mode: it will not stop to ask.
    var autoMode = false

    /// The bubble's lines, top to bottom. Empty lines are left out.
    func lines(status: CrabStatus, helpers: Int, now: Double) -> [String] {
        var place: [String] = []
        if !project.isEmpty { place.append(project) }
        if !source.isEmpty { place.append(source) }
        if autoMode { place.append("auto") }
        if helpers > 0 { place.append(helpers == 1 ? "1 helper" : "\(helpers) helpers") }
        return [headline(status: status), timing(status: status, now: now), place.joined(separator: " · ")]
            .filter { !$0.isEmpty }
    }

    private func headline(status: CrabStatus) -> String {
        switch status {
        case .working, .usingTool: return tool.map { "Running \($0)" } ?? "Thinking"
        case .needsPermission:     return tool.map { "Wants to run \($0)" } ?? "Waiting for your OK"
        case .needsQuestion:       return "Asked you a question"
        case .doneUnseen:          return "Done. Take a look"
        case .doneSeen:            return "Done"
        case .dormant:             return "Napping"
        case .error:               return "Hit an error"
        }
    }

    private func timing(status: CrabStatus, now: Double) -> String {
        guard since > 0 else { return "" }
        let span = Self.span(max(now - since, 0))
        switch status {
        case .working, .usingTool:             return "Busy for \(span)"
        case .needsPermission, .needsQuestion: return "Waiting \(span)"
        case .doneUnseen, .doneSeen:           return "Finished \(span) ago"
        case .error:                           return "Failed \(span) ago"
        case .dormant:                         return "Quiet for \(span)"
        }
    }

    /// "12 s", "3 min", "1 h 12 min".
    static func span(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h) h" : "\(h) h \(rest) min"
    }

    /// "Bash" stays "Bash"; an MCP tool like "mcp__trello__read_board" becomes "read board".
    static func toolLabel(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let parts = raw.components(separatedBy: "__")
        guard parts.count >= 3, let last = parts.last, !last.isEmpty else { return raw }
        return last.replacingOccurrences(of: "_", with: " ")
    }
}
