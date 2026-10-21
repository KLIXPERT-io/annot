import AppKit
import ApplicationServices
import SwiftUI

/// What the user pointed at in a non-browser app (APP-3).
struct AXTarget {
    var bundleID = "", appName = "", windowTitle = "", role = "", title = "", value = "", path = ""
    var url = "" // when the element is inside a web page (browser fallback)
    var frame: CGRect = .zero // global, top-left origin

    var summary: String {
        let what = [AXNames.role(role), title.isEmpty ? "" : "“\(title)”"].filter { !$0.isEmpty }.joined(separator: " ")
        return [appName, windowTitle, what].filter { !$0.isEmpty }.joined(separator: " › ")
    }
}

enum AXProbe {
    private static var primed = Set<pid_t>()
    /// Global AX timeout (default 6 s per call): a hung or busy app must not stall comment mode.
    private static let timeout: Void = { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3) }()

    /// Element under a global point, from the topmost window that isn't ours. Works without
    /// Accessibility too — then it falls back to the window itself.
    static func target(at p: CGPoint) -> AXTarget? {
        _ = timeout
        guard let win = windowUnder(p), let app = NSRunningApplication(processIdentifier: win.pid) else { return nil }
        var t = AXTarget(bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "", windowTitle: win.title,
                         role: "AXWindow", frame: win.frame)
        let appEl = AXUIElementCreateApplication(win.pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        if !primed.contains(win.pid) { // Electron/Chromium apps only expose their AX tree on request
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            primed.insert(win.pid)
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appEl, Float(p.x), Float(p.y), &hit) == .success, let el = hit else { return t }
        t.role = string(el, kAXRoleAttribute)
        t.title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].lazy.map { string(el, $0) }.first { !$0.isEmpty } ?? ""
        if let v = attr(el, kAXValueAttribute) { t.value = String(String(describing: v).prefix(200)) }
        if let f = frame(el), f.width > 0, f.height > 0 { t.frame = f }
        if let w = attr(el, kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            let title = string(w as! AXUIElement, kAXTitleAttribute)
            if !title.isEmpty { t.windowTitle = title }
        }
        (t.path, t.url) = path(el)
        return t
    }

    static func windowUnder(_ p: CGPoint) -> (pid: pid_t, title: String, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = getpid()
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
            return (pid, w[kCGWindowName as String] as? String ?? "", r)
        }
        return nil
    }

    /// Roles and titles from the element up to its window, plus the URL of the web page it sits in, if any.
    private static func path(_ el: AXUIElement) -> (path: String, url: String) {
        var parts: [String] = []
        var url = ""
        var cur: AXUIElement? = el
        while let c = cur, parts.count < 12 {
            let role = string(c, kAXRoleAttribute)
            let title = string(c, kAXTitleAttribute)
            if url.isEmpty, role == "AXWebArea", let u = attr(c, kAXURLAttribute) as? NSURL { url = u.absoluteString ?? "" }
            parts.insert(title.isEmpty ? role : "\(role)[\"\(title.prefix(30))\"]", at: 0)
            if role == "AXWindow" || role == "AXApplication" { break }
            guard let parent = attr(c, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            cur = (parent as! AXUIElement)
        }
        return (parts.joined(separator: " > "), url)
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String { attr(el, name) as? String ?? "" }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}

/// Accessibility roles in plain words:
/// `AXWindow["Mail"] > AXSplitGroup > AXGroup > AXButton["Send"]` → `Window “Mail” › Button “Send”`.
enum AXNames {
    private static let names = ["AXWebArea": "Web page", "AXStaticText": "Text", "AXCheckBox": "Checkbox",
                                "AXSplitGroup": "Split view", "AXTabGroup": "Tabs", "AXPopUpButton": "Pop-up button"]
    /// Untitled layout containers say nothing about what was clicked.
    private static let filler: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXSplitter", "AXList", "AXUnknown"]

    /// `AXMenuBarItem` → `Menu bar item`
    static func role(_ r: String) -> String {
        if let n = names[r] { return n }
        var out = ""
        for ch in r.hasPrefix("AX") ? r.dropFirst(2) : Substring(r) {
            if ch.isUppercase, !out.isEmpty { out += " " + ch.lowercased() } else { out.append(ch) }
        }
        return out
    }

    static func path(_ raw: String) -> String {
        let parts = raw.components(separatedBy: " > ")
        return parts.enumerated().compactMap { i, part -> String? in
            var r = part, title = ""
            if let open = part.range(of: "[\""), part.hasSuffix("\"]"), open.upperBound <= part.index(part.endIndex, offsetBy: -2) {
                r = String(part[..<open.lowerBound])
                title = String(part[open.upperBound..<part.index(part.endIndex, offsetBy: -2)])
            }
            if title.isEmpty, filler.contains(r), i < parts.count - 1 { return nil }
            return title.isEmpty ? role(r) : "\(role(r)) “\(title)”"
        }.joined(separator: " › ")
    }
}

/// Comment mode outside Chrome: a transparent panel per screen, highlight the element under the
/// mouse, click to drop a pin and type. Non-activating panels, so the app you point at keeps focus.
final class NativeCapture {
    var onFinish: (() -> Void)?
    private var panels: [CapturePanel] = []
    private var keyMonitors: [Any] = []
    private let axQueue = DispatchQueue(label: "io.klixpert.annot.ax", qos: .userInteractive)
    private var probing = false, probeAgain = false
    private var clicking = false // hit test for a click in flight
    private var target: AXTarget?
    private var click = CGPoint.zero
    private var composer: NSView?

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static var mouse: CGPoint { let m = NSEvent.mouseLocation; return CGPoint(x: m.x, y: primaryHeight - m.y) }
    static func cocoa(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }

    func start() {
        for screen in NSScreen.screens {
            let p = CapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.setFrame(screen.frame, display: false)
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = NSColor(white: 0, alpha: 0.001)
            p.hasShadow = false
            p.ignoresMouseEvents = false
            p.acceptsMouseMovedEvents = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = CaptureView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.capture = self
            p.contentView = v
            p.orderFrontRegardless()
            panels.append(p)
        }
        (panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first)?.makeKey()
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(); return nil } // Esc
            return e
        }
        // Esc also when another app took the keyboard (⌘-Tab); needs Accessibility, like the hit test.
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish() }
        }
        keyMonitors = [local, global].compactMap { $0 }
        mouseMoved(in: nil)
    }

    /// Safe to call any number of times.
    func finish() {
        guard !panels.isEmpty else { return }
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors.removeAll()
        composer = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        onFinish?()
    }

    deinit { // never leave a screen-covering panel behind
        keyMonitors.forEach(NSEvent.removeMonitor)
        panels.forEach { $0.orderOut(nil) }
    }

    func mouseMoved(in view: CaptureView?) {
        NSCursor.crosshair.set()
        guard composer == nil, !clicking else { return }
        if let w = view?.window, !w.isKeyWindow { w.makeKey() } // win Esc back after ⌘-Tab
        probe()
    }

    /// Hit-test off the main thread; coalesce while one is in flight.
    private func probe() {
        if probing { probeAgain = true; return }
        probing = true
        let p = Self.mouse
        axQueue.async {
            let t = AXProbe.target(at: p)
            DispatchQueue.main.async {
                self.probing = false
                guard self.composer == nil, !self.clicking, !self.panels.isEmpty else { return }
                self.target = t
                self.highlight(t)
                if self.probeAgain { self.probeAgain = false; self.probe() }
            }
        }
    }

    private func highlight(_ t: AXTarget?) {
        for p in panels {
            guard let v = p.contentView as? CaptureView else { continue }
            v.setHighlight(t.map { p.convertFromScreen(Self.cocoa($0.frame)) }, label: t?.summary ?? "")
        }
    }

    /// Hit test off the main thread (a slow app must not freeze the screen-covering panels), then open the composer.
    func mouseDown(in view: CaptureView) {
        guard !clicking else { return }
        composer?.removeFromSuperview()
        composer = nil
        let click = Self.mouse
        self.click = click
        clicking = true
        axQueue.async {
            let t = AXProbe.target(at: click)
                ?? AXTarget(appName: "Desktop", role: "AXDesktop", frame: CGRect(x: click.x - 1, y: click.y - 1, width: 2, height: 2))
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.clicking = false
                guard let view, !self.panels.isEmpty else { return }
                self.target = t
                self.highlight(t)
                self.openComposer(for: t, in: view)
            }
        }
    }

    private func openComposer(for t: AXTarget, in view: CaptureView) {
        let pad: CGFloat = 24, size = CGSize(width: 360 + pad * 2, height: 380 + pad * 2) // room for the @ list
        let pick = Tickets.choices.pick(for: ProjectChoices.place(url: t.url, bundleID: t.bundleID))
        let host = FirstClickHostingView(rootView: NativeComposer(author: Settings.authorName, context: t.summary, projects: Tickets.choices.all,
                                                                  project: pick.project, why: pick.why,
                                                                  onSubmit: { [weak self] in self?.submit($0, annotate: $1, project: $2) }))
        guard let window = view.window else { return }
        let local = window.convertFromScreen(CGRect(origin: CGPoint(x: click.x, y: Self.primaryHeight - click.y), size: .zero)).origin
        var origin = CGPoint(x: local.x - pad, y: local.y + 32 + pad - size.height) // pin's bottom-left corner on the click
        origin.x = min(max(origin.x, 0), view.bounds.width - size.width)
        origin.y = min(max(origin.y, 0), view.bounds.height - size.height)
        host.frame = CGRect(origin: origin, size: size)
        view.addSubview(host)
        composer = host
        window.makeKey()
    }

    private func submit(_ text: String, annotate: Bool, project: String?) {
        guard let t = target else { return }
        let click = self.click
        finish()
        var anchor: [String: Any] = [
            "kind": "native", "bundle_id": t.bundleID, "app_name": t.appName, "window_title": t.windowTitle,
            "ax_role": t.role, "ax_title": t.title, "ax_value": t.value, "ax_path": t.path,
            "point": ["x": click.x, "y": click.y],
            "frame": ["x": t.frame.minX, "y": t.frame.minY, "w": t.frame.width, "h": t.frame.height],
        ]
        if !t.url.isEmpty { anchor["url"] = t.url }
        let comment = CommentStore.shared.create(text: text, anchor: anchor)
        if !Tickets.choices.all.isEmpty { Settings.chooseProject(project, at: ProjectChoices.place(url: t.url, bundleID: t.bundleID)) }
        HUD.show(project.map { "Comment saved · \($0) Triage" } ?? "Comment saved")
        Task.detached {
            if let png = await Screenshot.region(around: t.frame, click: click) {
                CommentStore.shared.attachScreenshot(png, to: comment.id)
            }
            Tickets.autoSend(comment.id, to: project)
            if annotate { await Annotator.showAfterCapture(comment.id) }
        }
    }
}

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class CaptureView: NSView {
    weak var capture: NativeCapture?
    private let box = NSView()
    private let tagLabel = NSTextField(labelWithString: "")
    private let tagBG = NSView()
    private var hint: NSView?
    private let blue = NSColor(srgbRed: 13 / 255, green: 153 / 255, blue: 1, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.wantsLayer = true
        box.layer?.borderColor = blue.cgColor
        box.layer?.borderWidth = 1.5
        box.layer?.cornerRadius = 3
        box.layer?.backgroundColor = blue.withAlphaComponent(0.07).cgColor
        box.isHidden = true
        tagBG.wantsLayer = true
        tagBG.layer?.backgroundColor = blue.cgColor
        tagBG.layer?.cornerRadius = 4
        tagBG.isHidden = true
        tagLabel.font = .systemFont(ofSize: 11, weight: .medium)
        tagLabel.textColor = .white
        tagLabel.lineBreakMode = .byTruncatingMiddle
        tagBG.addSubview(tagLabel)
        addSubview(box)
        addSubview(tagBG)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        setHint("Click anything to comment")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { capture?.mouseMoved(in: self) }
    override func mouseDown(with event: NSEvent) { capture?.mouseDown(in: self) }
    override func rightMouseDown(with event: NSEvent) { capture?.finish() }

    func setHighlight(_ rect: CGRect?, label: String) {
        guard let rect, rect.intersects(bounds) else { box.isHidden = true; tagBG.isHidden = true; return }
        box.frame = rect
        box.isHidden = false
        tagLabel.stringValue = label
        tagLabel.sizeToFit()
        let w = min(tagLabel.frame.width, 420)
        tagLabel.frame = CGRect(x: 6, y: 1, width: w, height: 16)
        var o = CGPoint(x: rect.minX - 1, y: rect.maxY + 4)
        if o.y + 18 > bounds.maxY { o.y = rect.maxY - 22 }
        tagBG.frame = CGRect(origin: o, size: CGSize(width: w + 12, height: 18))
        tagBG.isHidden = label.isEmpty
    }

    func setHint(_ text: String?) {
        hint?.removeFromSuperview()
        hint = nil
        guard let text else { return }
        let v = FirstClickHostingView(rootView: HintPill(text: text) { [weak self] in self?.capture?.finish() })
        let s = v.fittingSize
        v.frame = CGRect(x: (bounds.width - s.width) / 2, y: 40, width: s.width, height: s.height)
        addSubview(v)
        hint = v
    }
}

/// Takes the first click even while another app is active, so Cancel always works.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct HintPill: View {
    let text: String
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left")
            Text(text)
            Button(action: cancel) {
                Text("Cancel  esc").font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.16)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Leave comment mode (Esc or right-click)")
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Color(white: 0.12)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(16)
    }
}

