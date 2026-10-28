import AppKit
import SwiftUI

/// Screenshot to the clipboard: the screens freeze, drag over an area or click a window, draw on it, say what it
/// shows, copy. Nothing is saved. The screens are captured first, so open menus and hover states stay as they were.
final class SnipCapture {
    var onFinish: (() -> Void)?
    /// Windows front to back when the screens froze, global and top-left origin: a click takes one.
    private(set) var windows: [(frame: CGRect, name: String)] = []
    private var panels: [CapturePanel] = []
    private var keyMonitors: [Any] = []
    private var done = false
    /// Where to go back after copying, so ⌘V works right away.
    private let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }

    func start() {
        windows = Self.windowList()
        Task { @MainActor in
            let shots = await Screenshot.displays()
            guard !done else { return } // cancelled while capturing
            guard !shots.isEmpty else {
                HUD.show("Couldn't capture the screen", isError: true)
                finish()
                return
            }
            show(shots)
        }
    }

    /// Safe to call any number of times.
    func finish() {
        guard !done else { return }
        done = true
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors.removeAll()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        onFinish?()
    }

    deinit { // never leave a screen-covering panel behind
        keyMonitors.forEach(NSEvent.removeMonitor)
        panels.forEach { $0.orderOut(nil) }
    }

    /// `area` (global, top-left origin) out of the frozen `shot` of `display`, into the editor.
    func take(_ area: CGRect, of shot: CGImage, display: CGRect) {
        let scale = CGFloat(shot.width) / display.width
        let r = area.offsetBy(dx: -display.minX, dy: -display.minY)
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
        finish()
        guard let crop = shot.cropping(to: px) else { return }
        let previous = previous
        MainActor.assumeIsolated { SnipEditor.show(crop, scale: scale, returnTo: previous) } // called from the view's mouseUp
    }

    private func show(_ shots: [(id: CGDirectDisplayID, frame: CGRect, image: CGImage)]) {
        for shot in shots {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == shot.id
            }) else { continue }
            let p = CapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.setFrame(screen.frame, display: false)
            p.level = .screenSaver
            p.hasShadow = false
            p.acceptsMouseMovedEvents = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = SnipView(frame: CGRect(origin: .zero, size: screen.frame.size), shot: shot.image, display: shot.frame)
            v.capture = self
            p.contentView = v
            p.orderFrontRegardless()
            panels.append(p)
        }
        guard !panels.isEmpty else { finish(); return }
        let under = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels[0]
        under.makeKey()
        (under.contentView as? SnipView)?.hover()
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(); return nil } // Esc
            return e
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish() }
        }
        keyMonitors = [local, global].compactMap { $0 }
    }

    private static func windowList() -> [(frame: CGRect, name: String)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.width >= 40, r.height >= 40 else { return nil }
            return (r, w[kCGWindowOwnerName as String] as? String ?? "Window")
        }
    }
}

/// One frozen screen, dimmed except for what a click or the drag would take.
final class SnipView: NSView {
    weak var capture: SnipCapture?
    private let shot: CGImage
    private let display: CGRect // global, top-left origin
    private let overlay = NSView()
    private let shade = CAShapeLayer(), outline = CAShapeLayer()
    private let tagLabel = NSTextField(labelWithString: "")
    private let tagBG = NSView()
    private var hint: NSView?
    private var area: CGRect? // global, top-left origin
    private var start: CGPoint?
    private var dragging = false
    private let blue = NSColor(srgbRed: 13 / 255, green: 153 / 255, blue: 1, alpha: 1)

