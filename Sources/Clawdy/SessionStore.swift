import AppKit

/// Polls every second on a background queue and keeps the playpen's crabs in sync with live Claude
/// sessions: registry sessions (CLI + Desktop Code), their sub-agents, and Cowork sessions.
/// Resolves each session's status from transcript + hook signals, applies the "seen" rule, and
/// hands the scene a snapshot on the main thread. All file I/O stays off the main thread so the
/// crabs never stutter.
final class SessionStore {
    struct CrabSnapshot { let id: String; let title: String; let color: NSColor; let status: CrabStatus }
    struct BabySnapshot { let id: String; let parentId: String; let color: NSColor }
    struct Snapshot { var crabs: [CrabSnapshot] = []; var babies: [BabySnapshot] = [] }
    struct Row { let title: String; let status: CrabStatus }

    static let dormantAfter: TimeInterval = 600      // 10 minutes with no activity
    static let permissionGuessDelay: TimeInterval = 6
    static let bashPermissionDelay: TimeInterval = 600
    static let lookDuration: TimeInterval = 1.5      // how long the chat must be in front to count as seen
    static let coworkFallbackLook: TimeInterval = 3  // without Accessibility we can't tell which Cowork chat is up

    private weak var scene: PlaypenScene?
    private let seen: SeenDetector
    private let queue = DispatchQueue(label: "app.clawdy.store", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Background-queue state.
    private var readers: [String: TranscriptReader] = [:]
    private let desktopMeta = DesktopMetaIndex()
    private let cowork = CoworkWatcher()
    private var ttyByPid: [Int: String?] = [:]
    private var seenDoneAt: [String: Double] = [:]   // session id → the finish time that has been seen

    /// Main-thread copy for the menu.
    private(set) var rows: [Row] = []
    /// Called on the main thread after every update (menu bar count, etc.).
    var onUpdate: (() -> Void)?

    private static let debug = ProcessInfo.processInfo.environment["CLAWDY_DEBUG"] == "1"
    private var lastLogged: [String: CrabStatus] = [:]
    private func log(_ message: String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(("[clawdy] " + message + "\n").data(using: .utf8)!)
    }

    init(scene: PlaypenScene, seen: SeenDetector) {
        self.scene = scene
        self.seen = seen
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: - Tick (background queue)

    private func tick() {
        let now = Date().timeIntervalSince1970
        defer {
            if Self.debug {
                let ms = Int((Date().timeIntervalSince1970 - now) * 1000)
                if ms > 30 { log("slow tick: \(ms) ms") }
            }
        }
        let look = seen.snapshot()
        let hooks = HookBridge.scan()
        let live = SessionRegistry.scan()
        desktopMeta.refresh(now: now)
        let coworkSessions = cowork.scan(now: now)

        let wantsTTY = live.contains { $0.entrypoint == "cli" }
        DispatchQueue.main.async { [seen] in seen.wantsTerminalTTY = wantsTTY }

        var snapshot = Snapshot()
        var newRows: [Row] = []
        var liveIds: Set<String> = []

        for session in live.sorted(by: { $0.startedAt < $1.startedAt }) {
            let meta = desktopMeta.meta(for: session.sessionId)
            if meta?.isArchived == true { continue }          // archived chats walk off
            liveIds.insert(session.sessionId)

            let reader = reader(for: session.sessionId)
            reader.refresh()
            var status = resolve(reader: reader, hook: hooks[session.sessionId], now: now)

            if status == .doneUnseen {
                let doneAt = reader.idleSince > 0 ? reader.idleSince : reader.lastEventTime
                let seenNow = seenDoneAt[session.sessionId] == doneAt
                    || isSeen(session: session, doneAt: doneAt, meta: meta, look: look, now: now)
                if Self.debug, lastLogged[session.sessionId] != (seenNow ? .doneSeen : .doneUnseen) {
                    let lf = meta.map { Int($0.lastFocusedAt - doneAt) } ?? -999999
                    let cf = look.claudeFrontSince.map { Int(now - $0) } ?? -1
                    log("seen-check \(session.sessionId.prefix(8)): front=\(look.frontBundleId ?? "nil") claudeFrontFor=\(cf)s focusedChat=\(desktopMeta.mostRecentlyFocusedId?.prefix(8) ?? "nil") lastFocused-doneAt=\(lf)s canSee=\(look.canSee) -> \(seenNow ? "SEEN" : "unseen")")
                }
                if seenNow {
                    seenDoneAt[session.sessionId] = doneAt
                    status = .doneSeen
                }
            } else if status.isBusy {
                seenDoneAt[session.sessionId] = nil           // new turn → next finish is unseen again
            }

            let title = meta?.title ?? reader.title ?? session.name
            let color = CrabPalette.color(for: session.projectName)
            snapshot.crabs.append(CrabSnapshot(id: session.sessionId, title: title, color: color, status: status))
            newRows.append(Row(title: title, status: status))

            if status.isBusy, let dir = reader.subagentsDirectory {
                for agentId in SubagentWatcher.activeAgents(in: dir, now: now) {
                    snapshot.babies.append(BabySnapshot(id: agentId, parentId: session.sessionId, color: color))
                }
            }
        }

        for session in coworkSessions {
            liveIds.insert(session.sessionId)
            var status = session.status
            if status == .doneUnseen {
                let doneAt = session.lastActivity
                if seenDoneAt[session.sessionId] == doneAt
                    || isCoworkSeen(title: session.title, doneAt: doneAt, look: look, now: now) {
                    seenDoneAt[session.sessionId] = doneAt
                    status = .doneSeen
                }
            } else if status.isBusy {
                seenDoneAt[session.sessionId] = nil
            }
            let color = CrabPalette.color(for: session.projectName)
            snapshot.crabs.append(CrabSnapshot(id: session.sessionId, title: session.title, color: color, status: status))
            newRows.append(Row(title: session.title, status: status))
        }

        if Self.debug {
            for c in snapshot.crabs where lastLogged[c.id] != c.status {
                lastLogged[c.id] = c.status
                log("\(c.id.prefix(8)) \(c.title.prefix(28)) -> \(c.status)")
            }
            for id in Set(lastLogged.keys).subtracting(liveIds) { lastLogged[id] = nil; log("\(id.prefix(8)) gone") }
        }
        for id in Set(readers.keys).subtracting(liveIds) { readers[id] = nil }
        for id in Set(seenDoneAt.keys).subtracting(liveIds) { seenDoneAt[id] = nil }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rows = newRows
            self.scene?.apply(snapshot)
            self.onUpdate?()
        }
    }

    private func reader(for id: String) -> TranscriptReader {
        if let r = readers[id] { return r }
        let r = TranscriptReader(sessionId: id)
        readers[id] = r
        return r
    }

    // MARK: - Status

    /// Turn transcript + hook signals into one status, using the plan's priority order.
    private func resolve(reader: TranscriptReader, hook: HookBridge.Event?, now: Double) -> CrabStatus {
        // Hooks are ground truth when present and at least as fresh as the transcript.
        if let hook, hook.ts + 1 >= reader.lastEventTime {
            switch hook.state {
            case "permission": return .needsPermission
            case "tool": return .usingTool
            default: break
            }
        }

        let age = now - (reader.lastEventTime == 0 ? now : reader.lastEventTime)

        // Permission guess from files: a tool_use left unanswered too long, unless auto-approved.
        if reader.toolUnanswered, !reader.permissionModeIsAuto, !isReadOnly(reader.lastToolName) {
            let sinceTool = now - reader.lastToolUseTime
            let threshold = reader.lastToolName == "bash" ? Self.bashPermissionDelay : Self.permissionGuessDelay
            if sinceTool > threshold { return .needsPermission }
        }

        if reader.idle {
            if reader.endedWithQuestion { return .needsQuestion }
            if reader.errored { return .error }
            if age > Self.dormantAfter { return .dormant }
            return .doneUnseen
        }

        if reader.toolUnanswered, !isReadOnly(reader.lastToolName) { return .usingTool }
        if age > Self.dormantAfter { return .dormant }
        return .working
    }

    private static let readOnlyTools: Set<String> = ["read", "glob", "grep", "todowrite", "webfetch", "websearch"]
    private func isReadOnly(_ tool: String) -> Bool { Self.readOnlyTools.contains(tool) }

    // MARK: - The "seen" rule

    /// Has the user actually looked at this chat since it finished? Never true from touching the
    /// crab. Never true while the screen is locked or asleep.
    private func isSeen(session: LiveSession, doneAt: Double, meta: DesktopMetaIndex.Meta?,
                        look: SeenDetector.Snapshot, now: Double) -> Bool {
        guard look.canSee, doneAt > 0 else { return false }

        if session.entrypoint == "cli" {
            // Terminal: the front terminal's selected tab must be this session's tty.
            guard let since = look.terminalFrontSince,
                  let tty = tty(for: session.pid),
                  look.terminalSelectedTTY == tty else { return false }
            return max(since, doneAt) + Self.lookDuration <= now
        }

        // Desktop Code tab.
        // 1. You clicked into the chat after it finished (Desktop writes lastFocusedAt).
        if let meta, meta.lastFocusedAt >= doneAt - 0.5 { return true }
        // 2. It was already the open chat, and the Claude app has been in front long enough after
        //    the finish for you to have seen it.
        guard let since = look.claudeFrontSince,
              desktopMeta.mostRecentlyFocusedId == session.sessionId else { return false }
        return max(since, doneAt) + Self.lookDuration <= now
    }

    private func isCoworkSeen(title: String, doneAt: Double, look: SeenDetector.Snapshot, now: Double) -> Bool {
        guard look.canSee, doneAt > 0, let since = look.claudeFrontSince else { return false }
        if look.axTrusted {
            // With Accessibility we can read the focused window's title and match this chat.
            guard let windowTitle = look.claudeWindowTitle,
                  windowTitle.localizedCaseInsensitiveContains(title) else { return false }
            return max(since, doneAt) + Self.lookDuration <= now
        }
        // Without it: Claude in front for a while after the finish counts. Rougher, but honest.
        return max(since, doneAt) + Self.coworkFallbackLook <= now
    }

    private func tty(for pid: Int) -> String? {
        if let cached = ttyByPid[pid] { return cached }
        let tty = SeenDetector.tty(ofPid: pid)
        ttyByPid[pid] = tty
        return tty
    }
}
