import AppKit

/// Polls every second on a background queue and keeps the playpen's crabs in sync with live Claude
/// sessions: registry sessions (CLI + Desktop Code), their sub-agents, and Cowork sessions.
/// Resolves each session's status from transcript + hook signals, applies the "seen" rule, and
/// hands the scene a snapshot on the main thread. All file I/O stays off the main thread so the
/// crabs never stutter.
final class SessionStore {
    struct CrabSnapshot { let id: String; let title: String; let color: NSColor; let status: CrabStatus; var detail = CrabDetail() }
    struct BabySnapshot { let id: String; let parentId: String; let color: NSColor }
    struct Snapshot { var crabs: [CrabSnapshot] = []; var babies: [BabySnapshot] = [] }
    struct Row { let title: String; let status: CrabStatus }

    static let dormantAfter: TimeInterval = 600      // 10 minutes with no activity
    static let hideAfterIdle: TimeInterval = 300     // idle this long → the pet leaves (menu still lists it)
    static let sleepAfterSeen: TimeInterval = 60     // a crab you have looked at rests this long, then sleeps
    static let permissionGuessDelay: TimeInterval = 6
    static let bashPermissionDelay: TimeInterval = 600
    static let lookDuration: TimeInterval = 1.5      // how long the chat must be in front to count as seen
    static let storageMargin: TimeInterval = 2       // Desktop's record must postdate a finish by this much to speak for it
    static let coworkFallbackLook: TimeInterval = 3  // without Accessibility we can't tell which Cowork chat is up

