import AppKit
import SpriteKit

/// The 2D floor the crabs stand on. Owns the crabs (and sub-agent baby crabs), handles dragging,
/// runs the little wander brain, and lets the SessionStore add / update / remove crabs.
final class PlaypenScene: SKScene {
    static let floorInset: CGFloat = 6
    /// How far from the herd's center a crab will roam (grows a little with the herd).
    static let baseHerdSpread: CGFloat = 160
    /// Minimum breathing room between crabs.
    static let spacing: CGFloat = 96
    /// After you drop a crab it stays put this long before rejoining the herd.
    static let holdAfterDrag: TimeInterval = 45

    private(set) var crabs: [CrabNode] = []
    private var byId: [String: CrabNode] = [:]
    private var babies: [String: CrabNode] = [:]
    private var babyParent: [String: String] = [:]
    private var leaving: Set<String> = []

    private var dragged: CrabNode?
    private var dragOffset = CGPoint.zero
    private var lastDragX: CGFloat = 0

    private var sceneTime: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0
    /// Keep the frame rate up for a moment after something changes, so short animations look smooth.
    private var boostUntil: TimeInterval = 0

    var isDragging: Bool { dragged != nil }
    var floorY: CGFloat { Self.floorInset }

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Session-driven crabs

    /// Apply a full snapshot from the store: add/update/remove crabs and babies in one pass.
    func apply(_ snapshot: SessionStore.Snapshot) {
        let ids = Set(snapshot.crabs.map { $0.id })
        for id in Array(byId.keys) where !ids.contains(id) { removeCrab(id: id) }
        for c in snapshot.crabs { syncCrab(id: c.id, title: c.title, color: c.color, status: c.status) }
        for b in snapshot.babies { syncBaby(id: b.id, parentId: b.parentId, color: b.color) }
        pruneBabies(keeping: Set(snapshot.babies.map { $0.id }))
    }

    func syncCrab(id: String, title: String, color: NSColor, status: CrabStatus) {
        if let crab = byId[id] {
            crab.title = title
            crab.projectColor = color
            let old = crab.currentStatus
            if dragged !== crab, old != status {
                crab.setStatus(status)
                boostUntil = sceneTime + 2
                if status == .doneUnseen, old.isBusy { SoundPlayer.play(.done) }
                if status.needsYou, !old.needsYou { SoundPlayer.play(.attention) }
            }
            return
        }
        let crab = CrabNode(id: id)
        crab.title = title
        crab.projectColor = color
        crab.position = CGPoint(x: spawnX(), y: floorY)
        crab.setStatus(status)
        crab.nextWanderAt = sceneTime + 3
        addChild(crab)
        crabs.append(crab)
        byId[id] = crab
        boostUntil = sceneTime + 2
        crab.setScale(0.6); crab.alpha = 0
        crab.run(.sequence([.group([.fadeIn(withDuration: 0.2), .scale(to: 1, duration: 0.25)]),
                            .run { crab.wave() }]))
    }

    func removeCrab(id: String) {
        guard let crab = byId[id], !leaving.contains(id) else { return }
        leaving.insert(id)
        byId[id] = nil
        crabs.removeAll { $0 === crab }
        if dragged === crab { dragged = nil }
        for (babyId, parent) in babyParent where parent == id { removeBaby(id: babyId) }
        walkOff(crab, id: id)
    }

    // MARK: - Sub-agent baby crabs

    func syncBaby(id: String, parentId: String, color: NSColor) {
        let baby: CrabNode
        if let existing = babies[id] {
            baby = existing
        } else {
            baby = CrabNode(id: id, isBaby: true)
            baby.projectColor = color
            baby.position = CGPoint(x: (byId[parentId]?.position.x ?? size.width / 2), y: floorY)
            baby.setStatus(.working)
            addChild(baby)
            babies[id] = baby
            babyParent[id] = parentId
            baby.setScale(0.4); baby.alpha = 0
            baby.run(.group([.fadeIn(withDuration: 0.2), .scale(to: 1, duration: 0.25)]))
        }
        baby.projectColor = color
    }

    func pruneBabies(keeping active: Set<String>) {
        for id in Set(babies.keys).subtracting(active) { removeBaby(id: id) }
    }

    private func removeBaby(id: String) {
        guard let baby = babies[id] else { return }
        babies[id] = nil
        babyParent[id] = nil
        baby.run(.sequence([.group([.fadeOut(withDuration: 0.2), .scale(to: 0.4, duration: 0.2)]),
                            .removeFromParent()]))
    }

