import AppKit
import os

/// `log stream --predicate 'subsystem == "io.klixpert.annot"'` shows what the bridge does.
let bridgeLog = Logger(subsystem: "io.klixpert.annot", category: "bridge")

enum BrowserState { case unknown, ok, jsDisabled, denied, noPage }

/// A browser we can run JavaScript in through AppleScript.
struct Browser: Equatable {
    /// Chromium: `execute <tab> javascript …`, runs in an isolated world the page can't see.
    /// Safari: `do JavaScript … in <tab>`, runs in the page's own world.
    enum Dialect { case chromium, safari }

    let name: String
    let bundleID: String
    var dialect = Dialect.chromium
    /// Where the user turns on JavaScript from Apple Events.
    var jsSetting = "Allow JavaScript from Apple Events"

    static let all = [
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome",
                jsSetting: "View › Developer › Allow JavaScript from Apple Events"),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser"),
        Browser(name: "Safari", bundleID: "com.apple.Safari", dialect: .safari,
                jsSetting: "Settings › Developer › Allow JavaScript from Apple Events (first: Advanced › Show features for web developers)"),
    ]

    static var front: Browser? { with(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    static func with(_ bundleID: String?) -> Browser? { all.first { $0.bundleID == bundleID } }
    static var installed: [Browser] { all.filter(\.isInstalled) }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

/// Talks to the active tab of the frontmost supported browser through AppleScript — no extension needed.
/// All Apple Events run on one serial background queue (PERF-1); nothing happens while no supported
/// browser is frontmost (BR-5); polling is fast only while the overlay is busy (BR-6, PERF-6).
final class BrowserBridge: @unchecked Sendable {
    static let shared = BrowserBridge()

    /// Last known state per browser bundle ID, for the menu and settings (main thread).
    private(set) var states: [String: BrowserState] = [:]

    private let queue = DispatchQueue(label: "io.klixpert.annot.browser-bridge", qos: .userInitiated)
    private var gen = 0
    private var lastURL: String?
    private var lastBrowser: String?
    private var pageKey: String?
    private var refreshFailed = false // the last setComments didn't come back "ok": send it again on the next poll
    private lazy var overlaySource = Self.loadOverlay()
    private var drainScripts: [String: NSAppleScript] = [:]
    private var lastError = "" // last AppleScript error, for the log when capture can't start

    private static let drainJS =
        "window.__annot ? JSON.stringify({e: window.__annot.drain(), busy: window.__annot.busy(), url: location.href, synced: window.__annot.synced ? window.__annot.synced() : true}) : 'missing'"

    // MARK: lifecycle

    func start() { queue.async { self.schedule(0.5) } }

    /// Poll soon, e.g. right after a browser became frontmost.
    func kick() { queue.async { self.schedule(0.05) } }

    private func schedule(_ delay: TimeInterval) {
        gen &+= 1
        let g = gen
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, g == self.gen else { return }
            self.schedule(self.tick())
        }
    }

    /// One poll = one Apple Event. Returns the delay until the next poll.
    private func tick() -> TimeInterval {
        guard let browser = Browser.front else {
            lastURL = nil // refetch when a browser comes back; comments may have changed meanwhile
            return 1.0
        }
        guard let res = execute(drainScript(for: browser), in: browser) else { return 2.0 }
        if res == "missing" {
            return run(overlaySource, in: browser) != nil ? 0.05 : 2.0 // BR-1; drain the `ready` event right away
        }
        guard let data = res.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 2.0 }
        let url = obj["url"] as? String ?? ""
        let events = obj["e"] as? [[String: Any]] ?? []
        // A tab or browser switch, a new page, or comments that never reached the overlay: Arc times out right after
        // a navigation, and a script it timed out on may still run there with its result lost (a `ready`, a setComments).
        let stale = url != lastURL || browser.bundleID != lastBrowser || obj["synced"] as? Bool == false || refreshFailed
        lastURL = url
        lastBrowser = browser.bundleID
        for e in events { handle(e, from: browser) } // BR-2
        if stale { refresh(url, in: browser) }
        return (obj["busy"] as? Bool ?? false) ? 0.3 : 2.0
    }

    private func drainScript(for browser: Browser) -> NSAppleScript? {
        if let s = drainScripts[browser.bundleID] { return s }
        let s = NSAppleScript(source: Self.wrap(Self.drainJS, for: browser))
        var err: NSDictionary?
        s?.compileAndReturnError(&err)
        drainScripts[browser.bundleID] = s
        return s
    }

    // MARK: overlay events → local store

    private func handle(_ e: [String: Any], from browser: Browser) {
        guard let type = e["type"] as? String else { return }
        let store = CommentStore.shared
        switch type {
        case "comment.create":
            create(e, from: browser)
        case "comment.reply":
            guard let id = e["id"] as? String, let text = e["text"] as? String else { return }
            store.reply(id, text: text)
        case "comment.resolve":
            guard let id = e["id"] as? String else { return }
            store.setStatus(id, e["status"] as? String ?? "resolved")
        default: // ready, navigate (BR-3: the overlay isn't synced for the new page, tick refreshes it), capture.cancel
            break
        }
        // Store changes come back through commentsChanged(pageKey:) and refresh the tab.
    }

    private func create(_ e: [String: Any], from browser: Browser) {
        guard let text = e["text"] as? String, var anchor = e["anchor"] as? [String: Any] else { return }
        anchor["browser"] = browser.bundleID
        let comment = CommentStore.shared.create(text: text, title: e["title"] as? String ?? "", anchor: anchor, tempId: e["tempId"] as? String)
        // The comment box's pick (null: keep local); no picker shown means the default.
        let project = e.keys.contains("project") ? e["project"] as? String : Settings.ticketsProjectKey
        if e.keys.contains("project") { Settings.chooseProject(project, at: ProjectChoices.place(url: anchor["url"] as? String)) }
        // Viewport origin on screen = mouse position on screen − position in the viewport (from the click).
        guard let screen = e["screen"] as? [String: Any], let client = e["client"] as? [String: Any] else {
            Tickets.autoSend(comment.id, to: project)
            return
        }
        let rect = e["rect"] as? [String: Any] ?? [:], click = e["click"] as? [String: Any] ?? [:], vp = e["vp"] as? [String: Any] ?? [:]
        let dpr = e["dpr"].map { num($0) } ?? 2
        let mouse = CGPoint(x: num(screen["x"]), y: num(screen["y"]))
        let inViewport = CGPoint(x: num(client["x"]), y: num(client["y"]))
        let element = CGRect(x: num(rect["x"]), y: num(rect["y"]), width: num(rect["w"]), height: num(rect["h"]))
        let point = CGPoint(x: num(click["x"]), y: num(click["y"]))
        let viewport = CGSize(width: num(vp["w"]), height: num(vp["h"]))
        let annotate = e["annotate"] as? Bool ?? false
        Task {
            if let png = await Screenshot.web(mouse: mouse, mouseInViewport: inViewport, element: element, click: point, viewport: viewport, dpr: dpr) {
                CommentStore.shared.attachScreenshot(png, to: comment.id)
            }
            Tickets.autoSend(comment.id, to: project)
            if annotate { await Annotator.showAfterCapture(comment.id) }
        }
    }

    /// Hands the stored comments for `url` to the overlay. Runs on the bridge queue.
    private func refresh(_ url: String, in browser: Browser) {
        pageKey = CommentStore.pageKey(url)
        let list = CommentStore.shared.comments(forURL: url).map(\.dict)
        guard let listJSON = Self.json(list), let urlJSON = Self.json(url),
              let opts = Self.json(["author": Settings.authorName]) else { return }
        let r = run("window.__annot ? window.__annot.setComments(\(listJSON), \(urlJSON), \(opts)) : 'missing'", in: browser)
        refreshFailed = r != "ok"
        if refreshFailed { bridgeLog.notice("comments for \(url, privacy: .public) not delivered: \(r ?? self.lastError, privacy: .public)") }
    }

    /// A comment changed in the store (from the page, a native capture or the Comments window).
    func commentsChanged(pageKey key: String) {
        queue.async {
            guard key == self.pageKey else { return }
            if let browser = Browser.front, browser.bundleID == self.lastBrowser, let url = self.lastURL {
                self.refresh(url, in: browser)
            } else {
                self.lastURL = nil
            }
        }
    }

    // MARK: capture

    /// Starts (or toggles off) web capture in the browser's active tab (APP-2). `done(false)` means we can't reach the page.
    func startCapture(in browser: Browser, _ done: @escaping (Bool) -> Void) {
        queue.async {
            // The page's address first: which project the comment box offers depends on the site.
            var r = self.run("location.href", in: browser)
            if let href = r {
                var o = Tickets.choices.overlayOptions(for: ProjectChoices.place(url: href))
                o["author"] = Settings.authorName
                let opts = Self.json(o) ?? "{}"
                let js = "window.__annot ? window.__annot.startCapture(\(opts)) : 'missing'"
                r = self.run(js, in: browser)
                if r == "missing" {
                    let injected = self.run(self.overlaySource, in: browser)
                    bridgeLog.notice("overlay injected for capture: \(injected ?? "nil", privacy: .public)")
                    if injected != nil { r = self.run(js, in: browser) }
                }
            }
            let ok = r == "ok" || r == "stopped"
            if ok { self.schedule(0.3) }
            bridgeLog.notice("capture in \(browser.name, privacy: .public): \(r ?? "nil", privacy: .public) \(ok ? "" : self.lastError, privacy: .public)")
            DispatchQueue.main.async { done(ok) }
        }
    }

    func stopCapture(in browser: Browser) {
        queue.async { _ = self.run("window.__annot ? window.__annot.stopCapture() : 'missing'", in: browser) }
    }

    /// One tiny script in a running browser, even in the background: the setup guide's live check while the user
    /// turns on JavaScript from Apple Events. Updates `states` like a poll does; `done` runs after that (main thread).
    /// Only for browsers already allowed (Automation), or macOS would ask from here.
    func check(_ browser: Browser, _ done: @escaping () -> Void = {}) {
        queue.async {
            if browser.isRunning { _ = self.execute(NSAppleScript(source: Self.wrap("'ok'", for: browser)), in: browser, inBackground: true) }
            DispatchQueue.main.async(execute: done) // after setState's update, which is queued first
        }
    }

    // MARK: AppleScript plumbing

    private func run(_ js: String, in browser: Browser) -> String? {
        execute(NSAppleScript(source: Self.wrap(js, for: browser)), in: browser)
    }

    private func execute(_ script: NSAppleScript?, in browser: Browser, inBackground: Bool = false) -> String? {
        guard inBackground || Browser.front == browser, let script else { return nil } // BR-5
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            let msg = err[NSAppleScript.errorMessage] as? String ?? ""
            lastError = "\(code) \(msg)"
            if code == -1743 { setState(.denied, browser) }
            else if msg.localizedCaseInsensitiveContains("JavaScript") { setState(.jsDisabled, browser) }
            else { setState(.noPage, browser) }
            return nil
        }
        guard var s = out.stringValue, s != "nowindow" else { lastError = "no window"; setState(.noPage, browser); return nil }
        // Arc returns JavaScript results JSON-encoded (`"ok"` with the quotes); Chrome and Safari return the plain string.
        if s.hasPrefix("\""), let v = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed) as? String { s = v }
        setState(.ok, browser)
        return s
    }

    private func setState(_ s: BrowserState, _ browser: Browser) {
        let error = s == .ok ? "" : lastError
        DispatchQueue.main.async {
            if self.states[browser.bundleID] != s { bridgeLog.notice("\(browser.name, privacy: .public) is now \("\(s)", privacy: .public) \(error, privacy: .public)") }
            self.states[browser.bundleID] = s
        }
    }

    /// At most 8 s per script instead of AppleScript's 2 minutes: a busy browser (Arc times out now and then) would
    /// otherwise hold up the queue, and with it every Add Comment, that long.
    static func wrap(_ js: String, for browser: Browser) -> String {
        let command = switch browser.dialect {
        case .chromium: "execute active tab of window 1 javascript \(literal(js))"
        case .safari: "do JavaScript \(literal(js)) in current tab of window 1"
        }
        return """
        with timeout of 8 seconds
            tell application id "\(browser.bundleID)"
                if (count of windows) is 0 then return "nowindow"
                return \(command)
            end tell
        end timeout
        """
    }

    /// AppleScript string literal for arbitrary JS source (BR-4).
    static func literal(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 64)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    static func json(_ v: Any) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func num(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }

    static func loadOverlay() -> String {
        if let url = Bundle.main.url(forResource: "overlay", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        // `swift run` during development: read it from the repo
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/overlay.js").standardized
        return (try? String(contentsOf: dev, encoding: .utf8)) ?? "'overlay.js not found'"
    }
}
