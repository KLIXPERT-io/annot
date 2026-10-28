import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

/// Permission checks for onboarding (APP-4).
enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// true = allowed, false = denied, nil = not asked yet / browser not running. Can block: call off the main thread.
    static func automation(_ browser: Browser, ask: Bool) -> Bool? {
        let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case Int(noErr): return true
        case errAEEventNotPermitted: return false
        default: return nil
        }
    }

    /// macOS shows its alert (and lists ANNOT in System Settings) only the first time; after that, open the list.
    static func requestAccessibility() {
        if UserDefaults.standard.bool(forKey: "askedAccessibility") { openPane("Privacy_Accessibility"); return }
        UserDefaults.standard.set(true, forKey: "askedAccessibility")
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
    }

    /// macOS asks once per browser, and only while it runs: starts it first if needed.
    static func requestAutomation(_ browser: Browser) {
        let launch = !browser.isRunning
        if launch { open(browser) }
        DispatchQueue.global(qos: .userInitiated).async {
            if launch {
                for _ in 0..<40 where !browser.isRunning { Thread.sleep(forTimeInterval: 0.25) }
                Thread.sleep(forTimeInterval: 1) // up, but not yet answering Apple Events
            }
            if automation(browser, ask: true) == false { openPane("Privacy_Automation") }
        }
    }

    static func open(_ browser: Browser) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

/// Open at login, through the system's Login Items: what's set in System Settings › General › Login Items counts.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Settings: General, Account (Rome) and Permissions as toolbar tabs. The window takes the selected tab's size and
/// follows it as it changes (connecting, an error line). A tab's icon turns into a warning when it needs attention.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int { case general, account, permissions }

    private let tabs = SettingsTabs()
    private var bag = Set<AnyCancellable>()
    private var poll: Timer?

    init() {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        super.init(window: w)
        tabs.add(GeneralSettings(), "General", "gearshape")
        tabs.add(AccountSettings(), "Account", "person.crop.circle")
        tabs.add(PermissionsSettings(), "Permissions", "lock.shield")
        w.contentViewController = tabs
        w.delegate = self
        Tickets.shared.$rejected.sink { [weak self] in
            self?.tabs.setSymbol($0 ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle", of: .account)
        }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Opens on `tab`. Without one: where setup starts on the first launch, else the tab used last.
    func show(_ tab: Tab? = nil) {
        let first = !Settings.shared.onboarded
        let saved = Tab(rawValue: UserDefaults.standard.integer(forKey: "settingsTab")) ?? .general
        let pick = tab ?? (!first ? saved : !Tickets.shared.hasToken ? .account : !Permissions.accessibility ? .permissions : .general)
        tabs.selectedTabViewItemIndex = pick.rawValue
        if window?.isVisible != true {
            tabs.fit()
            window?.center()
        }
        checkPermissions()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkPermissions() }
        NSApp.activate()
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        Settings.shared.onboarded = true
    }

    private func checkPermissions() {
        tabs.setSymbol(Permissions.accessibility ? "lock.shield" : "exclamationmark.shield", of: .permissions)
    }
}

/// Toolbar tabs, each a SwiftUI view whose ideal size becomes the window's content size.
private final class SettingsTabs: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func add<V: View>(_ view: V, _ label: String, _ symbol: String) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    func setSymbol(_ symbol: String, of tab: SettingsWindowController.Tab) {
        let item = tabViewItems[tab.rawValue]
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: "settingsTab")
        fit()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController === tabViewItems[selectedTabViewItemIndex].viewController { fit() }
    }

    /// Resizes the window to the selected tab, keeping its top edge where it is.
    func fit() {
        guard let window = view.window, let size = tabViewItems[selectedTabViewItemIndex].viewController?.preferredContentSize,
              size.width > 0, size.height > 0 else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard frame.size != window.frame.size else { return }
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height),
                        display: true, animate: window.isVisible)
    }
}

extension Text {
    /// Markdown parsed at runtime: a literal with interpolation isn't, so its links wouldn't work.
    init(markdown: String) { self.init((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)) }
}

