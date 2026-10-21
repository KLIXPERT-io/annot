import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKey()
    private let doubleTap = DoubleTap()
    private var native: NativeCapture?
    private var asking: Browser? // startCapture sent, browser hasn't answered yet
    private var cancelAsk = false
    private var settingsWindow: SettingsWindowController?
    private var setupWindow: SetupWindowController?
    private var bag = Set<AnyCancellable>()
    private let commentItem = NSMenuItem(title: "Add Comment", action: #selector(commentMode), keyEquivalent: "")
    private let projectItem = NSMenuItem(title: "Send Comments To", action: nil, keyEquivalent: "") // submenu, filled on open
    private lazy var connectItem = item("Connect to Rome…", #selector(connectRome))
    private var commentsWindow: NSWindow?
    private lazy var commentsItem = item("Comments…", #selector(showComments), key: "k")
    private var browserLines: [NSMenuItem] = []
    private let browserAnchor = NSMenuItem.separator()
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "ANNOT")

        let menu = NSMenu()
        menu.delegate = self
        commentItem.target = self
        menu.addItem(commentItem)
        projectItem.submenu = NSMenu()
        menu.addItem(projectItem)
        menu.addItem(connectItem)
        menu.addItem(.separator())
        menu.addItem(commentsItem)
        menu.addItem(browserAnchor) // browser status lines go below this
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Setup Guide…", #selector(showSetup)))
        updateItem.target = Updater.shared
        menu.addItem(updateItem)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = NSMenuItem(title: "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
                                 action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        menu.addItem(item("Quit ANNOT", #selector(quit), key: "q"))
        statusItem.menu = menu
        NSApp.mainMenu = Self.editMenu()

        HotKey.onPress = { [weak self] in self?.commentMode() }
        DoubleTap.onPress = { [weak self] in self?.commentMode() }
        Settings.shared.$hotKey
            .combineLatest(Settings.shared.$doubleTapOption)
            .sink { [weak self] combo, tap in
                guard let self else { return }
                self.hotKey.register(combo)
                if tap { self.doubleTap.start() } else { self.doubleTap.stop() }
                self.commentItem.title = "Add Comment    " + (tap ? "⌥⌥ or " : "") + combo.label
            }
            .store(in: &bag)

        CommentStore.shared.onChange = { key in BrowserBridge.shared.commentsChanged(pageKey: key) }

        Updater.shared.onPendingChange = { [weak self] pending in
            self?.updateItem.title = pending ? "Update Available…" : "Check for Updates…"
        }
        Updater.shared.start()

        BrowserBridge.shared.start()
        Task { await Tickets.shared.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            BrowserBridge.shared.kick()
        }

        if !Settings.shared.onboarded { showSetup() }
    }

    // APP-1 / APP-2
    @objc func commentMode() {
        if let native { native.finish(); return }
        if asking != nil { // pressed again while a slow browser is still answering: that's a cancel
            cancelAsk = true
            HUD.show("Comment mode cancelled")
            return
        }
        if let browser = Browser.front {
            asking = browser
            cancelAsk = false
            BrowserBridge.shared.startCapture(in: browser) { [weak self] ok in
                guard let self else { return }
                self.asking = nil
                if self.cancelAsk {
                    if ok { BrowserBridge.shared.stopCapture(in: browser) }
                    return
                }
                guard !ok else { return }
                // Never fall back silently: without the page there's no DOM, only the Accessibility path.
                switch BrowserBridge.shared.states[browser.bundleID] {
                case .jsDisabled: HUD.show("\(browser.name): turn on \(browser.jsSetting)", isError: true, seconds: 5)
                case .denied: HUD.show("Not allowed to control \(browser.name) (Privacy › Automation). Screen mode, no page details", isError: true, seconds: 5)
                default: HUD.show("Can't reach the page in \(browser.name). Screen mode, no page details", isError: true, seconds: 4)
                }
                self.startNative()
            }
        } else {
            startNative()
        }
    }

    private func startNative() {
        guard native == nil else { return } // two overlays = one we can no longer close
        let capture = NativeCapture()
        capture.onFinish = { [weak self] in self?.native = nil }
        native = capture
        capture.start()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == statusItem.menu else { return }
        let projects = Tickets.choices.all, current = Settings.shared.ticketsProject
        projectItem.isHidden = projects.isEmpty
        connectItem.isHidden = Tickets.shared.account != nil
        connectItem.title = Tickets.shared.rejected ? "Reconnect to Rome…" : "Connect to Rome…"
        projectItem.title = "Send Comments To: " + (projects.first { $0.key == current }?.key ?? "This Mac only")
        projectItem.submenu?.removeAllItems()
        for (title, key) in [("Keep on This Mac", nil)] + projects.map({ ("\($0.name) (\($0.key))", Optional($0.key)) }) {
            let i = NSMenuItem(title: title, action: #selector(chooseProject(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key
            i.state = key == current ? .on : .off
            projectItem.submenu?.addItem(i)
            if key == nil, !projects.isEmpty { projectItem.submenu?.addItem(.separator()) }
        }

        let open = CommentStore.shared.all.filter(\.isOpen).count
        commentsItem.title = open > 0 ? "Comments…  (\(open) open)" : "Comments…"
        browserLines.forEach(menu.removeItem)
        browserLines = Browser.installed.map { b in
            let title: String
            switch BrowserBridge.shared.states[b.bundleID] ?? .unknown {
            case .ok: title = "● \(b.name) connected"
            case .jsDisabled: title = "○ \(b.name): allow JavaScript from Apple Events"
            case .denied: title = "○ \(b.name): automation not allowed"
            case .unknown, .noPage: title = "○ \(b.name): waiting for a tab"
            }
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        }
        var at = menu.index(of: browserAnchor) + 1
        for line in browserLines { menu.insertItem(line, at: at); at += 1 }
    }

    @objc func showComments() {
        if commentsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Comments"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: InboxView())
            w.center()
            w.setFrameAutosaveName("Comments")
            commentsWindow = w
        }
        NSApp.activate()
        commentsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() { settings(nil) }

    @objc func connectRome() { settings(.account) }

    @objc func showSetup() {
        if setupWindow == nil {
            let w = SetupWindowController()
            w.onConnectRome = { [weak self] in self?.connectRome() }
            w.onAccessibilityGranted = { [weak self] in
                // The ⌥ monitor started without Accessibility: start it again so double-tap works right away.
                guard let self, Settings.shared.doubleTapOption else { return }
                self.doubleTap.stop()
                self.doubleTap.start()
            }
            setupWindow = w
        }
        setupWindow?.show()
    }

    private func settings(_ tab: SettingsWindowController.Tab?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show(tab)
    }

    @objc private func chooseProject(_ sender: NSMenuItem) {
        Settings.shared.ticketsProject = sender.representedObject as? String
        HUD.show(sender.representedObject == nil ? "New comments stay on this Mac" : "New comments go to \(sender.title)")
    }

    @objc func quit() { NSApp.terminate(nil) }

    /// Never shown (the app has no menu bar), but text fields only get ⌘X/⌘C/⌘V/⌘A/⌘Z through a main menu.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "ANNOT", action: nil, keyEquivalent: "")) // the first item is the app menu
        main.addItem(editItem)
        return main
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }
}