    // MARK: - Per-frame brain

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate == 0 ? 0 : min(currentTime - lastUpdate, 0.1)
        lastUpdate = currentTime
        sceneTime = currentTime

        wander(dt: dt)
        unstack(dt: dt)
        followParents()
        layoutTags()
        adaptFrameRate()
    }

    /// Crabs roam near the herd's center, keep a little distance from each other, and pause between
    /// walks. Working crabs are quick and restless; relaxed ones amble and often just sit.
    private func wander(dt: TimeInterval) {
        let herdCenter = crabs.isEmpty ? size.width / 2
            : crabs.map { $0.position.x }.reduce(0, +) / CGFloat(crabs.count)

        for crab in crabs where crab !== dragged {
            let working = crab.currentStatus == .working

            if let target = crab.wanderTarget {
                let speed: CGFloat = working ? 55 : 32
                let dx = target - crab.position.x
                if abs(dx) <= 1.5 {
                    crab.position.x = target
                    crab.wanderTarget = nil
                    crab.stopMoving()
                    crab.nextWanderAt = sceneTime + (working ? .random(in: 0.6...2.5) : .random(in: 3...8))
                } else {
                    let step = min(abs(dx), speed * CGFloat(dt))
                    crab.position.x += dx > 0 ? step : -step
                    crab.facingRight = dx > 0
                }
                continue
            }

            guard crab.canWander, sceneTime >= crab.nextWanderAt, sceneTime >= crab.holdUntil else { continue }

            // Relaxed crabs often decide to just sit a while longer.
            if !working, Bool.random() {
                crab.nextWanderAt = sceneTime + .random(in: 2...5)
                continue
            }

            let spread = Self.baseHerdSpread + CGFloat(max(0, crabs.count - 3)) * 45
            var target = herdCenter + .random(in: -spread...spread)
            target = separated(target, from: crab)
            target = clampX(target, for: crab)
            if abs(target - crab.position.x) < 12 {
                crab.nextWanderAt = sceneTime + 1.5
                continue
            }
            crab.wanderTarget = target
            crab.facingRight = target > crab.position.x
            crab.startMoving()
        }
    }

    /// Two crabs standing on top of each other gently step apart. Crabs you placed by hand, and
    /// crabs that want your attention or are asleep, hold their ground; the other one moves.
    private func unstack(dt: TimeInterval) {
        let minGap: CGFloat = 44
        let free = crabs.filter { $0 !== dragged }.sorted { $0.position.x < $1.position.x }
        guard free.count > 1 else { return }
        func fixed(_ c: CrabNode) -> Bool {
            c.holdUntil > sceneTime || c.currentStatus.needsYou || c.currentStatus == .dormant
        }
        for i in 1..<free.count {
            let a = free[i - 1], b = free[i]
            let gap = b.position.x - a.position.x
            guard gap < minGap else { continue }
            let push = min((minGap - gap) / 2, 40 * CGFloat(dt))
            let aFixed = fixed(a), bFixed = fixed(b)
            if !aFixed { a.position.x = clampX(a.position.x - (bFixed ? push * 2 : push), for: a) }
            if !bFixed { b.position.x = clampX(b.position.x + (aFixed ? push * 2 : push), for: b) }
        }
    }

    /// Nudge a target x away from any other crab standing too close to it.
    private func separated(_ x: CGFloat, from crab: CrabNode) -> CGFloat {
        var target = x
        for _ in 0..<3 {
            guard let neighbour = crabs.first(where: { $0 !== crab && abs($0.position.x - target) < Self.spacing }) else { break }
            target = neighbour.position.x + (target >= neighbour.position.x ? Self.spacing : -Self.spacing)
        }
        return target
    }

    private func followParents() {
        for (babyId, baby) in babies {
            guard let parentId = babyParent[babyId], let parent = byId[parentId] else { continue }
            let side: CGFloat = baby.id.hashValue % 2 == 0 ? -1 : 1
            let targetX = parent.position.x + side * (parent.size.width * 0.5 + 12)
            let dx = targetX - baby.position.x
            if abs(dx) > 1 {
                baby.facingRight = dx > 0
                baby.position.x += max(-2.5, min(2.5, dx * 0.15))
            }
        }
    }

    /// Neighbouring crabs get their name tags stacked at different heights so they stay readable.
    private func layoutTags() {
        var placed: [(x: CGFloat, width: CGFloat, level: Int)] = []
        for crab in crabs.sorted(by: { $0.position.x < $1.position.x }) {
            var level = 0
            while level < 3, placed.contains(where: {
                $0.level == level && abs($0.x - crab.position.x) < ($0.width + crab.tagWidth) / 2 + 6
            }) { level += 1 }
            crab.tagLevel = level
            placed.append((crab.position.x, crab.tagWidth, level))
        }
    }

    /// 24 fps while anything is moving or wants attention; 10 fps when everyone is resting.
    private func adaptFrameRate() {
        guard let view else { return }
        let busy = isDragging || !leaving.isEmpty || !babies.isEmpty || sceneTime < boostUntil
            || crabs.contains { $0.isMoving || $0.currentStatus.isBusy || $0.currentStatus.needsYou }
        let fps = busy ? 24 : 10
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
    }

    // MARK: - Placement

    private func walkOff(_ crab: CrabNode, id: String) {
        // The going-away pet walks itself out of frame; afterwards the node fades and is removed.
        crab.showLeaving { [weak self, weak crab] in
            guard let crab else { self?.leaving.remove(id); return }
            crab.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent(),
                                .run { [weak self] in self?.leaving.remove(id) }]))
        }
        if !PetLibrary.isAvailable || crab.isBaby {
            let exitX: CGFloat = crab.position.x < size.width / 2 ? -crab.size.width : size.width + crab.size.width
            crab.facingRight = exitX > crab.position.x
            crab.run(.move(to: CGPoint(x: exitX, y: floorY),
                           duration: TimeInterval(abs(exitX - crab.position.x) / 220)), withKey: "exit")
        }
    }

    /// New crabs arrive near the herd, not at the far edges.
    private func spawnX() -> CGFloat {
        guard !crabs.isEmpty else { return size.width * 0.5 }
        let herdCenter = crabs.map { $0.position.x }.reduce(0, +) / CGFloat(crabs.count)
        var x = herdCenter + .random(in: -100...100)
        for _ in 0..<4 {
            guard let neighbour = crabs.first(where: { abs($0.position.x - x) < Self.spacing }) else { break }
            x = neighbour.position.x + (x >= neighbour.position.x ? Self.spacing : -Self.spacing)
        }
        let margin: CGFloat = 40
        return min(max(x, margin), size.width - margin)
    }

    private func clampX(_ x: CGFloat, for crab: CrabNode) -> CGFloat {
        let half = crab.size.width / 2 + 8
        return min(max(x, half), size.width - half)
    }

    private func clamp(_ p: CGPoint, for crab: CrabNode) -> CGPoint {
        let half = crab.size.width / 2
        return CGPoint(x: min(max(p.x, half), size.width - half),
                       y: min(max(p.y, floorY), size.height - crab.size.height))
    }

    /// Spread everyone out evenly and forget any "stay here" holds.
    func resetCrabs() {
        let margin: CGFloat = 60
        let step = crabs.count > 1 ? (size.width - 2 * margin) / CGFloat(crabs.count - 1) : 0
        for (i, crab) in crabs.enumerated() {
            crab.removeAction(forKey: "settle")
            crab.wanderTarget = nil
            crab.stopMoving()
            crab.holdUntil = 0
            crab.nextWanderAt = sceneTime + 2
            crab.position = CGPoint(x: crabs.count == 1 ? size.width / 2 : margin + CGFloat(i) * step, y: floorY)
        }
    }

    // MARK: - Dragging

    func crab(at point: CGPoint, slop: CGFloat = 6) -> CrabNode? {
        crabs.last { $0.bodyFrame.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        guard let crab = crab(at: p) else { return }
        dragged = crab
        dragOffset = CGPoint(x: crab.position.x - p.x, y: crab.position.y - p.y)
        lastDragX = p.x
        crab.removeAction(forKey: "settle")
        crab.zPosition = 10
        crab.showDragging()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let crab = dragged else { return }
        let p = event.location(in: self)
        if abs(p.x - lastDragX) > 1 { crab.facingRight = p.x >= lastDragX; lastDragX = p.x }
        crab.position = clamp(CGPoint(x: p.x + dragOffset.x, y: p.y + dragOffset.y), for: crab)
    }

    override func mouseUp(with event: NSEvent) {
        guard let crab = dragged else { return }
        dragged = nil
        crab.zPosition = 0
        crab.holdUntil = sceneTime + Self.holdAfterDrag
        crab.nextWanderAt = crab.holdUntil
        crab.restoreStatus()
        let fall = SKAction.move(to: CGPoint(x: crab.position.x, y: floorY), duration: 0.25)
        fall.timingMode = .easeIn
        crab.run(fall, withKey: "settle")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        for crab in crabs { crab.position = clamp(crab.position, for: crab) }
    }
}
