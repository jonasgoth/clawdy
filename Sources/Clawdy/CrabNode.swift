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

/// One crab, standing for one Claude session (or, when `isBaby`, one sub-agent). Origin is
/// between its feet, so `position.y == floorY` means standing on the floor.
final class CrabNode: SKNode {
    /// Full-size crabs. Babies are drawn smaller.
    static let pixelScale: CGFloat = 1.0
    static let babyScale: CGFloat = 0.6

    let id: String
    let isBaby: Bool
    private let sprite: SKSpriteNode
    private let nameLabel = SKLabelNode()
    private let nameBackground = SKShapeNode()
    private let tagNode = SKNode()

    private let badgeNode = SKNode()
    private let badgeCircle = SKShapeNode(circleOfRadius: 8)
    private let badgeSymbol = SKSpriteNode()

    private var status: CrabStatus = .working
    private var tintedWalk: [SKTexture] = CrabSprite.walkTextures
    private var tintedIdle: SKTexture { tintedWalk.first ?? CrabSprite.idleTexture }

    var title: String = "" { didSet { if title != oldValue { updateLabel() } } }
    var projectColor: NSColor = CrabPalette.colors[0] { didSet { if projectColor != oldValue { applyColor() } } }

    var facingRight = true { didSet { sprite.xScale = (facingRight ? 1 : -1) * abs(sprite.xScale) } }

    var size: CGSize { sprite.size }
    var bodyFrame: CGRect {
        let s = sprite.size
        return CGRect(x: position.x - s.width / 2, y: position.y, width: s.width, height: s.height)
    }

    init(id: String, isBaby: Bool = false) {
        self.id = id
        self.isBaby = isBaby
        let scale = isBaby ? Self.babyScale : Self.pixelScale
        sprite = SKSpriteNode(texture: CrabSprite.idleTexture)
        sprite.size = CGSize(width: CrabSprite.frameSize.width * scale,
                             height: CrabSprite.frameSize.height * scale)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
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
        nameLabel.fontSize = 8
        nameLabel.fontColor = .white
        nameLabel.verticalAlignmentMode = .center
        nameLabel.horizontalAlignmentMode = .center
        nameLabel.zPosition = 2
        nameBackground.strokeColor = .clear
        nameBackground.zPosition = 1
        nameBackground.alpha = 0.92
        tagNode.position = CGPoint(x: 0, y: sprite.size.height + 9)
        tagNode.addChild(nameBackground)
        tagNode.addChild(nameLabel)
        addChild(tagNode)
    }

    private func updateLabel() {
        guard !isBaby else { return }
        let short = title.count > 22 ? String(title.prefix(21)) + "…" : title
        nameLabel.text = short
        let w = max(nameLabel.frame.width + 12, 22), h: CGFloat = 13
        nameBackground.path = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                     cornerWidth: 4, cornerHeight: 4, transform: nil)
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
        // Top-right shoulder of the crab.
        badgeNode.position = CGPoint(x: sprite.size.width * 0.42, y: sprite.size.height - r * 0.5)
        badgeNode.zPosition = 5
        badgeNode.isHidden = true
        addChild(badgeNode)
    }

    private func updateBadge() {
        guard let style = BadgeStyle.forStatus(status) else {
            badgeNode.isHidden = true
            badgeNode.removeAction(forKey: "pulse")
            return
        }
        badgeNode.isHidden = false
        badgeCircle.fillColor = style.color
        badgeSymbol.texture = BadgeIcon.texture(style.symbol, pointSize: isBaby ? 8 : 11)
        // Attention badges pulse; quiet ones (done, dormant, tool) sit still.
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
        nameBackground.fillColor = projectColor
        tintedWalk = CrabSprite.walkTextures(hueDegrees: CrabPalette.hueDegrees(of: projectColor))
        // Restart the current gait so it picks up the recolored frames, even if the status is
        // unchanged (otherwise a still-marching crab keeps its old color).
        applyGait(force: true)
    }

    // MARK: - Status + animation

    func setStatus(_ newStatus: CrabStatus) {
        let changed = newStatus != status
        status = newStatus
        if changed { updateBadge() }
        applyGait(force: changed || sprite.action(forKey: "gait") == nil)
    }

    private func applyGait(force: Bool) {
        guard force else { return }
        sprite.removeAction(forKey: "gait")
        removeAction(forKey: "hop")
        sprite.position = .zero
        sprite.zRotation = 0
        sprite.alpha = 1

        switch status {
        case .working:
            march(timePerFrame: 0.07)
        case .usingTool:
            // Paused, holding a tool. Legs still, gentle breathing.
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
            sprite.alpha = 0.55
        case .error:
            sprite.texture = tintedIdle
            dizzy()
        }
    }

    private func march(timePerFrame: TimeInterval) {
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
        let pause = SKAction.wait(forDuration: 0.25)
        sprite.run(.repeatForever(.sequence([up, down, pause])), withKey: "gait")
    }

    private func occasionalHop() {
        let hop = SKAction.sequence([.moveBy(x: 0, y: 7, duration: 0.18), .moveBy(x: 0, y: -7, duration: 0.18)])
        let wait = SKAction.wait(forDuration: 3.0, withRange: 2.0)
        run(.repeatForever(.sequence([wait, hop])), withKey: "hop")
    }

    private func dizzy() {
        let wobble = SKAction.sequence([.rotate(toAngle: 0.12, duration: 0.25),
                                        .rotate(toAngle: -0.12, duration: 0.25)])
        wobble.timingMode = .easeInEaseOut
        sprite.run(.repeatForever(wobble), withKey: "gait")
    }

    // MARK: - Dragging

    func showDragging() {
        status = .working
        updateBadge()
        sprite.removeAction(forKey: "gait")
        removeAction(forKey: "hop")
        sprite.position = .zero
        sprite.zRotation = 0
        sprite.alpha = 1
        march(timePerFrame: 0.05)
    }

    func restoreStatus() {
        let s = status
        status = .working
        setStatus(s)
    }
}
