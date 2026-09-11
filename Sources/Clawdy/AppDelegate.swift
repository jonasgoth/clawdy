import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let version = "0.3.0"

    private var statusItem: NSStatusItem!
    private var playpen: PlaypenController!
    private var store: SessionStore!

    private var menu: NSMenu!
    private let crabCountItem = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Hide playpen", action: #selector(togglePlaypen), keyEquivalent: "")
    private let hooksItem = NSMenuItem(title: "Turn on instant updates…", action: #selector(toggleHooks), keyEquivalent: "")
    private var sessionSeparatorTop: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        playpen = PlaypenController()
        store = SessionStore(scene: playpen.scene)

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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Clawdy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        playpen.show()
        store.start()
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
        case .usingTool:       return "🔧"
        case .dormant:         return "💤"
        case .working:         return "●"
        }
    }
}
