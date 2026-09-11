import AppKit
import SpriteKit

/// The see-through strip the crabs live in. Never takes keyboard focus.
final class PlaypenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PlaypenView: SKView {
    /// A click on a crab should grab it right away, not just "activate" the panel first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel and keeps it "solid only over crabs": the panel ignores the mouse
/// unless the cursor is on a crab or a drag is in progress, so clicks on empty strip
/// go straight through to whatever app is behind it.
final class PlaypenController {
    static let stripHeight: CGFloat = 130

    let panel: PlaypenPanel
    let skView: PlaypenView
    let scene: PlaypenScene
    private var monitors: [Any] = []

    init() {
        let frame = Self.stripFrame()

        panel = PlaypenPanel(contentRect: frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        skView = PlaypenView(frame: NSRect(origin: .zero, size: frame.size))
        skView.allowsTransparency = true
        skView.ignoresSiblingOrder = true
        skView.preferredFramesPerSecond = 60
        skView.autoresizingMask = [.width, .height]

        scene = PlaypenScene(size: frame.size)
        skView.presentScene(scene)
        panel.contentView = skView

        // Global = events going to other apps (cursor over empty strip or elsewhere).
        // Local = events going to us (cursor over a crab, or mid-drag). Need both.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.updateMousePassthrough()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.updateMousePassthrough()
            return event
        }) { monitors.append(m) }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
    }

    /// Full width of the main screen, sitting just above the Dock.
    static func stripFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: stripHeight)
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.logCrabRect() }
    }

    func hide() { panel.orderOut(nil) }

    func reposition() { panel.setFrame(Self.stripFrame(), display: true) }

    func updateMousePassthrough() {
        guard panel.isVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        var solid = scene.isDragging
        if !solid, panel.frame.contains(screenPoint) {
            let windowPoint = panel.convertPoint(fromScreen: screenPoint)
            let scenePoint = skView.convert(windowPoint, to: scene)
            solid = scene.crab(at: scenePoint) != nil
        }
        if panel.ignoresMouseEvents == solid {
            panel.ignoresMouseEvents = !solid
            debugLog(solid ? "solid (cursor on crab)" : "pass-through")
            if !solid { logCrabRect() }
        }
    }

    /// Set CLAWDY_DEBUG=1 to see pass-through flips and the crab's screen rect on stderr.
    private static let debugEnabled = ProcessInfo.processInfo.environment["CLAWDY_DEBUG"] == "1"

    private func debugLog(_ message: String) {
        guard Self.debugEnabled else { return }
        FileHandle.standardError.write(("[clawdy] " + message + "\n").data(using: .utf8)!)
    }

    /// Screen-coordinate rect of the first crab (bottom-left origin). Debug only.
    func logCrabRect() {
        guard Self.debugEnabled, let crab = scene.crabs.first else { return }
        let sceneRect = crab.bodyFrame
        let a = skView.convert(CGPoint(x: sceneRect.minX, y: sceneRect.minY), from: scene)
        let b = skView.convert(CGPoint(x: sceneRect.maxX, y: sceneRect.maxY), from: scene)
        let viewRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let screenRect = panel.convertToScreen(viewRect)
        debugLog("crab screen rect x=\(Int(screenRect.minX)) y=\(Int(screenRect.minY)) w=\(Int(screenRect.width)) h=\(Int(screenRect.height)) panel=\(panel.frame)")
    }
}