    private weak var scene: PlaypenScene?
    private let seen: SeenDetector
    private let queue = DispatchQueue(label: "app.clawdy.store", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Background-queue state.
    private var readers: [String: TranscriptReader] = [:]
    private let desktopMeta = DesktopMetaIndex()
    private let cowork = CoworkWatcher()
    private let desktopStorage = DesktopLocalStorage()
    private var ttyByPid: [Int: String?] = [:]
    private let watcher = FileWatcher(roots: [DesktopMetaIndex.baseDir, CoworkWatcher.baseDir, DesktopLocalStorage.baseDir])
    private var coworkCache: [CoworkWatcher.Session] = []
    private var lastDesktopScan: Double = 0
    private var lastCoworkScan: Double = 0
    private var lastStorageScan: Double = 0
    static let fallbackRescan: TimeInterval = 30
    static let storageRescan: TimeInterval = 2       // FSEvents stays quiet for appends to Desktop's storage log, so poll it (a few stats)
    private var seenDoneAt: [String: Double] = [:]   // session id → the finish time that has been seen
    private var seenAt: [String: Double] = [:]       // session id → when you first saw that finish

    /// Main-thread copy for the menu.
    private(set) var rows: [Row] = []
    /// Called on the main thread after every update (menu bar count, etc.).
    var onUpdate: (() -> Void)?

    private static let debug = ProcessInfo.processInfo.environment["CLAWDY_DEBUG"] == "1"
    private var lastLogged: [String: CrabStatus] = [:]
    private var lastSeenCheckLog: [String: Double] = [:]   // debug: last time an unseen crab's inputs were logged
    private static let stampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    private func log(_ message: String) {
        guard Self.debug else { return }
        let stamp = Self.stampFormatter.string(from: Date())
        FileHandle.standardError.write(("[clawdy] " + stamp + " " + message + "\n").data(using: .utf8)!)
    }

    init(scene: PlaypenScene, seen: SeenDetector) {
        self.scene = scene
        self.seen = seen
    }

    func start() {
        watcher.start(queue: queue)
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
        // Folder trees are only rescanned when FSEvents saw a change (plus a slow safety rescan).
        if watcher.consume(DesktopMetaIndex.baseDir) || now - lastDesktopScan > Self.fallbackRescan {
            if Self.debug, now - lastDesktopScan <= Self.fallbackRescan { log("fs: meta folder changed") }
            desktopMeta.refresh(now: now)
            lastDesktopScan = now
        }
        if watcher.consume(CoworkWatcher.baseDir) || now - lastCoworkScan > Self.fallbackRescan {
            coworkCache = cowork.scan(now: now)
            lastCoworkScan = now
        }
        if watcher.consume(DesktopLocalStorage.baseDir) || now - lastStorageScan > Self.storageRescan {
            let before = desktopStorage.state?.writtenAt
            desktopStorage.refresh()
            if Self.debug, let w = desktopStorage.state?.writtenAt, w != before { log("storage record now from \(Self.stampFormatter.string(from: Date(timeIntervalSince1970: w)))") }
            lastStorageScan = now
        }
        let coworkSessions = coworkCache

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

            if status.isUnseenFinish {
                // When it stopped needing to run: the end of the turn, or the question tool it is
                // parked on. (Not lastEventTime: Desktop keeps appending bookkeeping records with
                // fresh timestamps, which would move the target and un-see the crab.)
                let doneAt = reader.idleSince > 0 ? reader.idleSince
                    : (reader.toolUnanswered ? reader.lastToolUseTime : reader.lastEventTime)
                let seenNow: Bool
                switch desktopVerdict(meta: meta, doneAt: doneAt, look: look, now: now) {
                case .seen:   seenNow = true                      // Desktop's own unread dot decides…
                case .unseen: seenNow = false; seenDoneAt[session.sessionId] = nil   // …and overrules an earlier guess
                case .notYet: seenNow = seenDoneAt[session.sessionId] == doneAt      // no dot, but you have not looked yet
                case nil:     seenNow = seenDoneAt[session.sessionId] == doneAt      // Desktop's record is too old to say
                    || isSeen(session: session, doneAt: doneAt, meta: meta, look: look, now: now)
                }
                let stuckUnseen = Self.debug && !seenNow && now - (lastSeenCheckLog[session.sessionId] ?? 0) > 5
                if Self.debug, stuckUnseen || (lastLogged[session.sessionId] != (seenNow ? .doneSeen : status)
                   && !(seenNow && lastLogged[session.sessionId] == .dormant)) {
                    lastSeenCheckLog[session.sessionId] = now
                    let lf = meta.map { Int($0.lastFocusedAt - doneAt) } ?? -999999
                    let cf = look.claudeFrontSince.map { Int(now - $0) } ?? -1
                    let ls = desktopStorage.state
                    let unread = meta.map { ls?.unreadIds.contains($0.localId) ?? false } ?? false
                    let onScreen = meta.map { ls?.currentSessionId == $0.localId } ?? false
                    let lsAge = ls.map { Int($0.writtenAt - doneAt) } ?? -999999
                    let verdict = desktopVerdict(meta: meta, doneAt: doneAt, look: look, now: now).map { "\($0)" } ?? "nil"
                    log("seen-check \(session.sessionId.prefix(8)): verdict=\(verdict) doneAt=\(Self.stampFormatter.string(from: Date(timeIntervalSince1970: doneAt))) lastFocusedAt=\(meta.map { Self.stampFormatter.string(from: Date(timeIntervalSince1970: $0.lastFocusedAt)) } ?? "nil") front=\(look.frontBundleId ?? "nil") claudeFrontFor=\(cf)s focusedChat=\(desktopMeta.mostRecentlyFocusedId?.prefix(8) ?? "nil") lastFocused-doneAt=\(lf)s desktopUnread=\(unread) desktopOnScreen=\(onScreen) storageWritten-doneAt=\(lsAge)s canSee=\(look.canSee) -> \(seenNow ? "SEEN" : "unseen")")
                }
                if seenNow {
                    seenDoneAt[session.sessionId] = doneAt
                    status = .doneSeen
                }
            } else if status.isBusy {
                seenDoneAt[session.sessionId] = nil           // new turn → next finish is unseen again
            }
            status = restOrSleep(id: session.sessionId, status: status, now: now)

            let title = meta?.title ?? reader.title ?? session.name
            let color = CrabPalette.standard
            let idleFor = status.isBusy ? 0 : now - (reader.lastEventTime == 0 ? now : reader.lastEventTime)
            if !status.isBusy, !status.needsYou, idleFor > Self.hideAfterIdle {
                newRows.append(Row(title: title, status: .dormant))   // listed, but the pet has left
                if Self.debug { lastLogged[session.sessionId] = status }   // keeps the seen-check log quiet
                continue
            }
            snapshot.crabs.append(CrabSnapshot(id: session.sessionId, title: title, color: color, status: status,
                                               detail: detail(for: session, reader: reader, status: status)))
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
            if status.isUnseenFinish {
                let doneAt = session.lastActivity
                if seenDoneAt[session.sessionId] == doneAt
                    || isCoworkSeen(title: session.title, doneAt: doneAt, look: look, now: now) {
                    seenDoneAt[session.sessionId] = doneAt
                    status = .doneSeen
                }
            } else if status.isBusy {
                seenDoneAt[session.sessionId] = nil
            }
            status = restOrSleep(id: session.sessionId, status: status, now: now)
            if !status.isBusy, !status.needsYou, now - session.lastActivity > Self.hideAfterIdle {
                newRows.append(Row(title: session.title, status: .dormant))
                continue
            }
            let color = CrabPalette.standard
            snapshot.crabs.append(CrabSnapshot(id: session.sessionId, title: session.title, color: color, status: status,
                                               detail: CrabDetail(project: session.projectName, source: "Cowork",
                                                                  since: session.lastActivity)))
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
        for id in Set(seenAt.keys).subtracting(liveIds) { seenAt[id] = nil }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rows = newRows
            self.scene?.apply(snapshot)
            self.onUpdate?()
        }
    }

