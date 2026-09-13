import AppKit

/// One box in the menu's settings grid: what it controls on top, and what it is
/// doing right now underneath, as a small icon plus a word. The box picks up a
/// light colour when the thing is on, so the state is readable at a glance.
final class MenuCard: NSView {
    struct Model {
        var title: String
        var status: String
        var symbol: String
        /// nil draws the plain grey "off" box; a colour tints the whole card.
        var tint: NSColor?
        /// Actions that change something on the desktop dismiss the menu so you can see it.
        var closesMenu: Bool = false
        var action: () -> Void
    }

    static let height: CGFloat = 48

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hovering = false
    private var model: Model

    init(model: Model) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Self.height))
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(titleLabel)
        addSubview(icon)
        addSubview(statusLabel)
        setAccessibilityRole(.button)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Flipping a switch redraws the same box rather than building a new one, so the card
    /// survives the click that is still being handled inside it.
    func update(_ model: Model) {
        self.model = model
        apply()
    }

    private func apply() {
        titleLabel.stringValue = model.title
        statusLabel.stringValue = model.status
        let colour = model.tint ?? .secondaryLabelColor
        statusLabel.textColor = colour
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        icon.image = NSImage(systemSymbolName: model.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        setAccessibilityLabel("\(model.title): \(model.status)")
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 9
        titleLabel.frame = NSRect(x: pad, y: bounds.height - pad - 14,
                                  width: max(0, bounds.width - pad * 2), height: 14)
        let side: CGFloat = 13
        icon.frame = NSRect(x: pad, y: pad + 1, width: side, height: side)
        statusLabel.frame = NSRect(x: pad + side + 5, y: pad - 1,
                                   width: max(0, bounds.width - pad * 2 - side - 5), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        if let tint = model.tint {
            tint.withAlphaComponent(hovering ? 0.26 : 0.15).setFill()
            path.fill()
            tint.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(hovering ? 0.13 : 0.06).setFill()
            path.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if model.closesMenu { enclosingMenuItem?.menu?.cancelTracking() }
        model.action()
    }
}

/// The block of setting boxes at the bottom of the menu. Anything the app still
/// needs you to switch on gets a full-width box at the top; the everyday toggles
/// sit under it in two columns.
final class MenuGridView: NSView {
    private static let gap: CGFloat = 6
    private static let sideInset: CGFloat = 13
    private static let topInset: CGFloat = 4
    private static let bottomInset: CGFloat = 6

    private var wideCards: [MenuCard] = []
    private var gridCards: [MenuCard] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 288, height: 0))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCards(wide: [MenuCard.Model], grid: [MenuCard.Model]) {
        if wide.count == wideCards.count, grid.count == gridCards.count {
            zip(wideCards, wide).forEach { $0.update($1) }
            zip(gridCards, grid).forEach { $0.update($1) }
            return
        }
        subviews.forEach { $0.removeFromSuperview() }
        wideCards = wide.map(MenuCard.init(model:))
        gridCards = grid.map(MenuCard.init(model:))
        (wideCards + gridCards).forEach(addSubview)
        let rows = wideCards.count + (gridCards.count + 1) / 2
        let height = rows == 0 ? 0
            : Self.topInset + Self.bottomInset
              + CGFloat(rows) * MenuCard.height + CGFloat(rows - 1) * Self.gap
        setFrameSize(NSSize(width: frame.width, height: height))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let usable = bounds.width - Self.sideInset * 2
        var y = bounds.height - Self.topInset - MenuCard.height
        for card in wideCards {
            card.frame = NSRect(x: Self.sideInset, y: y, width: usable, height: MenuCard.height)
            y -= MenuCard.height + Self.gap
        }
        let half = (usable - Self.gap) / 2
        for (index, card) in gridCards.enumerated() {
            let right = index % 2 == 1
            // A lone card on the last row stretches, so the grid never looks half-empty.
            let alone = !right && index == gridCards.count - 1
            let width = alone ? usable : half
            let x = Self.sideInset + (right ? half + Self.gap : 0)
            card.frame = NSRect(x: x, y: y, width: width, height: MenuCard.height)
            if right || alone { y -= MenuCard.height + Self.gap }
        }
    }
}
