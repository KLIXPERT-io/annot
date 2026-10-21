import AppKit
import SwiftUI

/// The setup guide: opens on the first launch (later: Setup Guide… in the menu) and walks through everything ANNOT
/// needs, one step at a time, each with a picture of where to turn it on and a live check. Closing it, at any step,
/// counts as onboarded.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    var onConnectRome: (() -> Void)?
    private let model = SetupModel()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Set Up ANNOT"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        let host = NSHostingView(rootView: SetupView(model: model,
                                                     connectRome: { [weak self] in self?.onConnectRome?() },
                                                     close: { [weak self] in self?.close() }))
        host.sizingOptions = [] // pages differ in height; the window keeps its size
        w.contentView = host
        w.delegate = self
        w.center()
        model.onProgress = { [weak self] new, step in
            // Just done in System Settings or the browser: bring the guide back, without taking the keyboard.
            if new.contains(where: { $0.hasPrefix("\(step)") }), let w = self?.window, w.isVisible, !w.isKeyWindow {
                w.orderFrontRegardless()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        model.start()
        NSApp.activate()
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Settings.shared.onboarded = true
    }
}

/// What's allowed and running, checked every second while the guide is open.
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, accessibility, control, javascript, restart, screenshots, done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .accessibility: "Accessibility"
            case .control: "Browser Control"
            case .javascript: "JavaScript"
            case .restart: "Restart Browsers"
            case .screenshots: "Screenshots"
            case .done: "Ready"
            }
        }
    }

    enum Status { case done, partial, todo, optional, info }

    @Published var step: Step { didSet { UserDefaults.standard.set(step.rawValue, forKey: "setupStep") } }
    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var screenshots = Permissions.screenRecording
    /// Per bundle ID: may ANNOT control it. macOS only answers while the browser runs, so a browser not started since
    /// the guide opened isn't in here.
    @Published private(set) var control: [String: Bool] = [:]
    @Published private(set) var states: [String: BrowserState] = [:]
    /// Running browsers and when they started.
    @Published private(set) var launched: [String: Date] = [:]
    let browsers = Browser.installed
    /// When the guide first opened. Browsers started before that still run without the new settings.
    let since: Date
    /// What just got done (keys like "accessibility", "javascript:<bundle ID>") and the step on screen.
    var onProgress: ((Set<String>, Step) -> Void)?

    private var timer: Timer?
    private var ticks = 0
    private var finished: Set<String>?

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "setupStarted") == nil { d.set(Date(), forKey: "setupStarted") }
        since = d.object(forKey: "setupStarted") as? Date ?? Date()
        // Picks up where it was, e.g. after macOS reopened ANNOT for screenshots.
        step = Settings.shared.onboarded ? .welcome : Step(rawValue: d.integer(forKey: "setupStep")) ?? .welcome
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func status(_ s: Step) -> Status {
        switch s {
        case .welcome, .done: .info
        case .accessibility: accessibility ? .done : .todo
        case .control: count { control[$0.bundleID] == true }
        case .javascript: count { states[$0.bundleID] == .ok }
        case .restart: browsers.contains(where: needsRestart) ? .todo : .done
        case .screenshots: screenshots ? .done : .optional
        }
    }

    func needsRestart(_ b: Browser) -> Bool { launched[b.bundleID].map { $0 < since } ?? false }

    private func count(_ ok: (Browser) -> Bool) -> Status {
        let n = browsers.filter(ok).count
        return n == browsers.count ? .done : n > 0 ? .partial : .todo
    }

    private func refresh() {
        ticks += 1
        accessibility = Permissions.accessibility
        screenshots = Permissions.screenRecording
        states = BrowserBridge.shared.states
        launched = browsers.reduce(into: [:]) { out, b in
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleID)
            if !apps.isEmpty { out[b.bundleID] = apps.map { $0.launchDate ?? .distantPast }.min() }
        }
        let running = browsers.filter { launched[$0.bundleID] != nil }
        let probe = step == .javascript && ticks % 2 == 1
        DispatchQueue.global(qos: .utility).async {
            let answers = running.map { ($0, Permissions.automation($0, ask: false)) }
            DispatchQueue.main.async {
                for (b, allowed) in answers { self.control[b.bundleID] = allowed }
                // The live check while the user flips the switch in the browser: one Apple Event per browser, every 2 s.
                if probe {
                    for (b, allowed) in answers where allowed == true {
                        BrowserBridge.shared.check(b) {
                            self.states = BrowserBridge.shared.states
                            self.noticeProgress()
                        }
                    }
                }
                self.noticeProgress()
            }
        }
    }

    /// Calls `onProgress` with what got done since the last check (not with what was done when the guide opened).
    private func noticeProgress() {
        var now: Set<String> = []
        if accessibility { now.insert("accessibility") }
        if screenshots { now.insert("screenshots") }
        for b in browsers {
            if control[b.bundleID] == true { now.insert("control:" + b.bundleID) }
            if states[b.bundleID] == .ok { now.insert("javascript:" + b.bundleID) }
            if let started = launched[b.bundleID], started >= since { now.insert("restart:" + b.bundleID) }
        }
        let new = now.subtracting(finished ?? now)
        finished = now
        if !new.isEmpty { onProgress?(new, step) }
    }
}

