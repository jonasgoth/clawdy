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

    /// Rows for busy sessions: their Claude asterisk is redrawn on a timer while the menu is open.
    private var spinningRows: [NSMenuItem] = []
    private var spinTimer: Timer?
    private var spinFrame = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        playpen = PlaypenController()
        seen.start()
        store = SessionStore(scene: playpen.scene, seen: seen)
        // Clicking a crab opened that chat, so the store can stop calling it unseen.
        playpen.scene.onOpened = { [weak self] id in self?.store.markOpened(id) }

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
        // macOS gives Quit its own icon, so the other actions get one too and the column lines up.
        reset.image = Self.actionIcon("sparkles")
        hooksItem.image = Self.actionIcon("bolt")
        axItem.image = Self.actionIcon("macwindow")
        soundItem.image = Self.actionIcon("speaker.wave.2")
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

    func menuWillOpen(_ menu: NSMenu) {
        rebuildSessionRows()
        spinFrame = 0
        spinTimer?.invalidate()
        guard !spinningRows.isEmpty else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.spinTick() }
        RunLoop.main.add(t, forMode: .common)   // .common covers menu tracking, so it keeps ticking
        spinTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        spinTimer?.invalidate()
        spinTimer = nil
        spinningRows = []
    }

    private func spinTick() {
        spinFrame = (spinFrame + 1) % ClaudeMark.steps
        let frame = ClaudeMark.image(step: spinFrame)
        for item in spinningRows { item.image = frame }
    }

    /// A plain menu-action icon, in the grey AppKit uses for the ones it adds itself.
    private static func actionIcon(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// The little mark in front of a session row: a tinted SF Symbol for every resting state.
    private static func markImage(_ status: CrabStatus) -> NSImage? {
        let style = BadgeStyle.forStatus(status)
        let name = style?.symbol ?? "circle"
        let color = style?.color ?? NSColor.tertiaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.size = NSSize(width: 14, height: 14)
        return image
    }

    @objc private func togglePlaypen() {
        if playpen.isVisible { playpen.hide() } else { playpen.show() }
    }

    @objc private func resetCrabs() { playpen.scene.resetCrabs() }

    /// Session rows are a readout, not a button — but they need an action to avoid being greyed out.
    @objc private func noop() {}

    /// Jump to the chat: the Desktop app switches to it, or its terminal window comes forward.
    /// Landing there is proof you have seen it, so the crab drops its badge.
    @objc private func openSession(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionOpener.Request else { return }
        if SessionOpener.open(request.target) { store.markOpened(request.sessionId) }
    }

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
        toggleItem.image = Self.actionIcon(playpen.isVisible ? "eye.slash" : "eye")
        hooksItem.title = HookInstaller.isInstalled ? "Turn off instant updates" : "Turn on instant updates…"
        soundItem.state = SoundPlayer.enabled ? .on : .off
        let trusted = AXIsProcessTrusted()
        axItem.title = trusted ? "Window checks: on" : "Allow window checks…"
        axItem.isEnabled = !trusted

        // Drop the old session rows: everything between the count line and the separator.
        // The index has to be re-read each pass, or the loop walks off the end and eats the
        // separator plus the actions below it (that is why the menu sometimes came up bare).
        let firstRow = menu.index(of: crabCountItem) + 1
        while firstRow < menu.numberOfItems, menu.item(at: firstRow) !== sessionSeparatorTop {
            menu.removeItem(at: firstRow)
        }
        var insertAt = menu.index(of: sessionSeparatorTop)
        spinningRows = []
        for row in rows {
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            if row.status.isBusy {
                item.image = ClaudeMark.image(step: spinFrame)
                spinningRows.append(item)
            } else {
                item.image = Self.markImage(row.status)
            }
            // Live rows draw full-strength (macOS greys out disabled items, which muted the
            // asterisk). Desktop chats open on click; a terminal session has nothing to open,
            // so its row keeps the no-op and stays a plain readout.
            item.representedObject = row.open.map { SessionOpener.Request(sessionId: row.id, target: $0) }
            item.action = row.open == nil ? #selector(noop) : #selector(openSession(_:))
            item.toolTip = row.open == nil ? nil : "Go to this chat"
            item.target = self
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
    }

}
