import AppKit
import SpriteKit

/// The 2D floor the crabs stand on. Owns the crabs (and sub-agent baby crabs), handles dragging,
/// runs the little wander brain, and lets the SessionStore add / update / remove crabs.
final class PlaypenScene: SKScene {
    static let floorInset: CGFloat = 0
    /// How far from the herd's center a crab will roam (grows a little with the herd).
    static let baseHerdSpread: CGFloat = 160
    /// How fast a relaxed crab ambles during its occasional shuffle.
    static let strollSpeed: CGFloat = 22
    /// Average speed of a crab switching sides (started working, or finished). The run is eased,
    /// so it winds up, sprints at about 1.5x this in the middle, and glides to a stop.
    static let dashSpeed: CGFloat = 700
    /// Minimum breathing room between crabs.
    static let spacing: CGFloat = 96

    /// A crab only steps aside for a neighbour this often, so crowding never turns into shoving.
    static let unstackCooldown: TimeInterval = 30
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

    /// The crab under the cursor, and where the cursor was (scene coordinates) when we last heard.
    private var hovered: CrabNode?
    private var hoverPoint = CGPoint(x: -1000, y: -1000)
    /// The cursor must rest on a crab this long before its bubble pops (no flashing while crossing).
    static let hoverDelay: TimeInterval = 0.25

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

    /// The two sides of the floor. Left is the working side, right is the done side. With the Dock
    /// in our row that is simply the left gap and the right gap; otherwise the floor is split in half.
    private var sides: (working: ClosedRange<CGFloat>, done: ClosedRange<CGFloat>) {
        let ranges = allowedRanges
        if ranges.count >= 2 { return (ranges[0], ranges[ranges.count - 1]) }
        let r = ranges[0]
        let mid = (r.lowerBound + r.upperBound) / 2
        let aisle = min(30, (r.upperBound - r.lowerBound) / 4)   // a little no-man's-land in the middle
        return (r.lowerBound...(mid - aisle), (mid + aisle)...r.upperBound)
    }

    private func side(for status: CrabStatus) -> ClosedRange<CGFloat> {
        status.isWorkingSide ? sides.working : sides.done
    }

