import AppKit

/// Polls every second and keeps the playpen's crabs in sync with live Claude sessions:
/// registry sessions (CLI + Desktop Code), their sub-agents, and Cowork sessions. Resolves each
/// session's status from transcript + hook signals and pushes it to the scene.
final class SessionStore {
    private weak var scene: PlaypenScene?
    private var readers: [String: TranscriptReader] = [:]
    private var timer: Timer?

    static let dormantAfter: TimeInterval = 600      // 10 minutes with no activity
    static let permissionGuessDelay: TimeInterval = 6
    static let bashPermissionDelay: TimeInterval = 600

    struct Row { let title: String; let status: CrabStatus }
    private(set) var rows: [Row] = []

    init(scene: PlaypenScene) { self.scene = scene }

    func start() {
        tick()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let scene else { return }
        let now = Date().timeIntervalSince1970
        let hooks = HookBridge.scan()

        let live = SessionRegistry.scan()
        let cowork = CoworkWatcher.scan()
        let liveIds = Set(live.map { $0.sessionId }).union(cowork.map { $0.sessionId })

        // Drop crabs (and readers) for sessions that have exited.
        for id in Set(readers.keys).subtracting(liveIds) {
            readers[id] = nil
            scene.removeCrab(id: id)
        }

        var newRows: [Row] = []
        var activeBabies: Set<String> = []

        for session in live.sorted(by: { $0.startedAt < $1.startedAt }) {
            let reader = reader(for: session.sessionId)
            reader.refresh()
            let status = resolve(reader: reader, hook: hooks[session.sessionId], now: now)
            let title = reader.title ?? session.name
            let color = CrabPalette.color(for: session.projectName)
            scene.syncCrab(id: session.sessionId, title: title, color: color, status: status)
            newRows.append(Row(title: title, status: status))

            // Sub-agents → baby crabs, only while the parent is busy.
            if status.isBusy, let dir = reader.subagentsDirectory {
                for agentId in SubagentWatcher.activeAgents(in: dir, now: now) {
                    scene.syncBaby(id: agentId, parentId: session.sessionId, color: color)
                    activeBabies.insert(agentId)
                }
            }
        }

        for session in cowork {
            let color = CrabPalette.color(for: session.projectName)
            scene.syncCrab(id: session.sessionId, title: session.title, color: color, status: session.status)
            newRows.append(Row(title: session.title, status: session.status))
        }

        scene.pruneBabies(keeping: activeBabies)
        rows = newRows
    }

    private func reader(for id: String) -> TranscriptReader {
        if let r = readers[id] { return r }
        let r = TranscriptReader(sessionId: id)
        readers[id] = r
        return r
    }

    /// Turn transcript + hook signals into one status, using the plan's priority order.
    private func resolve(reader: TranscriptReader, hook: HookBridge.Event?, now: Double) -> CrabStatus {
        // 1. Hooks are the ground truth when present and at least as fresh as the transcript.
        if let hook, hook.ts + 1 >= reader.lastEventTime {
            switch hook.state {
            case "permission": return .needsPermission
            case "tool": return .usingTool
            case "done": break            // fall through to transcript (question / dormant refinement)
            default: break
            }
        }

        let age = now - (reader.lastEventTime == 0 ? now : reader.lastEventTime)

        // 2. Permission guess from files: a tool_use left unanswered too long, unless auto-approved.
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

        // Working. If a (non-read-only) tool is mid-run, show the tool badge.
        if reader.toolUnanswered, !isReadOnly(reader.lastToolName) { return .usingTool }
        if age > Self.dormantAfter { return .dormant }
        return .working
    }

    private static let readOnlyTools: Set<String> = ["read", "glob", "grep", "todowrite", "webfetch", "websearch"]
    private func isReadOnly(_ tool: String) -> Bool { Self.readOnlyTools.contains(tool) }
}
