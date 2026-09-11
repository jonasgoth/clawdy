import AppKit
import SpriteKit

/// Stable, pleasant colors keyed by project name, so the same project is always the same color.
enum CrabPalette {
    /// Hand-picked mid-saturation hues that stay legible tinted over the crab and behind white text.
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1), // terracotta (Clawd's own)
        NSColor(srgbRed: 0.36, green: 0.55, blue: 0.86, alpha: 1), // blue
        NSColor(srgbRed: 0.44, green: 0.68, blue: 0.42, alpha: 1), // green
        NSColor(srgbRed: 0.78, green: 0.55, blue: 0.24, alpha: 1), // amber
        NSColor(srgbRed: 0.62, green: 0.47, blue: 0.80, alpha: 1), // violet
        NSColor(srgbRed: 0.30, green: 0.66, blue: 0.66, alpha: 1), // teal
        NSColor(srgbRed: 0.84, green: 0.44, blue: 0.60, alpha: 1), // pink
        NSColor(srgbRed: 0.50, green: 0.60, blue: 0.30, alpha: 1), // olive
    ]

    /// Hue of a palette color in degrees, used to recolor the crab sprite.
    static func hueDegrees(of color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        return c.hueComponent * 360
    }

    static func color(for projectName: String) -> NSColor {
        var hash: UInt64 = 5381
        for byte in projectName.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

/// One crab, standing for one Claude session (or, when `isBaby`, one sub-agent).
///
/// Session crabs are drawn with the animated Clawd pets (PetLibrary): one pet per state, so the
/// pose itself says what the session is doing. Baby crabs (sub-agents) keep the small pixel crab.
/// Origin is between the feet, so `position.y == floorY` means standing on the floor.
final class CrabNode: SKNode {
    /// Pet frame cell shown at this many points (sheets are rendered at 2x).
    static let petSize: CGFloat = 120
    /// Measured from the sheets: the pet's shadow ends 21 of 240 px above the cell's bottom edge,
    /// so anchoring there puts the node origin right under the shadow.
    static let petAnchorY: CGFloat = 21.0 / 240.0
    /// The standing body, relative to that origin: feet 3 pt up, 40 wide, 26 tall.
    static let petBody = CGSize(width: 40, height: 26)
    static let petBodyBottom: CGFloat = 3
    /// Name tag height above the origin: clear of the props that float over the head.
    static let petTagY: CGFloat = 58
    /// A seen-and-done session is not worth reading, so its tag fades back to this much opacity.
    static let restingTagAlpha: CGFloat = 0.35
    static let babyScale: CGFloat = 0.6
    /// Status badges are off for now (the pet's pose already says it). Flip to bring them back.
    static var badgesEnabled = false

    let id: String
    let isBaby: Bool
    private let usesPet: Bool
    private let sprite: SKSpriteNode
    private let nameLabel = SKLabelNode()
    private let nameBackground = SKShapeNode()
    private let tagNode = SKNode()
    private var tagBaseY: CGFloat = 0

    private let badgeNode = SKNode()
    private let badgeCircle = SKShapeNode(circleOfRadius: 8)
    private let badgeSymbol = SKSpriteNode()

    private var status: CrabStatus = .working
    private var hueDegrees: CGFloat = PetLibrary.baseHueDegrees
    /// This crab's own working animation, picked once from the rotation and kept for life.
    private lazy var workingPetKey: String = PetLibrary.workingKey(for: id)
    // Pixel-crab textures (babies, or fallback when pet sheets are missing).
    private var tintedWalk: [SKTexture] = CrabSprite.walkTextures
    private var tintedIdle: SKTexture { tintedWalk.first ?? CrabSprite.idleTexture }

    var title: String = "" { didSet { if title != oldValue { updateLabel() } } }
    var projectColor: NSColor = CrabPalette.colors[0] { didSet { if projectColor != oldValue { applyColor() } } }

    var facingRight = true { didSet { sprite.xScale = (facingRight ? 1 : -1) * abs(sprite.xScale) } }

    /// The body's footprint (not the whole pet cell), used for spacing and clamping.
    var size: CGSize { usesPet ? Self.petBody : sprite.size }
    var bodyFrame: CGRect {
        if usesPet {
            return CGRect(x: position.x - Self.petBody.width / 2, y: position.y + Self.petBodyBottom,
                          width: Self.petBody.width, height: Self.petBody.height)
        }
        let s = sprite.size
        return CGRect(x: position.x - s.width / 2, y: position.y, width: s.width, height: s.height)
    }
    var currentStatus: CrabStatus { status }

    /// Width of the name tag, so the scene can keep neighbours' tags from overlapping.
    private(set) var tagWidth: CGFloat = 22
    /// 0 = normal height; higher levels lift the tag so it clears a close neighbour's tag.
    var tagLevel = 0 {
        didSet {
            guard tagLevel != oldValue else { return }
            tagNode.removeAllActions()
            tagNode.run(.moveTo(y: tagBaseY + CGFloat(tagLevel) * 15, duration: 0.15))
        }
    }

    // MARK: Wander state (driven by PlaypenScene)

    var wanderTarget: CGFloat?
    var nextWanderAt: TimeInterval = 0
    var holdUntil: TimeInterval = 0
    private(set) var isMoving = false

    /// Only relaxed crabs roam. Working crabs (and everyone else) stand still and just animate.
    var canWander: Bool { !isBaby && status == .doneSeen }

    init(id: String, isBaby: Bool = false) {
        self.id = id
        self.isBaby = isBaby
        self.usesPet = !isBaby && PetLibrary.isAvailable
        if usesPet {
            sprite = SKSpriteNode(texture: nil, size: CGSize(width: Self.petSize, height: Self.petSize))
        } else {
            let scale = isBaby ? Self.babyScale : 1.0
            sprite = SKSpriteNode(texture: CrabSprite.idleTexture)
            sprite.size = CGSize(width: CrabSprite.frameSize.width * scale,
                                 height: CrabSprite.frameSize.height * scale)
        }
        sprite.anchorPoint = CGPoint(x: 0.5, y: usesPet ? Self.petAnchorY : 0)
        super.init()
        addChild(sprite)
        if !isBaby { buildNameTag() }
        buildBadge()
        alpha = isBaby ? 0.9 : 1
        setStatus(.working)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Name tag

    private func buildNameTag() {
        nameLabel.fontName = "Menlo-Bold"
        nameLabel.fontSize = 9.5
        nameLabel.fontColor = .white
        nameLabel.verticalAlignmentMode = .center
        nameLabel.horizontalAlignmentMode = .center
        nameLabel.zPosition = 2
        nameBackground.strokeColor = .clear
        nameBackground.fillColor = NSColor.black.withAlphaComponent(0.62)
        nameBackground.zPosition = 1
        nameBackground.alpha = 1
        // Above the body, and above the props (brackets, wrenches, question marks) that float over it.
        tagBaseY = usesPet ? Self.petTagY : sprite.size.height + 9
        tagNode.position = CGPoint(x: 0, y: tagBaseY)
        tagNode.zPosition = 6
        tagNode.addChild(nameBackground)
        tagNode.addChild(nameLabel)
        addChild(tagNode)
    }

    private func updateLabel() {
        guard !isBaby else { return }
        let short = title.count > 22 ? String(title.prefix(21)) + "…" : title
        nameLabel.text = short
        let w = max(nameLabel.frame.width + 14, 24), h: CGFloat = 15
        tagWidth = w
        nameBackground.path = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                     cornerWidth: 4, cornerHeight: 4, transform: nil)
    }

    /// Dim the whole tag (pill + text) once the session is done and seen; full strength otherwise.
    private func updateTagFade() {
        guard !isBaby else { return }
        let wanted: CGFloat = status == .doneSeen ? Self.restingTagAlpha : 1
        guard abs(tagNode.alpha - wanted) > 0.01 else { return }
        tagNode.removeAction(forKey: "fade")
        tagNode.run(.fadeAlpha(to: wanted, duration: 0.45), withKey: "fade")
    }

    // MARK: - Badge

    private func buildBadge() {
        let r: CGFloat = isBaby ? 6 : 8
        badgeCircle.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        badgeCircle.strokeColor = NSColor.white.withAlphaComponent(0.85)
        badgeCircle.lineWidth = 1
        badgeCircle.zPosition = 1
        badgeSymbol.zPosition = 2
        badgeSymbol.size = CGSize(width: r * 1.4, height: r * 1.4)
        badgeNode.addChild(badgeCircle)
        badgeNode.addChild(badgeSymbol)
        if usesPet {
            badgeNode.position = CGPoint(x: Self.petBody.width * 0.5 + 4,
                                         y: Self.petBodyBottom + Self.petBody.height - 2)
        } else {
            badgeNode.position = CGPoint(x: sprite.size.width * 0.42, y: sprite.size.height - r * 0.5)
        }
        badgeNode.zPosition = 5
        badgeNode.isHidden = true
        addChild(badgeNode)
    }

    private func updateBadge() {
        guard Self.badgesEnabled, let style = BadgeStyle.forStatus(status) else {
            badgeNode.isHidden = true
            badgeNode.removeAction(forKey: "pulse")
            return
        }
        badgeNode.isHidden = false
        badgeCircle.fillColor = style.color
        badgeSymbol.texture = BadgeIcon.texture(style.symbol, pointSize: isBaby ? 8 : 11)
        badgeNode.removeAction(forKey: "pulse")
        if status.needsYou {
            let pulse = SKAction.sequence([.scale(to: 1.18, duration: 0.5), .scale(to: 1.0, duration: 0.5)])
            pulse.timingMode = .easeInEaseOut
            badgeNode.run(.repeatForever(pulse), withKey: "pulse")
        } else {
            badgeNode.setScale(1)
        }
    }

    // MARK: - Color

    private func applyColor() {
        hueDegrees = CrabPalette.hueDegrees(of: projectColor)
        if !usesPet { tintedWalk = CrabSprite.walkTextures(hueDegrees: hueDegrees) }
        // Restart the current animation so it picks up the recolored frames.
        if isMoving { playMoving() } else { applyGait(force: true) }
    }

    // MARK: - Status + animation

    func setStatus(_ newStatus: CrabStatus) {
        let old = status
        let changed = newStatus != status
        status = newStatus
        if changed { updateBadge(); updateTagFade() }
        // A tool pause may finish the current walk (so a crab never stops on top of a neighbour);
        // any other non-roaming status stops it where it is.
        if changed, !canWander, newStatus != .usingTool { wanderTarget = nil; isMoving = false }
        if !isMoving { applyGait(force: changed || sprite.action(forKey: "gait") == nil) }
        if changed, newStatus == .doneUnseen, old.isBusy, !usesPet { celebrate() }
    }

    private func applyGait(force: Bool) {
        guard force else { return }
        sprite.removeAction(forKey: "gait")
        removeAction(forKey: "hop")
        removeAction(forKey: "zzz")
        sprite.position = .zero
        sprite.zRotation = 0
        sprite.yScale = 1
        sprite.alpha = 1
        if usesPet { petGait() } else { pixelGait() }
    }

    /// Pets carry their own animation per state; we just play the right sheet.
    private func petGait() {
        let key: String
        switch status {
        case .working:         key = workingPetKey
        case .usingTool:       key = workingPetKey  // same animation as working, by request
        case .needsPermission: key = "needsPermission"
        case .needsQuestion:   key = "needsQuestion"
        case .doneUnseen:      key = "doneUnseen"
        case .doneSeen:        key = "doneSeen"
        case .dormant:         key = "dormant"
        case .error:           key = "error"
        }
        playPet(key, loop: true)
        if status == .dormant { sprite.alpha = 0.8 }
    }

    private func playPet(_ key: String, loop: Bool, completion: (() -> Void)? = nil) {
        let frames = PetLibrary.frames(key, hueDegrees: hueDegrees)
        guard !frames.isEmpty else { return }
        sprite.removeAction(forKey: "gait")
        let anim = SKAction.animate(with: frames, timePerFrame: 1.0 / PetLibrary.fps, resize: false, restore: false)
        if loop {
            sprite.run(.repeatForever(anim), withKey: "gait")
        } else if let completion {
            sprite.run(.sequence([anim, .run(completion)]), withKey: "gait")
        } else {
            sprite.run(anim, withKey: "gait")
        }
    }

    /// The pixel crab has no poses of its own, so we act them out with small motions.
    private func pixelGait() {
        switch status {
        case .working:
            march(timePerFrame: 0.07)
        case .usingTool:
            sprite.texture = tintedIdle
            breathe()
        case .needsPermission, .needsQuestion:
            sprite.texture = tintedIdle
            jump()
        case .doneUnseen:
            sprite.texture = tintedIdle
            breathe()
            occasionalHop()
        case .doneSeen:
            sprite.texture = tintedIdle
            breathe()
        case .dormant:
            sprite.texture = tintedIdle
            sleep()
        case .error:
            sprite.texture = tintedIdle
            dizzy()
        }
    }

    private func march(timePerFrame: TimeInterval) {
        sprite.removeAction(forKey: "gait")
        sprite.position = .zero
        let walk = SKAction.animate(with: tintedWalk, timePerFrame: timePerFrame, resize: false, restore: false)
        sprite.run(.repeatForever(walk), withKey: "gait")
    }

    private func breathe() {
        let bob = SKAction.sequence([.moveBy(x: 0, y: 2, duration: 0.7), .moveBy(x: 0, y: -2, duration: 0.7)])
        bob.timingMode = .easeInEaseOut
        sprite.run(.repeatForever(bob), withKey: "gait")
    }

    private func jump() {
        let up = SKAction.moveBy(x: 0, y: 10, duration: 0.22); up.timingMode = .easeOut
        let down = SKAction.moveBy(x: 0, y: -10, duration: 0.22); down.timingMode = .easeIn
        sprite.run(.repeatForever(.sequence([up, down, .wait(forDuration: 0.25)])), withKey: "gait")
    }

    private func occasionalHop() {
        let hop = SKAction.sequence([.moveBy(x: 0, y: 7, duration: 0.18), .moveBy(x: 0, y: -7, duration: 0.18)])
        run(.repeatForever(.sequence([.wait(forDuration: 3.0, withRange: 2.0), hop])), withKey: "hop")
    }

    private func dizzy() {
        let wobble = SKAction.sequence([.rotate(toAngle: 0.12, duration: 0.25),
                                        .rotate(toAngle: -0.12, duration: 0.25)])
        wobble.timingMode = .easeInEaseOut
        sprite.run(.repeatForever(wobble), withKey: "gait")
    }

    private func sleep() {
        sprite.alpha = 0.55
        sprite.yScale = 0.72
        let spawnZ = SKAction.run { [weak self] in self?.floatZ() }
        run(.repeatForever(.sequence([.wait(forDuration: 2.4, withRange: 1.2), spawnZ])), withKey: "zzz")
    }

    private func floatZ() {
        let z = SKLabelNode(text: "z")
        z.fontName = "Menlo-Bold"
        z.fontSize = isBaby ? 7 : 9
        z.fontColor = BadgeStyle.Palette.sleep
        z.position = CGPoint(x: sprite.size.width * 0.25, y: sprite.size.height * 0.6)
        z.zPosition = 4
        addChild(z)
        let drift = SKAction.group([.moveBy(x: 6, y: 16, duration: 1.6), .fadeOut(withDuration: 1.6)])
        drift.timingMode = .easeOut
        z.run(.sequence([drift, .removeFromParent()]))
    }

    /// Two quick hops (pixel crabs only; the celebrating pet jumps by itself).
    func celebrate() {
        removeAction(forKey: "celebrate")
        let hop = SKAction.sequence([.moveBy(x: 0, y: 12, duration: 0.15), .moveBy(x: 0, y: -12, duration: 0.15)])
        hop.timingMode = .easeOut
        run(.sequence([hop, .wait(forDuration: 0.1), hop]), withKey: "celebrate")
    }

    /// A quick side-to-side wiggle when a crab arrives.
    func wave() {
        let wiggle = SKAction.sequence([.rotate(toAngle: 0.2, duration: 0.1),
                                        .rotate(toAngle: -0.2, duration: 0.2),
                                        .rotate(toAngle: 0.2, duration: 0.2),
                                        .rotate(toAngle: 0, duration: 0.1)])
        sprite.run(wiggle, withKey: "wave")
    }

    // MARK: - Moving, leaving, dragging

    private func playMoving() {
        if usesPet { playPet("moving", loop: true) } else { march(timePerFrame: status == .working ? 0.07 : 0.1) }
    }

    func startMoving() {
        guard !isMoving else { return }
        isMoving = true
        removeAction(forKey: "hop")
        playMoving()
    }

    func stopMoving() {
        guard isMoving else { return }
        isMoving = false
        applyGait(force: true)
    }

    /// Plays the leaving animation once, then calls `completion`. Pixel crabs just keep marching.
    func showLeaving(completion: @escaping () -> Void) {
        wanderTarget = nil
        isMoving = false
        removeAction(forKey: "hop"); removeAction(forKey: "zzz"); removeAction(forKey: "celebrate")
        sprite.zRotation = 0; sprite.yScale = 1; sprite.alpha = 1
        if usesPet, !PetLibrary.frames("leaving", hueDegrees: hueDegrees).isEmpty {
            playPet("leaving", loop: false, completion: completion)
        } else {
            march(timePerFrame: 0.05)
            completion()
        }
    }

    func showDragging() {
        wanderTarget = nil
        isMoving = false
        removeAction(forKey: "hop"); removeAction(forKey: "zzz"); removeAction(forKey: "celebrate")
        sprite.zRotation = 0; sprite.yScale = 1; sprite.alpha = 1
        if usesPet { playPet("moving", loop: true) } else { march(timePerFrame: 0.05) }
    }

    func restoreStatus() {
        applyGait(force: true)
    }
}
