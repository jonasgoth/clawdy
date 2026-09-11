import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let version = "0.5.0"

    private var statusItem: NSStatusItem!
    private var playpen: PlaypenController!
    private var store: SessionStore!
    private let seen = SeenDetector()

    private var menu: NSMenu!
    private let crabCountItem = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Hide playpen", action: #selector(togglePlaypen), keyEquivalent: "")
    private let hooksItem = NSMenuItem(title: "Turn on instant updates…", action: #selector(toggleHooks), keyEquivalent: "")
    private let axItem = NSMenuItem(title: "Allow window checks…", action: #selector(requestAccessibility), keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
    private var sessionSeparatorTop: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        playpen = PlaypenController()
        seen.start()
        store = SessionStore(scene: playpen.scene, seen: seen)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = CrabSprite.menuBarImage()
            button.toolTip = "Clawdy"
        }

        menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Clawdy \(Self.version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        crabCountItem.isEnabled = false
        menu.addItem(crabCountItem)
        sessionSeparatorTop = NSMenuItem.separator()
        menu.addItem(sessionSeparatorTop)

        toggleItem.target = self
        menu.addItem(toggleItem)
        let reset = NSMenuItem(title: "Tidy crabs", action: #selector(resetCrabs), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        hooksItem.target = self
        menu.addItem(hooksItem)
        axItem.target = self
        menu.addItem(axItem)
        soundItem.target = self
        menu.addItem(soundItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Clawdy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        store.onUpdate = { [weak self] in self?.updateStatusItem() }
        playpen.show()
        store.start()
    }

    /// Menu bar shows how many crabs are alive; turns red with a "!" when one needs you.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let rows = store.rows
        let attention = rows.contains { $0.status.needsYou }
        let text = rows.isEmpty ? "" : (attention ? " \(rows.count)!" : " \(rows.count)")
        let color: NSColor = attention ? .systemRed : .labelColor
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: attention ? .bold : .medium),
        ])
        button.imagePosition = .imageLeading
    }

    @objc private func toggleSounds() {
        SoundPlayer.enabled.toggle()
        soundItem.state = SoundPlayer.enabled ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildSessionRows() }

    @objc private func togglePlaypen() {
        if playpen.isVisible { playpen.hide() } else { playpen.show() }
    }

    @objc private func resetCrabs() { playpen.scene.resetCrabs() }

    @objc private func toggleHooks() {
        if HookInstaller.isInstalled {
            switch HookInstaller.uninstall() {
            case .success: notify("Instant updates off", "Clawdy's hooks were removed from your Claude settings.")
            case .failure(let e): notify("Could not remove hooks", e.localizedDescription)
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "Turn on instant updates?"
            alert.informativeText = "Clawdy will add hooks to your Claude Code settings (~/.claude/settings.json) so crabs react instantly to permission prompts and finished turns. Your settings file is backed up first. You can turn this off any time."
            alert.addButton(withTitle: "Turn on")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            switch HookInstaller.install() {
            case .success: notify("Instant updates on", "Restart or prompt any Claude session for the hooks to take effect.")
            case .failure(let e): notify("Could not install hooks", e.localizedDescription)
            }
        }
    }

    /// Asks macOS for Accessibility permission so Clawdy can read which Claude window is in front
    /// (used to clear Cowork "done" badges precisely). Only ever runs when you click this.
    @objc private func requestAccessibility() {
        SeenDetector.requestAccessibility()
    }

    private func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func rebuildSessionRows() {
        let rows = store.rows
        crabCountItem.title = rows.isEmpty
            ? "No sessions running"
            : "\(rows.count) session\(rows.count == 1 ? "" : "s") running"
        toggleItem.title = playpen.isVisible ? "Hide playpen" : "Show playpen"
        hooksItem.title = HookInstaller.isInstalled ? "Turn off instant updates" : "Turn on instant updates…"
        soundItem.state = SoundPlayer.enabled ? .on : .off
        let trusted = AXIsProcessTrusted()
        axItem.title = trusted ? "Window checks: on" : "Allow window checks…"
        axItem.isEnabled = !trusted

        let topIndex = menu.index(of: sessionSeparatorTop)
        while topIndex > 0, let item = menu.item(at: topIndex - 1), item !== crabCountItem {
            menu.removeItem(item)
        }
        var insertAt = menu.index(of: sessionSeparatorTop)
        for row in rows {
            let item = NSMenuItem(title: "\(Self.glyph(row.status))  \(row.title)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
    }

    private static func glyph(_ status: CrabStatus) -> String {
        switch status {
        case .needsPermission: return "🔴"
        case .needsQuestion:   return "🟠"
        case .error:           return "⚠️"
        case .doneUnseen:      return "🟢"
        case .doneSeen:        return "○"
        case .usingTool:       return "🔧"
        case .dormant:         return "💤"
        case .working:         return "●"
        }
    }
}
