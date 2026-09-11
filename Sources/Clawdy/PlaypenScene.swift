import AppKit
import SpriteKit

/// The 2D floor the crabs stand on. Owns the crabs (and sub-agent baby crabs), handles dragging,
/// and lets the SessionStore add / update / remove crabs as sessions come and go.
final class PlaypenScene: SKScene {
    static let floorInset: CGFloat = 6

    private(set) var crabs: [CrabNode] = []
    private var byId: [String: CrabNode] = [:]
    private var babies: [String: CrabNode] = [:]
    private var babyParent: [String: String] = [:]
    private var leaving: Set<String> = []

    private var dragged: CrabNode?
    private var dragOffset = CGPoint.zero
    private var lastDragX: CGFloat = 0

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
            if dragged !== crab { crab.setStatus(status) }
            return
        }
        let crab = CrabNode(id: id)
        crab.title = title
        crab.projectColor = color
        crab.position = CGPoint(x: openX(), y: floorY)
        crab.setStatus(status)
        addChild(crab)
        crabs.append(crab)
        byId[id] = crab
        crab.setScale(0.6); crab.alpha = 0
        crab.run(.group([.fadeIn(withDuration: 0.2), .scale(to: 1, duration: 0.25)]))
    }

    func removeCrab(id: String) {
        guard let crab = byId[id], !leaving.contains(id) else { return }
        leaving.insert(id)
        byId[id] = nil
        crabs.removeAll { $0 === crab }
        if dragged === crab { dragged = nil }
        // Any of this crab's babies leave with it.
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

    /// Remove baby crabs whose sub-agent is no longer active.
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

    /// Keep babies trailing their parent each frame.
    override func update(_ currentTime: TimeInterval) {
        for (babyId, baby) in babies {
            guard let parentId = babyParent[babyId], let parent = byId[parentId] else { continue }
            let targetX = parent.position.x + (baby.hashValue % 2 == 0 ? -1 : 1) * (parent.size.width * 0.5 + 12)
            let dx = targetX - baby.position.x
            if abs(dx) > 1 {
                baby.facingRight = dx > 0
                baby.position.x += max(-2.5, min(2.5, dx * 0.15))
            }
        }
    }

    private func walkOff(_ crab: CrabNode, id: String) {
        let exitX: CGFloat = crab.position.x < size.width / 2 ? -crab.size.width : size.width + crab.size.width
        crab.facingRight = exitX > crab.position.x
        crab.showDragging()
        let walk = SKAction.move(to: CGPoint(x: exitX, y: floorY),
                                 duration: TimeInterval(abs(exitX - crab.position.x) / 220))
        crab.run(.sequence([walk, .fadeOut(withDuration: 0.15), .removeFromParent(),
                            .run { [weak self] in self?.leaving.remove(id) }]))
    }

    private func openX() -> CGFloat {
        let margin: CGFloat = 50
        guard !crabs.isEmpty else { return size.width * 0.5 }
        let candidates = stride(from: margin, through: size.width - margin, by: (size.width - 2 * margin) / 11)
        return candidates.max(by: { minDistance($0) < minDistance($1) }) ?? size.width * 0.5
    }

    private func minDistance(_ x: CGFloat) -> CGFloat {
        crabs.map { abs($0.position.x - x) }.min() ?? .greatestFiniteMagnitude
    }

    func resetCrabs() {
        let margin: CGFloat = 50
        let step = crabs.count > 1 ? (size.width - 2 * margin) / CGFloat(crabs.count - 1) : 0
        for (i, crab) in crabs.enumerated() {
            crab.removeAction(forKey: "settle")
            crab.position = CGPoint(x: crabs.count == 1 ? size.width / 2 : margin + CGFloat(i) * step, y: floorY)
        }
    }

    // MARK: - Dragging

    func crab(at point: CGPoint, slop: CGFloat = 6) -> CrabNode? {
        crabs.last { $0.bodyFrame.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    private func clamp(_ p: CGPoint, for crab: CrabNode) -> CGPoint {
        let half = crab.size.width / 2
        return CGPoint(x: min(max(p.x, half), size.width - half),
                       y: min(max(p.y, floorY), size.height - crab.size.height))
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
