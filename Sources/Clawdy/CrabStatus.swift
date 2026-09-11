import AppKit

/// Everything a crab can be. One value per session, chosen by StatusResolver using the plan's
/// priority order: permission > question > error > done-not-seen > working/tool > dormant.
enum CrabStatus: Equatable {
    case working            // generating, or a tool is running normally
    case usingTool          // a specific tool is running (shows a tool badge)
    case needsPermission    // waiting for you to approve something
    case needsQuestion      // finished its turn by asking you a question
    case doneUnseen         // finished, and you have not looked yet
    case dormant            // no activity for a long time
    case error              // an API error ended the turn

    /// True while the session is actively doing work (legs should march).
    var isBusy: Bool { self == .working || self == .usingTool }

    /// True when the crab wants your attention.
    var needsYou: Bool { self == .needsPermission || self == .needsQuestion }
}

/// How to draw the badge for a status: SF Symbol name + circle color. Nil = no badge.
struct BadgeStyle {
    let symbol: String
    let color: NSColor

    static func forStatus(_ status: CrabStatus) -> BadgeStyle? {
        switch status {
        case .needsPermission: return BadgeStyle(symbol: "exclamationmark", color: Palette.bad)
        case .needsQuestion:   return BadgeStyle(symbol: "questionmark", color: Palette.ask)
        case .error:           return BadgeStyle(symbol: "xmark", color: Palette.bad)
        case .doneUnseen:      return BadgeStyle(symbol: "checkmark", color: Palette.ok)
        case .usingTool:       return BadgeStyle(symbol: "wrench.and.screwdriver.fill", color: Palette.tool)
        case .dormant:         return BadgeStyle(symbol: "zzz", color: Palette.sleep)
        case .working:         return nil
        }
    }

    enum Palette {
        static let ok = NSColor(srgbRed: 0.18, green: 0.62, blue: 0.36, alpha: 1)
        static let bad = NSColor(srgbRed: 0.85, green: 0.27, blue: 0.25, alpha: 1)
        static let ask = NSColor(srgbRed: 0.85, green: 0.60, blue: 0.17, alpha: 1)
        static let tool = NSColor(srgbRed: 0.36, green: 0.42, blue: 0.52, alpha: 1)
        static let sleep = NSColor(srgbRed: 0.48, green: 0.52, blue: 0.60, alpha: 1)
    }
}