/// Pin + comment card, Figma style.
struct NativeComposer: View {
    let author: String
    let context: String
    let projects: [Tickets.Project] // empty: not connected, no picker
    @State var project: String? // nil keeps the comment on this Mac
    @State var why: String? // why it's this project ("last used in this app"); nil for the default or once changed
    let onSubmit: (String, Bool, String?) -> Void // text, draw on the screenshot, project
    @State private var text = ""
    @State private var mention = MentionState()
    @FocusState private var focused: Bool

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PinBubble(name: author)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Avatar(name: author)
                    TextField("Add a comment", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit { mention.people.isEmpty ? send() : complete(mention.people[mention.selected]) }
                        .mentionKeys($mention, text: text, pick: complete)
                        .onChange(of: text) { mention.update(text, from: Tickets.choices.people(in: project)) }
                        .padding(.top, 4)
                    Button { send(annotate: true) } label: {
                        Image(systemName: "pencil.tip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(canSend ? Color(white: 0.3) : Color(white: 0.72))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Post and draw on the screenshot  ⌘↩")
                    .keyboardShortcut(.return, modifiers: .command)
                    Button { send() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : Color(white: 0.72))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(canSend ? Color.annotBlue : Color(white: 0.94)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                if !mention.people.isEmpty {
                    Divider()
                    MentionList(people: mention.people, selected: mention.selected, pick: complete)
                }
                if !context.isEmpty {
                    Divider()
                    Label(context, systemImage: "scope")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                }
                if !projects.isEmpty {
                    Divider()
                    HStack(spacing: 6) {
                        Text("Send to").foregroundStyle(.secondary)
                        Menu {
                            Button("Keep on this Mac") { project = nil; why = nil }
                            Divider()
                            ForEach(projects) { p in Button("\(p.name) (\(p.key))") { project = p.key; why = nil } }
                        } label: {
                            Text(projects.first { $0.key == project }.map { "\($0.name) (\($0.key))" } ?? "Keep on this Mac")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        if let why { Text(why).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail) }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .light)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func send(annotate: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onSubmit(t, annotate, project) }
    }

    private func complete(_ p: Tickets.Person) {
        text = Mentions.complete(text, with: p)
        focused = true
    }
}