    init(frame: NSRect, shot: CGImage, display: CGRect) {
        self.shot = shot
        self.display = display
        super.init(frame: frame)
        wantsLayer = true
        overlay.frame = bounds
        overlay.layer = CALayer() // layer-hosting: the shapes are ours
        overlay.wantsLayer = true
        shade.frame = bounds
        shade.fillRule = .evenOdd
        shade.fillColor = NSColor(white: 0, alpha: 0.3).cgColor
        outline.frame = bounds
        outline.fillColor = nil
        outline.strokeColor = blue.cgColor
        outline.lineWidth = 2
        overlay.layer?.addSublayer(shade)
        overlay.layer?.addSublayer(outline)
        addSubview(overlay)
        tagBG.wantsLayer = true
        tagBG.layer?.backgroundColor = blue.cgColor
        tagBG.layer?.cornerRadius = 4
        tagLabel.font = .systemFont(ofSize: 11, weight: .medium)
        tagLabel.textColor = .white
        tagLabel.lineBreakMode = .byTruncatingTail
        tagBG.addSubview(tagLabel)
        addSubview(tagBG)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
        let v = FirstClickHostingView(rootView: HintPill(text: "Drag over an area, or click a window", icon: "camera.viewfinder") { [weak self] in
            self?.capture?.finish()
        })
        let s = v.fittingSize
        v.frame = CGRect(x: (bounds.width - s.width) / 2, y: 40, width: s.width, height: s.height)
        addSubview(v)
        hint = v
        update(label: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = shot }

    /// The shade and the tag are drawing only; the hint's Cancel takes its own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === overlay || v === tagBG || v === tagLabel ? self : v
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { hover() }
    override func mouseEntered(with event: NSEvent) { hover() }
    override func rightMouseDown(with event: NSEvent) { capture?.finish() }

    override func mouseExited(with event: NSEvent) {
        guard start == nil else { return }
        area = nil
        update(label: "")
    }

    /// Not dragging: the window under the mouse, or the whole screen over the desktop.
    func hover() {
        NSCursor.crosshair.set()
        if let w = window, !w.isKeyWindow { w.makeKey() } // win Esc back after ⌘-Tab
        guard start == nil else { return }
        let m = NativeCapture.mouse
        let win = capture?.windows.first { $0.frame.contains(m) }
        area = win.map { $0.frame.intersection(display) } ?? display
        update(label: win?.name ?? "Whole screen")
    }

    override func mouseDown(with event: NSEvent) {
        start = NativeCapture.mouse
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.crosshair.set()
        guard let s = start else { return }
        let m = NativeCapture.mouse
        guard dragging || hypot(m.x - s.x, m.y - s.y) >= 4 else { return } // a click that wobbled
        dragging = true
        hint?.isHidden = true
        let r = CGRect(x: min(s.x, m.x), y: min(s.y, m.y), width: abs(m.x - s.x), height: abs(m.y - s.y)).integral.intersection(display)
        area = r
        update(label: "\(Int(r.width)) × \(Int(r.height))")
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; dragging = false }
        guard start != nil, let area, area.width >= 4, area.height >= 4 else { hint?.isHidden = false; return }
        capture?.take(area, of: shot, display: display)
    }

    /// Dims all but `area`, outlines it and puts `label` on its top-left corner.
    private func update(label: String) {
        let local = area.map { CGRect(x: $0.minX - display.minX, y: display.maxY - $0.maxY, width: $0.width, height: $0.height) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let local { path.addRect(local) }
        shade.path = path
        outline.path = local.map { CGPath(rect: $0.insetBy(dx: 1, dy: 1), transform: nil) }
        CATransaction.commit()
        guard let local, !label.isEmpty else { tagBG.isHidden = true; return }
        tagLabel.stringValue = label
        tagLabel.sizeToFit()
        let w = min(tagLabel.frame.width, 320)
        tagLabel.frame = CGRect(x: 6, y: 1, width: w, height: 16)
        var o = CGPoint(x: local.minX, y: local.maxY + 4)
        if o.y + 18 > bounds.maxY { o = CGPoint(x: local.minX + 6, y: local.maxY - 24) } // no room above: inside
        o.x = min(max(o.x, 0), bounds.maxX - w - 12)
        tagBG.frame = CGRect(origin: o, size: CGSize(width: w + 12, height: 18))
        tagBG.isHidden = false
    }
}

/// The snip in the annotation editor. Copy puts it on the clipboard and goes back to the app it came from.
@MainActor
final class SnipEditor: NSObject, NSWindowDelegate {
    private static var open: [SnipEditor] = []
    private let window: NSWindow

    static func show(_ shot: CGImage, scale: CGFloat, returnTo previous: NSRunningApplication?) {
        let editor = SnipEditor(shot, scale: scale, previous: previous)
        open.append(editor)
        NSApp.activate()
        editor.window.makeKeyAndOrderFront(nil)
    }

    private init(_ shot: CGImage, scale: CGFloat, previous: NSRunningApplication?) {
        let pixels = CGSize(width: shot.width, height: shot.height)
        let pts = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let image = NSImage(cgImage: shot, size: pts)
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = CGSize(width: min(visible.width * 0.9, max(760, pts.width + 40)),
                          height: min(visible.height * 0.9, max(480, pts.height + 140))) // toolbar and the caption field
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Screenshot"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: AnnotatorView(
            image: image, pixels: pixels, scale: scale, marks: [], caption: "", action: .copy,
            onSave: { [weak self] marks, caption in
                guard let png = MarkPainter.render(marks, on: image, pixels: pixels, scale: scale, caption: caption) else {
                    HUD.show("Couldn't copy the screenshot", isError: true)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(png, forType: .png)
                if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) } // for older apps
                self?.window.close()
                previous?.activate()
                HUD.show("Copied: paste it anywhere")
            },
            onCancel: { [weak self] in
                self?.window.close()
                previous?.activate()
            }))
        window.center()
    }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}