    /// What the hover bubble says: the project, where it runs, the tool in hand, and when the
    /// current state began (the turn started, the tool asked for approval, or the turn ended).
    private func detail(for session: LiveSession, reader: TranscriptReader, status: CrabStatus) -> CrabDetail {
        var d = CrabDetail()
        d.project = session.projectName
        d.source = session.entrypoint == "cli" ? "Terminal" : "Claude app"
        d.autoMode = reader.permissionModeIsAuto
        if reader.toolUnanswered || status == .usingTool, !reader.lastToolLabel.isEmpty {
            d.tool = CrabDetail.toolLabel(reader.lastToolLabel)
        }
        let doneAt = reader.idleSince > 0 ? reader.idleSince : reader.lastEventTime
        switch status {
        case .working, .usingTool:           d.since = reader.turnStartedAt
        case .needsPermission:               d.since = reader.lastToolUseTime
        case .needsQuestion:                 d.since = reader.toolUnanswered ? reader.lastToolUseTime : doneAt
        case .doneUnseen, .doneSeen, .error: d.since = doneAt
        case .dormant:                       d.since = reader.lastEventTime
        }
        return d
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
        let hookState = hook.flatMap { $0.ts + 1 >= reader.lastEventTime ? $0.state : nil }
        if hookState == "permission" { return .needsPermission }

        // A question tool (AskUserQuestion, ExitPlanMode) is parked waiting for you, not running.
        // The hook only says "tool" for it, so this has to come before the hook's tool state.
        if reader.toolUnanswered, Self.questionTools.contains(reader.lastToolName) { return .needsQuestion }

        if hookState == "tool" { return .usingTool }

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
    /// Tools that block on you answering something (lowercased, like `lastToolName`).
    private static let questionTools: Set<String> = ["askuserquestion", "exitplanmode"]
    private func isReadOnly(_ tool: String) -> Bool { Self.readOnlyTools.contains(tool) }

    /// A crab you have looked at rests for a while, then falls asleep. Anything else (a new turn,
    /// a fresh unseen finish, Desktop putting the dot back) resets the timer.
    private func restOrSleep(id: String, status: CrabStatus, now: Double) -> CrabStatus {
        guard status == .doneSeen else { seenAt[id] = nil; return status }
        let since = seenAt[id] ?? now
        seenAt[id] = since
        return now - since >= Self.sleepAfterSeen ? .dormant : status
    }

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

        // Desktop Code tab, before Desktop's own record has caught up with this finish.
        // 1. You opened the chat after it finished (Desktop writes lastFocusedAt within a second),
        //    and the Claude app is in front (a bump while it sits behind a browser is not a read).
        if let meta, meta.lastFocusedAt >= doneAt - 0.5, look.claudeFrontSince != nil { return true }
        // 2. It is the chat on screen, and Claude has been in front long enough since the finish.
        guard let meta, onScreenLocalId() == meta.localId, let since = look.claudeFrontSince else { return false }
        return max(since, doneAt) + Self.lookDuration <= now
    }

