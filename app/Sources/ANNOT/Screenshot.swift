import AppKit
import ScreenCaptureKit

/// Cropped screenshots via ScreenCaptureKit. Opt-in: without Screen Recording permission this returns nil
/// right away and never triggers the macOS prompt ("Screen & System Audio Recording"); comments save without one.
enum Screenshot {
    static var enabled: Bool { CGPreflightScreenCaptureAccess() }

    /// Region around a web element in any browser layout (Chrome, Arc's sidebar, docked devtools…).
    /// `mouse` is the click on screen (points), `mouseInViewport` the same click in CSS px; the rest is CSS px.
    static func web(mouse: CGPoint, mouseInViewport: CGPoint, element: CGRect, click: CGPoint, viewport: CGSize, dpr: CGFloat) async -> Data? {
        guard enabled, viewport.width > 0, viewport.height > 0 else { return nil }
        let zoom = dpr / backingScale(at: mouse) // page zoom: CSS px → points
        let origin = CGPoint(x: mouse.x - mouseInViewport.x * zoom, y: mouse.y - mouseInViewport.y * zoom)
        func onScreen(_ r: CGRect) -> CGRect {
            CGRect(x: origin.x + r.minX * zoom, y: origin.y + r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
        }
        return await region(around: onScreen(element), click: CGPoint(x: origin.x + click.x * zoom, y: origin.y + click.y * zoom),
                            within: onScreen(CGRect(origin: .zero, size: viewport)))
    }

    /// Screen region around a native element (global, top-left origin), without our own windows.
    static func region(around frame: CGRect, click: CGPoint, within limit: CGRect? = nil) async -> Data? {
        guard enabled else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(click) }) ?? content.displays.first
            else { return nil }
            let screen = CGDisplayBounds(display.displayID)
            let r = contextRect(frame, click: click, bounds: limit.map { $0.intersection(screen) } ?? screen)
            guard r.width >= 4, r.height >= 4 else { return nil }
            let me = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.sourceRect = r.offsetBy(dx: -screen.minX, dy: -screen.minY)
            cfg.width = Int(r.width * scale)
            cfg.height = Int(r.height * scale)
            cfg.showsCursor = false
            return png(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg))
        } catch {
            return nil
        }
    }

    /// Every display as it is right now, full resolution, with its frame (global, top-left origin). ANNOT's windows
    /// are in it (the Comments window can be snipped too), its panels and HUD aren't.
    static func displays() async -> [(id: CGDirectDisplayID, frame: CGRect, image: CGImage)] {
        guard enabled, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let panels = content.windows.filter { $0.owningApplication?.processID == getpid() && $0.windowLayer != 0 }
        var out: [(id: CGDirectDisplayID, frame: CGRect, image: CGImage)] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: panels)
            let frame = CGDisplayBounds(display.displayID), scale = CGFloat(filter.pointPixelScale)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(frame.width * scale)
            cfg.height = Int(frame.height * scale)
            cfg.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                out.append((display.displayID, frame, image))
            }
        }
        return out
    }

    /// Element padded a little and grown to at least 560×320 around the click, so agents see the surroundings.
    static func contextRect(_ el: CGRect, click: CGPoint, bounds: CGRect) -> CGRect {
        let minW: CGFloat = 560, minH: CGFloat = 320
        var r = el.isEmpty ? CGRect(x: click.x, y: click.y, width: 0, height: 0) : el.insetBy(dx: -24, dy: -24)
        if r.width < minW { r = CGRect(x: click.x - minW / 2, y: r.minY, width: minW, height: r.height) }
        if r.height < minH { r = CGRect(x: r.minX, y: click.y - minH / 2, width: r.width, height: minH) }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        return r.intersection(bounds)
    }

    /// Backing scale of the display under a global (top-left origin) point.
    static func backingScale(at p: CGPoint) -> CGFloat {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for s in NSScreen.screens {
            let f = s.frame
            if CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height).contains(p) { return s.backingScaleFactor }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