    /// Where a crab will be standing once it stops: its dash or stroll target, else where it is.
    private func restingX(of crab: CrabNode) -> CGFloat {
        crab.dashTarget ?? crab.wanderTarget ?? crab.position.x
    }

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
        for c in snapshot.crabs { byId[c.id]?.detail = c.detail }
        for crab in crabs { crab.helpers = babyParent.values.filter { $0 == crab.id }.count }
    }

    func syncCrab(id: String, title: String, color: NSColor, status: CrabStatus) {
        if let crab = byId[id] {
            crab.title = title
            crab.projectColor = color
            let old = crab.currentStatus
            if dragged !== crab, old != status {
                crab.setStatus(status)
                boostUntil = sceneTime + 2
                // Switching sides beats a hand placement: the crab runs over right away.
                if old.isWorkingSide != status.isWorkingSide { crab.holdUntil = 0 }
                if status == .doneUnseen, old.isBusy { SoundPlayer.play(.done) }
                if status.needsYou, !old.needsYou { SoundPlayer.play(.attention) }
            }
            return
        }
        let crab = CrabNode(id: id)
        crab.title = title
        crab.projectColor = color
        crab.position = CGPoint(x: landingX(in: side(for: status), for: nil), y: floorY)
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
        if hovered === crab { setHovered(nil, at: nil) }
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

        keepSides()
        wander(dt: dt)
        unstack()
        followParents()
        layoutTags()
        hoverCheck()
        adaptFrameRate()
    }

    /// Left is the working side, right is the done side. Anyone standing on the wrong side runs
    /// over (a crab you just placed by hand waits out its hold first). A crab whose status flips
    /// mid-run turns around.
    private func keepSides() {
        let slack: CGFloat = 24
        for crab in crabs where crab !== dragged && sceneTime >= crab.holdUntil {
            let home = side(for: crab.currentStatus)
            if let target = crab.dashTarget {
                if !home.contains(target) { dash(crab, to: landingX(in: home, for: crab)) }
                continue
            }
            guard !(home.lowerBound - slack...home.upperBound + slack).contains(crab.position.x) else { continue }
            dash(crab, to: landingX(in: home, for: crab))
        }
    }

    private func dash(_ crab: CrabNode, to x: CGFloat) {
        crab.startDash(to: x, duration: TimeInterval(abs(x - crab.position.x) / Self.dashSpeed))
        boostUntil = sceneTime + 2
    }

    /// Cubic ease-in-out: a quick wind-up, full sprint in the middle, and a soft stop.
    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Slope of `easeInOut`, scaled to 0...1 (it peaks in the middle of the run). Paces the legs.
    private static func easeInOutPace(_ t: CGFloat) -> CGFloat {
        (t < 0.5 ? 12 * t * t : 12 * (1 - t) * (1 - t)) / 3
    }

    /// Only relaxed crabs roam, and barely: they stand and live their little life, and every now
    /// and then take one short shuffle. Working crabs stay put and just play their animation.
    /// A crab switching sides runs, fast, and does nothing else until it gets there.
    private func wander(dt: TimeInterval) {
        for crab in crabs where crab !== dragged {
            if let target = crab.dashTarget {
                crab.dashElapsed += dt
                let t = CGFloat(min(crab.dashElapsed / crab.dashDuration, 1))
                crab.position.x = crab.dashFromX + (target - crab.dashFromX) * Self.easeInOut(t)
                crab.setDashPace(Self.easeInOutPace(t))
                if t >= 1 {
                    crab.position.x = target
                    crab.finishDash()
                    crab.nextWanderAt = sceneTime + .random(in: 12...30)
                }
                continue
            }

            let home = side(for: crab.currentStatus)
            let mates = crabs.filter { $0 !== crab && home.contains(restingX(of: $0)) }
            let herdCenter = mates.isEmpty ? (home.lowerBound + home.upperBound) / 2
                : mates.map { restingX(of: $0) }.reduce(0, +) / CGFloat(mates.count)

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

    /// Two crabs standing too close take one short step apart — a single shuffle, not a continuous
    /// shove, and at most once every `unstackCooldown` seconds each. Crabs you placed by hand, and
    /// crabs that want your attention or are asleep, hold their ground; the other one moves.
    private func unstack() {
        let minGap: CGFloat = 44
        let free = crabs.filter { $0 !== dragged && !$0.isDashing }.sorted { $0.position.x < $1.position.x }
        guard free.count > 1 else { return }
        func fixed(_ c: CrabNode) -> Bool {
            c.holdUntil > sceneTime || c.currentStatus.needsYou || c.currentStatus == .dormant
        }
        for i in 1..<free.count {
            let a = free[i - 1], b = free[i]
            let gap = b.position.x - a.position.x
            guard gap < minGap else { continue }
            let aFixed = fixed(a), bFixed = fixed(b)
            let room = minGap - gap
            if !aFixed { stepAside(a, by: -(bFixed ? room : room / 2)) }
            if !bFixed { stepAside(b, by: aFixed ? room : room / 2) }
        }
    }

    /// One short walk `dx` points sideways, then a long cooldown before this crab budges again.
    /// A crab already walking, or still held after a drag, is left alone.
    private func stepAside(_ crab: CrabNode, by dx: CGFloat) {
        guard crab.wanderTarget == nil, sceneTime >= crab.nextUnstackAt, sceneTime >= crab.holdUntil else { return }
        crab.nextUnstackAt = sceneTime + Self.unstackCooldown
        let home = side(for: crab.currentStatus)
        let step = dx + (dx < 0 ? -8 : 8)   // a touch extra, so they end up clearly apart
        let target = min(max(crab.position.x + step, home.lowerBound + crab.size.width / 2),
                         home.upperBound - crab.size.width / 2)
        guard abs(target - crab.position.x) > 2 else { return }
        crab.wanderTarget = target
        crab.facingRight = target > crab.position.x
        crab.startMoving()
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

    /// 30 fps (the pets' own frame rate) while any crab is awake; 15 fps once everyone is asleep.
    private func adaptFrameRate() {
        guard let view else { return }
        let awake = isDragging || !leaving.isEmpty || !babies.isEmpty || sceneTime < boostUntil
            || crabs.contains { $0.currentStatus != .dormant }
        let fps = awake ? 30 : 15
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

    /// A free spot on a side, near whoever is already there (or on their way there). New crabs
    /// are born on one, and a crab switching sides runs to one.
    private func landingX(in home: ClosedRange<CGFloat>, for crab: CrabNode?) -> CGFloat {
        let others = crabs.filter { $0 !== crab }.map { restingX(of: $0) }
        let mates = others.filter { home.contains($0) }
        let center = mates.isEmpty ? (home.lowerBound + home.upperBound) / 2
            : mates.reduce(0, +) / CGFloat(mates.count)
        var x = center + .random(in: -80...80)
        for _ in 0..<4 {
            guard let neighbour = others.first(where: { abs($0 - x) < Self.spacing }) else { break }
            x = neighbour + (x >= neighbour ? Self.spacing : -Self.spacing)
        }
        let inset = min(26, (home.upperBound - home.lowerBound) / 2)
        return min(max(x, home.lowerBound + inset), home.upperBound - inset)
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

    /// Spread everyone out evenly on their own side and forget any "stay here" holds.
    func resetCrabs() {
        let s = sides
        let groups: [(ClosedRange<CGFloat>, [CrabNode])] = [
            (s.working, crabs.filter { $0.currentStatus.isWorkingSide }),
            (s.done, crabs.filter { !$0.currentStatus.isWorkingSide }),
        ]
        for (r, bucket) in groups {
            let inset: CGFloat = 40
            let lo = r.lowerBound + inset, hi = r.upperBound - inset
            let step = bucket.count > 1 ? (hi - lo) / CGFloat(bucket.count - 1) : 0
            for (i, crab) in bucket.enumerated() {
                crab.removeAction(forKey: "settle")
                crab.finishDash()
                crab.wanderTarget = nil
                crab.stopMoving()
                crab.holdUntil = 0
                crab.nextWanderAt = sceneTime + 2
                crab.position = CGPoint(x: bucket.count == 1 ? (lo + hi) / 2 : lo + CGFloat(i) * step, y: floorY)
            }
        }
    }

    // MARK: - Hover

    /// The crab the cursor is on (nil when it is not on one). Its bubble pops after a short rest.
    func setHovered(_ crab: CrabNode?, at point: CGPoint?) {
        hoverPoint = point ?? CGPoint(x: -1000, y: -1000)
        guard crab !== hovered else { return }
        hovered?.hideBubble()
        removeAction(forKey: "hover")
        hovered = crab
        guard let crab else { return }
        boostUntil = sceneTime + 1
        run(.sequence([.wait(forDuration: Self.hoverDelay), .run { [weak crab] in crab?.showBubble() }]),
            withKey: "hover")
    }

    /// A hovered crab can walk out from under a resting cursor; drop its bubble when it does.
    private func hoverCheck() {
        guard let h = hovered, crab(at: hoverPoint) !== h else { return }
        setHovered(nil, at: nil)
    }

    // MARK: - Dragging

    func crab(at point: CGPoint, slop: CGFloat = 6) -> CrabNode? {
        crabs.last { $0.bodyFrame.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        guard let crab = crab(at: p) else { return }
        dragged = crab
        setHovered(nil, at: nil)
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
