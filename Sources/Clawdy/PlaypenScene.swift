import AppKit
import SpriteKit

/// The 2D floor the crabs stand on. Owns the crabs (and sub-agent baby crabs), handles dragging,
/// runs the little wander brain, and lets the SessionStore add / update / remove crabs.
final class PlaypenScene: SKScene {
    static let floorInset: CGFloat = 1
    /// How far from the herd's center a crab will roam (grows a little with the herd).
    static let baseHerdSpread: CGFloat = 160
    /// How fast a relaxed crab ambles during its occasional shuffle.
    static let strollSpeed: CGFloat = 22
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

    /// The Dock's footprint in scene x (with margin). Pets live in the gaps on either side of it.
    var blockedX: ClosedRange<CGFloat>? {
        didSet {
            guard blockedX != oldValue else { return }
            for crab in crabs where crab !== dragged {
                let x = clampX(crab.position.x, for: crab)
                if x != crab.position.x { crab.wanderTarget = x; crab.startMoving() }
            }
        }
    }

    /// Where pets may stand: one range per wallpaper gap (or the whole floor if there is no Dock here).
    private var allowedRanges: [ClosedRange<CGFloat>] {
        let edge: CGFloat = 40
        guard let b = blockedX else { return [edge...max(edge, size.width - edge)] }
        var out: [ClosedRange<CGFloat>] = []
        if b.lowerBound - edge > edge + 60 { out.append(edge...(b.lowerBound)) }
        if size.width - edge - b.upperBound > 60 { out.append(b.upperBound...(size.width - edge)) }
        return out.isEmpty ? [edge...max(edge, size.width - edge)] : out
    }

    private func range(containing x: CGFloat) -> ClosedRange<CGFloat> {
        let ranges = allowedRanges
        if let r = ranges.first(where: { $0.contains(x) }) { return r }
        return ranges.min(by: { distance(x, to: $0) < distance(x, to: $1) }) ?? ranges[0]
    }

    private func distance(_ x: CGFloat, to r: ClosedRange<CGFloat>) -> CGFloat {
        x < r.lowerBound ? r.lowerBound - x : (x > r.upperBound ? x - r.upperBound : 0)
    }

    private func crabs(in r: ClosedRange<CGFloat>) -> [CrabNode] { crabs.filter { r.contains($0.position.x) } }

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

    /// Only relaxed crabs roam, and barely: they stand and live their little life, and every now
    /// and then take one short shuffle. Working crabs stay put and just play their animation.
    private func wander(dt: TimeInterval) {
        for crab in crabs where crab !== dragged {
            let home = range(containing: crab.position.x)
            let mates = crabs(in: home)
            let herdCenter = mates.isEmpty ? (home.lowerBound + home.upperBound) / 2
                : mates.map { $0.position.x }.reduce(0, +) / CGFloat(mates.count)

            if let target = crab.wanderTarget {
                let dx = target - crab.position.x
                if abs(dx) <= 1.5 {
                    crab.position.x = target
                    crab.wanderTarget = nil
                    crab.stopMoving()
                    crab.nextWanderAt = sceneTime + .random(in: 12...30)
                } else {
                    let step = min(abs(dx), Self.strollSpeed * CGFloat(dt))
                    crab.position.x += dx > 0 ? step : -step
                    crab.facingRight = dx > 0
                }
                continue
            }

            guard crab.canWander, sceneTime >= crab.nextWanderAt, sceneTime >= crab.holdUntil else { continue }

            // Most of the time it just stays where it is.
            if CGFloat.random(in: 0..<1) < 0.8 {
                crab.nextWanderAt = sceneTime + .random(in: 8...18)
                continue
            }

            // One short shuffle, leaning back toward the herd if it has drifted off.
            let towardHerd: CGFloat = herdCenter > crab.position.x ? 1 : -1
            let drifted = abs(herdCenter - crab.position.x) > Self.baseHerdSpread
            let direction: CGFloat = drifted ? towardHerd : (Bool.random() ? 1 : -1)
            var target = crab.position.x + direction * .random(in: 18...55)
            target = separated(target, from: crab)
            target = min(max(target, home.lowerBound + crab.size.width / 2), home.upperBound - crab.size.width / 2)
            if abs(target - crab.position.x) < 8 {
                crab.nextWanderAt = sceneTime + .random(in: 6...12)
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
            let dx = clampX(targetX, for: baby) - baby.position.x
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

    /// New crabs arrive in the emptier wallpaper gap (the wider one on a tie), near its herd.
    private func spawnX() -> CGFloat {
        let ranges = allowedRanges
        let home = ranges.min(by: { a, b in
            let ca = crabs(in: a).count, cb = crabs(in: b).count
            return ca != cb ? ca < cb : (a.upperBound - a.lowerBound) > (b.upperBound - b.lowerBound)
        }) ?? ranges[0]
        let mates = crabs(in: home)
        let center = mates.isEmpty ? (home.lowerBound + home.upperBound) / 2
            : mates.map { $0.position.x }.reduce(0, +) / CGFloat(mates.count)
        var x = center + .random(in: -80...80)
        for _ in 0..<4 {
            guard let neighbour = crabs.first(where: { abs($0.position.x - x) < Self.spacing }) else { break }
            x = neighbour.position.x + (x >= neighbour.position.x ? Self.spacing : -Self.spacing)
        }
        return min(max(x, home.lowerBound + 26), home.upperBound - 26)
    }

    /// Keep x inside the wallpaper gap it is in (or the nearest one).
    private func clampX(_ x: CGFloat, for crab: CrabNode) -> CGFloat {
        let half = crab.size.width / 2 + 8
        let r = range(containing: x)
        return min(max(x, r.lowerBound + half), r.upperBound - half)
    }

    /// While dragging, the whole floor is fair game (so you can carry a pet across the Dock).
    private func clamp(_ p: CGPoint, for crab: CrabNode) -> CGPoint {
        let half = crab.size.width / 2
        return CGPoint(x: min(max(p.x, half), size.width - half),
                       y: min(max(p.y, floorY), size.height - crab.size.height))
    }

    /// Spread everyone out evenly and forget any "stay here" holds.
    func resetCrabs() {
        let ranges = allowedRanges
        // Deal crabs across the gaps, widest gap first, evenly spaced inside each.
        let ordered = ranges.sorted { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) }
        var buckets: [[CrabNode]] = Array(repeating: [], count: ordered.count)
        for (i, crab) in crabs.enumerated() { buckets[i % ordered.count].append(crab) }
        for (r, bucket) in zip(ordered, buckets) {
            let inset: CGFloat = 40
            let lo = r.lowerBound + inset, hi = r.upperBound - inset
            let step = bucket.count > 1 ? (hi - lo) / CGFloat(bucket.count - 1) : 0
            for (i, crab) in bucket.enumerated() {
                crab.removeAction(forKey: "settle")
                crab.wanderTarget = nil
                crab.stopMoving()
                crab.holdUntil = 0
                crab.nextWanderAt = sceneTime + 2
                crab.position = CGPoint(x: bucket.count == 1 ? (lo + hi) / 2 : lo + CGFloat(i) * step, y: floorY)
            }
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
        // Dropped over the Dock? Slide out to the nearest gap.
        let fall = SKAction.move(to: CGPoint(x: clampX(crab.position.x, for: crab), y: floorY), duration: 0.25)
        fall.timingMode = .easeIn
        crab.run(fall, withKey: "settle")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        for crab in crabs { crab.position = clamp(crab.position, for: crab) }
    }
}