extension Browser {
    /// Quits the browser the normal way (it may still ask, e.g. about a form) and opens it again once it's gone.
    func restart() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        Task { @MainActor in
            for _ in 0..<120 where apps.contains(where: { !$0.isTerminated }) { // 30 s, then it stays closed
                try? await Task.sleep(for: .milliseconds(250))
            }
            if apps.allSatisfy(\.isTerminated) { Permissions.open(self) }
        }
    }
}

// MARK: - Window

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var tickets = Tickets.shared
    let connectRome: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                page
                    .id(model.step)
                    .transition(.opacity.combined(with: .offset(x: 14)))
                    .padding(.horizontal, 32).padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea() // under the transparent title bar
    }

    // MARK: sidebar and buttons

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 0) {
                    Text("ANNOT").font(.system(size: 14, weight: .semibold))
                    Text("Setup").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6).padding(.bottom, 18)
            ForEach(SetupModel.Step.allCases, id: \.self, content: stepRow)
            Spacer()
            Text("Open this guide again any time: click ANNOT's bubble in the menu bar › Setup Guide…")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 12).padding(.top, 52).padding(.bottom, 18)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarMaterial())
    }

    private func stepRow(_ s: SetupModel.Step) -> some View {
        let current = s == model.step
        return Button { go(to: s) } label: {
            HStack(spacing: 9) {
                StepDot(step: s, status: model.status(s))
                Text(s.title).font(.system(size: 12.5, weight: current ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(current ? Color.accentColor.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.step != .welcome { Button("Back") { go(by: -1) } }
            Spacer()
            if model.step == .done {
                if tickets.account == nil { Button("Connect to Rome…", action: connectRome) }
                Button("Start Commenting", action: close).keyboardShortcut(.defaultAction)
            } else {
                switch model.status(model.step) {
                case .todo: Button("Skip for Now") { go(by: 1) }
                case .optional: Button("Skip") { go(by: 1) }
                default: Button(model.step == .welcome ? "Get Started" : "Continue") { go(by: 1) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .frame(height: 60)
    }

    private func go(by delta: Int) {
        if let s = SetupModel.Step(rawValue: model.step.rawValue + delta) { go(to: s) }
    }

    private func go(to s: SetupModel.Step) {
        withAnimation(.easeInOut(duration: 0.2)) { model.step = s }
    }

    /// The shortcut as keys to draw: double-tap ⌥, or the key combo split into modifiers and key.
    private var keys: [String] {
        if settings.doubleTapOption { return ["⌥"] }
        let label = settings.hotKey.label, mods = label.prefix { "⌃⌥⇧⌘".contains($0) }
        return mods.map(String.init) + [String(label.dropFirst(mods.count))].filter { !$0.isEmpty }
    }

    // MARK: pages

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome: welcome
        case .accessibility: accessibility
        case .control: control
        case .javascript: JavaScriptPage(model: model)
        case .restart: restart
        case .screenshots: screenshots
        case .done: ready
        }
    }

    private var welcome: some View {
        Page(title: "Comment on anything on your Mac",
             text: "\(settings.doubleTapOption ? "Double-tap ⌥" : "Press \(settings.hotKey.label)"), click what you mean, type. In Chrome, Arc and Safari the pins sit right on the page; anywhere else ANNOT remembers the app and the element.") {
            HeroArt(keys: keys, taps: settings.doubleTapOption)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("First, a few things to allow. It takes about two minutes:").font(.system(size: 13, weight: .medium))
                ForEach([("hand.raised", "Accessibility, to see what you click"),
                         ("globe", "Let ANNOT control your browsers"),
                         ("curlybraces", "Turn on JavaScript from Apple Events in each browser"),
                         ("arrow.clockwise", "Restart your browsers"),
                         ("camera.viewfinder", "Screenshots, if you want them")], id: \.1) { symbol, text in
                    HStack(spacing: 8) {
                        Image(systemName: symbol).foregroundStyle(Color.annotBlue).frame(width: 20)
                        Text(text)
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
    }

    private var accessibility: some View {
        Page(title: "Allow Accessibility",
             text: "So ANNOT can tell which button, text or field you click in other apps, and notice the double-tap on ⌥. It only watches for that double-tap; it doesn't log your typing.") {
            AccessibilityArt(granted: model.accessibility)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Instructions(["Click **Open System Settings**.",
                              "Turn on **ANNOT** in \(Loc.privacy) › \(Loc.accessibility).",
                              "Confirm with your password or Touch ID."])
                HStack {
                    StatusLine(model.accessibility ? .ok : .waiting, model.accessibility ? "Accessibility is on" : "Waiting for the switch…")
                    Spacer()
                    if !model.accessibility { Button("Open System Settings", action: Permissions.requestAccessibility) }
                }
            }
        }
    }

    private var control: some View {
        Page(title: "Let ANNOT control your browsers",
             text: "ANNOT talks to the open tab to show pins and to capture the element you click. macOS asks once per browser: click **\(Loc.t("Allow", "Erlauben"))**.") {
            AutomationArt(browser: model.browsers.first { model.control[$0.bundleID] != true } ?? model.browsers.first)
        } content: {
            VStack(spacing: 6) { ForEach(model.browsers, id: \.bundleID, content: controlRow) }
        }
    }

    private func controlRow(_ b: Browser) -> some View {
        let allowed = model.control[b.bundleID], running = model.launched[b.bundleID] != nil
        let detail = allowed == true ? "Allowed"
            : allowed == false ? "Turned off. Turn on \(b.name) under ANNOT in \(Loc.privacy) › Automation"
            : running ? "macOS asks once" : "Not running: opens it, then macOS asks"
        return BrowserRow(browser: b, done: allowed == true, detail: detail) {
            if allowed == false {
                Button("Open System Settings") { Permissions.openPane("Privacy_Automation") }
            } else {
                Button(running ? "Allow…" : "Open and Allow…") { Permissions.requestAutomation(b) }
            }
        }
    }

    private var restart: some View {
        Page(title: "Restart your browsers",
             text: "Quit each browser once and open it again, so every window and tab starts with ANNOT and the new settings.") {
            RestartArt(browsers: model.browsers)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.browsers, id: \.bundleID, content: restartRow)
                Text("Save what you're typing first. If tabs don't come back, the browser's History menu has them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func restartRow(_ b: Browser) -> some View {
        let detail = model.launched[b.bundleID] == nil ? "Not running. Starts fresh next time"
            : model.needsRestart(b) ? "Open since before the setup" : "Restarted"
        return BrowserRow(browser: b, done: !model.needsRestart(b), detail: detail) {
            Button("Quit and Reopen") { b.restart() }
        }
    }

    private var screenshots: some View {
        Page(title: "Screenshots (optional)",
             text: "Keep a cropped picture of what you commented on. macOS calls this “\(Loc.screenRecording)”; ANNOT records no audio. Don't need pictures? Skip it, you can turn it on later in Settings.") {
            ScreenshotArt()
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if !model.screenshots {
                    Instructions(["Click **Turn On Screenshots**.",
                                  "Turn on **ANNOT** in \(Loc.privacy) › \(Loc.screenRecording).",
                                  "Let macOS quit and reopen ANNOT. This guide continues here."])
                }
                HStack {
                    StatusLine(model.screenshots ? .ok : .idle, model.screenshots ? "On: each comment gets a screenshot" : "Off")
                    Spacer()
                    if !model.screenshots { Button("Turn On Screenshots", action: Permissions.requestScreenRecording) }
                }
            }
        }
    }

    private var ready: some View {
        let missing = self.missing
        return Page(title: missing.isEmpty ? "You're all set" : "Almost there",
                    text: "\(settings.doubleTapOption ? "Double-tap ⌥ (or press \(settings.hotKey.label))" : "Press \(settings.hotKey.label)") anywhere, click what you mean, and type. ANNOT lives in the menu bar: click its bubble for your comments, settings and this guide.") {
            ReadyArt(keys: keys, taps: settings.doubleTapOption)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(missing, id: \.text) { m in
                    HStack {
                        StatusLine(.warn, m.text)
                        Spacer()
                        Button("Show Me") { go(to: m.step) }
                    }
                }
            }
        }
    }

    /// What still keeps a part of ANNOT from working.
    private var missing: [(text: String, step: SetupModel.Step)] {
        var out: [(text: String, step: SetupModel.Step)] = []
        if !model.accessibility { out.append(("Accessibility is off: no double-tap ⌥, no comments outside the browser", .accessibility)) }
        if model.status(.javascript) == .todo {
            out.append(("No browser connected yet: no pins on web pages", model.status(.control) == .todo ? .control : .javascript))
        }
        let restart = model.browsers.filter(model.needsRestart).map(\.name)
        if !restart.isEmpty { out.append(("Restart \(restart.joined(separator: ", "))", .restart)) }
        return out
    }
}

/// Chrome, Arc and Safari each hide the switch somewhere else: one tab per browser, each with its own picture.
private struct JavaScriptPage: View {
    @ObservedObject var model: SetupModel
    @State private var pick: String?

    var body: some View {
        let b = selected
        Page(title: "Turn on JavaScript from Apple Events",
             text: "Browsers keep this off until you allow it; ANNOT needs it to put its pins on the page. Turn it on in each browser you use and skip the others.") {
            if let b {
                if b.dialect == .safari { SafariSettingsArt() } else { BrowserMenuArt(browser: b) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) { ForEach(model.browsers, id: \.bundleID, content: tab) }
                if let b {
                    Instructions(steps(b))
                    HStack {
                        let (kind, text) = status(b)
                        StatusLine(kind, text)
                        Spacer()
                        if model.states[b.bundleID] != .ok { Button("Open \(b.name)") { Permissions.open(b) } }
                    }
                }
            }
        }
    }

    /// The tab picked, else the first browser still to do.
    private var selected: Browser? {
        model.browsers.first { $0.bundleID == pick } ?? model.browsers.first { model.states[$0.bundleID] != .ok } ?? model.browsers.first
    }

    private func tab(_ b: Browser) -> some View {
        let on = model.states[b.bundleID] == .ok, current = b == selected
        return Button { pick = b.bundleID } label: {
            HStack(spacing: 6) {
                Image(nsImage: b.icon).resizable().frame(width: 18, height: 18)
                Text(b.name).font(.system(size: 12, weight: .medium))
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.green : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Capsule().fill(current ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(current ? Color.accentColor.opacity(0.6) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func steps(_ b: Browser) -> [String] {
        switch b.dialect {
        case .safari:
            return ["In Safari choose **Safari › \(Loc.t("Settings…", "Einstellungen …"))**, click **\(Loc.t("Advanced", "Erweitert"))** and turn on **\(Loc.t("Show features for web developers", "Funktionen für Web-Entwickler anzeigen"))**.",
                    "Click **\(Loc.t("Developer", "Entwickler"))** and turn on **\(Loc.t("Allow JavaScript from Apple Events", "JavaScript von Apple Events erlauben"))**."]
        case .chromium:
            let m = b.jsMenu
            return ["In \(b.menuName)'s menu bar choose **\(m.view) › \(m.developer) › \(m.item)**."]
                + (b.bundleID == "com.google.Chrome" ? ["More than one Chrome profile? Turn it on in each of them."] : [])
        }
    }

    private func status(_ b: Browser) -> (StatusLine.Kind, String) {
        if model.states[b.bundleID] == .ok { return (.ok, "On: ANNOT reaches the pages in \(b.name)") }
        if model.launched[b.bundleID] == nil { return (.idle, "Open \(b.name) to check") }
        if model.control[b.bundleID] != true { return (.warn, "First let ANNOT control \(b.name) (previous step)") }
        switch model.states[b.bundleID] ?? .unknown {
        case .jsDisabled: return (.waiting, "Still off. Waiting for the switch…")
        case .noPage: return (.idle, "Open a web page in \(b.name) to check")
        case .denied: return (.warn, "Not allowed to control \(b.name) (previous step)")
        case .ok, .unknown: return (.waiting, "Checking…")
        }
    }
}

// MARK: - Pieces

private struct Page<Art: View, Content: View>: View {
    let title: String
    let text: String
    @ViewBuilder let art: Art
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 210)
                .background(LinearGradient(colors: [Color.annotBlue.opacity(0.16), Color.annotAgent.opacity(0.07)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 22, weight: .bold)).padding(.top, 20)
            Text(markdown: text).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            content.padding(.top, 16)
        }
    }
}

private struct Instructions: View {
    let steps: [String]
    init(_ steps: [String]) { self.steps = steps }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(steps.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(i + 1)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Circle().fill(Color.annotBlue))
                    Text(markdown: steps[i]).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(.top, 1)
                }
            }
        }
    }
}

private struct StatusLine: View {
    enum Kind { case ok, waiting, warn, idle }
    let kind: Kind
    let text: String
    init(_ kind: Kind, _ text: String) { (self.kind, self.text) = (kind, text) }

    var body: some View {
        HStack(spacing: 7) {
            switch kind {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .waiting: ProgressView().controlSize(.small).frame(width: 16, height: 16)
            case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .idle: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(kind == .ok ? .primary : .secondary)
        }
        .font(.system(size: 15))
    }
}

private struct BrowserRow<Action: View>: View {
    let browser: Browser
    let done: Bool
    let detail: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: browser.icon).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.name).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green) } else { action }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

private struct StepDot: View {
    let step: SetupModel.Step
    let status: SetupModel.Status

    var body: some View {
        Group {
            switch status {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .partial: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
            case .info: Image(systemName: step == .welcome ? "hand.wave.fill" : "flag.checkered").foregroundStyle(Color.annotBlue)
            case .todo, .optional:
                Text("\(step.rawValue)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.7),
                                                   style: StrokeStyle(lineWidth: 1.2, dash: status == .optional ? [2, 2] : [])))
            }
        }
        .font(.system(size: 15))
        .frame(width: 18, height: 18)
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