/// Every tab is a grouped form of the same width.
extension View {
    func settingsPage() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var tickets = Tickets.shared
    @State private var login = LaunchAtLogin.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ANNOT").font(.system(size: 15, weight: .semibold))
                        Text("Press \(settings.triggerLabel) anywhere, click what you mean, type. Find them all under Comments in the menu bar.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if let account = tickets.account {
                    LabeledContent("Name", value: account.name)
                } else {
                    TextField("Name", text: $settings.author)
                }
            } header: {
                Text("You")
            } footer: {
                Text(markdown: tickets.account == nil ? "Shown on your comments and replies."
                     : "From your Rome account, so comments look the same here and in Rome. [Change it in Rome](\(Rome.web("/settings/profile")))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Comment mode") {
                Toggle(isOn: $settings.doubleTapOption) {
                    Text("Double-tap ⌥ to comment")
                    Text("Tap Option twice quickly. Needs Accessibility")
                }
                LabeledContent("Shortcut") { ShortcutRecorder(combo: $settings.hotKey, taken: settings.snipHotKey) }
            }
            Section {
                LabeledContent {
                    ShortcutRecorder(combo: $settings.snipHotKey, taken: settings.hotKey)
                } label: {
                    Text("Shortcut")
                    Text("Drag over an area, draw on it, say what it shows, copy")
                }
            } header: {
                Text("Screenshot to clipboard")
            }
            Section {
                Toggle(isOn: Binding(get: { login == .enabled || login == .requiresApproval }, set: setLogin)) {
                    Text("Open at login")
                    Text("Starts in the menu bar when you log in, so \(settings.triggerLabel) always works")
                }
                if login == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Waiting for your OK")
                        Text("Turn on ANNOT in System Settings › General › Login Items")
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Storage") {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([CommentStore.databaseURL]) }
                } label: {
                    Text("Comments and screenshots")
                    Text((CommentStore.directory.path as NSString).abbreviatingWithTildeInPath).truncationMode(.middle)
                }
            }
        }
        .settingsPage()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login = LaunchAtLogin.status }
        .onAppear { login = LaunchAtLogin.status }
    }

    private func setLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            loginError = nil
        } catch {
            loginError = "Couldn't \(on ? "add ANNOT to" : "remove ANNOT from") Login Items: \(error.localizedDescription)"
        }
        login = LaunchAtLogin.status
    }
}

private struct PermissionsSettings: View {
    @State private var ax = Permissions.accessibility
    @State private var screen = Permissions.screenRecording
    @State private var automation: [String: Bool?] = [:]
    @State private var browserStates: [String: BrowserState] = [:]

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Accessibility", detail: "Identify the element you click in any app", ok: ax,
                              action: "Grant", perform: Permissions.requestAccessibility)
                PermissionRow(title: "Screenshots (optional)",
                              detail: screen ? "A cropped screenshot is saved with each comment, and \(Settings.shared.snipHotKey.label) takes one to copy"
                                             : "Off. macOS lists this as “Screen & System Audio Recording”; no audio is recorded",
                              ok: screen ? true : nil, action: "Turn On", perform: Permissions.requestScreenRecording)
            } footer: {
                Text("After turning on screenshots, relaunch the app.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Browser.installed, id: \.bundleID) { browserRow($0) }
            } header: {
                Text("Browsers")
            } footer: {
                Text("Each browser also needs “Allow JavaScript from Apple Events”.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Open Guide…") { (NSApp.delegate as? AppDelegate)?.showSetup() }
                } label: {
                    Text("Setup guide")
                    Text("Step by step, with a picture of each switch")
                }
            }
        }
        .settingsPage()
        .task { // while the tab is open
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func browserRow(_ b: Browser) -> some View {
        let allowed = automation[b.bundleID] ?? nil
        let js = browserStates[b.bundleID] ?? .unknown
        let row: (ok: Bool?, detail: String, action: String, perform: () -> Void)
        if allowed == false {
            row = (false, "Not allowed to control \(b.name)", "Open Settings", { Permissions.openPane("Privacy_Automation") })
        } else if js == .jsDisabled {
            row = (false, "Turn on: \(b.jsSetting)", "Open \(b.name)", { Permissions.open(b) })
        } else if allowed == true, js == .ok {
            row = (true, "Connected: pins and capture in the active tab", "", {})
        } else if allowed == true {
            row = (nil, "Allowed. Switch to a tab in \(b.name) to finish the check", "Open \(b.name)", { Permissions.open(b) })
        } else {
            row = (nil, b.isRunning ? "Control \(b.name) — macOS asks once" : "Start \(b.name) to check", "Grant", { Permissions.requestAutomation(b) })
        }
        return PermissionRow(title: b.name, detail: row.detail, ok: row.ok, action: row.action, perform: row.perform)
    }

    private func refresh() {
        ax = Permissions.accessibility
        screen = Permissions.screenRecording
        browserStates = BrowserBridge.shared.states
        DispatchQueue.global(qos: .utility).async {
            var result: [String: Bool?] = [:]
            for b in Browser.installed { result[b.bundleID] = Permissions.automation(b, ask: false) }
            DispatchQueue.main.async { automation = result }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool?
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "xmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(ok == true ? Color.green : ok == false ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if ok != true { Button(action, action: perform).controlSize(.small) }
        }
    }
}

private struct ShortcutRecorder: View {
    @Binding var combo: HotKeyCombo
    var taken: HotKeyCombo? // the other shortcut: one combo can't do both
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type shortcut…" : combo.label) { recording ? stop() : start() }
            .frame(minWidth: 110)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            let new = HotKeyCombo(code: UInt32(e.keyCode), mods: HotKey.carbonMods(flags), label: HotKey.label(flags, key: HotKey.keyName(e)))
            guard new.code != taken?.code || new.mods != taken?.mods else { NSSound.beep(); return nil }
            combo = new
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