    /// The chat on screen, as best we can tell. Desktop's own "current chat" record is exact but
    /// reaches disk up to a minute late (its web storage is flushed on a timer). A click into any
    /// chat after that record was written (`lastFocusedAt`, which lands within a second) is invisible
    /// to it, so then the newest click is the better answer. Nil means a non-chat view (new chat…).
    private func onScreenLocalId() -> String? {
        let newestClick = desktopMeta.mostRecentlyFocusedId.flatMap { desktopMeta.meta(for: $0) }
        if let ls = desktopStorage.state, ls.writtenAt > newestClickAt() + Self.storageMargin {
            return ls.currentSessionId
        }
        return newestClick?.localId
    }

    enum DesktopVerdict { case seen, unseen, notYet }

    /// What Desktop's own records say about this finish. Two records, two speeds: `lastFocusedAt`
    /// (per-chat meta file) lands within a second of you opening a chat; the unread dot and the
    /// chat-on-screen record (web storage) land up to a minute later. A record can only vouch for
    /// what happened before it was written, so a click newer than the storage record wins over it,
    /// and a storage record newer than the click wins over that (it catches `lastFocusedAt` bumps
    /// that were not real reads). Nil: nothing on disk postdates the finish, so the caller guesses.
    /// `.notYet`: the chat was on screen when it finished, but you have not had the app in front
    /// long enough since with it still up.
    private func desktopVerdict(meta: DesktopMetaIndex.Meta?, doneAt: Double,
                                look: SeenDetector.Snapshot, now: Double) -> DesktopVerdict? {
        guard let meta, let ls = desktopStorage.state, doneAt > 0 else { return nil }
        let openedAfterFinish = meta.lastFocusedAt >= doneAt - 0.5
        let recordAfterClick = ls.writtenAt > meta.lastFocusedAt + Self.storageMargin
        let recordAfterFinish = ls.writtenAt > doneAt + Self.storageMargin
        // Opening the chat counts once the Claude app is actually in front (a bump while it sits
        // behind a browser is not a read); the store checks again every second, so this is instant.
        let claudeUp = look.canSee && look.claudeFrontSince != nil
        if ls.unreadIds.contains(meta.localId) || ls.explicitUnreadIds.contains(meta.localId) {
            // Desktop drops the dot the moment you open the chat, but that reaches disk with its
            // next flush. Until then a newer click is the truth; otherwise the dot is.
            guard openedAfterFinish, !recordAfterClick else { return .unseen }
            return claudeUp ? .seen : .notYet
        }
        if openedAfterFinish { return claudeUp ? .seen : .notYet }   // opened after the finish, nothing newer disagrees
        guard recordAfterFinish else { return nil }
        // Desktop saw no dot after the finish: the chat was on screen when it finished. That counts
        // once the app has been in front long enough with it still up, or once you have clicked on
        // to another chat since (which you did from the app, with this one in view).
        guard look.canSee else { return .notYet }
        if newestClickAt() > doneAt + 0.5 { return .seen }
        guard onScreenLocalId() == meta.localId, let since = look.claudeFrontSince,
              max(since, doneAt) + Self.lookDuration <= now else { return .notYet }
        return .seen
    }

    /// When you last clicked into any chat (the newest `lastFocusedAt` on disk).
    private func newestClickAt() -> Double {
        desktopMeta.mostRecentlyFocusedId.flatMap { desktopMeta.meta(for: $0) }?.lastFocusedAt ?? 0
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
