import AppKit
import SwiftUI

/// Something drawn on a screenshot: an arrow, a box, a text label or a freehand line, each with an optional label.
/// Points are image pixels from the top-left. Stored as `annotations` on the comment, so agents can read them too.
struct Mark: Codable {
    enum Kind: String, Codable, CaseIterable {
        case arrow, rect, text, pen

        var title: String { ["Arrow", "Box", "Text", "Pen"][Self.allCases.firstIndex(of: self)!] }
        var icon: String { ["arrow.up.right", "rectangle", "textformat", "scribble"][Self.allCases.firstIndex(of: self)!] }
        var hint: String {
            switch self {
            case .arrow: "Drag to draw an arrow, then label it"
            case .rect: "Drag to draw a box, then label it"
            case .text: "Click to place a label"
            case .pen: "Drag to draw"
            }
        }
    }

    var kind: Kind
    var points: [CGPoint]
    var label = ""
    var color: String

    static let palette = ["#F24822", "#FFC21A", "#14AE5C", "#0D99FF", "#1E1E1E"]

    static func decode(_ list: [[String: Any]]) -> [Mark] {
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return [] }
        return (try? JSONDecoder().decode([Mark].self, from: data)) ?? []
    }

    static func encode(_ marks: [Mark]) -> [[String: Any]] {
        guard let data = try? JSONEncoder().encode(marks) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Draws marks. Shared by the editor and the PNG export, so the saved image looks like what you drew.
enum MarkPainter {
    /// Strokes and labels grow with the screenshot, so they read the same on 1× and 2× captures.
    static func unit(_ pixels: CGSize) -> CGFloat { max(1, min(pixels.width, pixels.height) / 320) }

    /// `scale`: image pixels → canvas points.
    static func draw(_ marks: [Mark], in ctx: GraphicsContext, scale s: CGFloat, unit: CGFloat, bounds: CGRect) {
        var c = ctx
        c.addFilter(.shadow(color: .black.opacity(0.3), radius: 1.5 * unit * s, y: 0.5 * unit * s)) // readable on any background
        for m in marks { draw(m, in: c, scale: s, k: unit * s, bounds: bounds) }
    }

    private static func draw(_ m: Mark, in c: GraphicsContext, scale s: CGFloat, k: CGFloat, bounds: CGRect) {
        let color = Color(hex: m.color)
        let p = m.points.map { CGPoint(x: $0.x * s, y: $0.y * s) }
        let line = StrokeStyle(lineWidth: 2 * k, lineCap: .round, lineJoin: .round)
        switch m.kind {
        case .rect:
            guard p.count == 2 else { return }
            let r = CGRect(x: min(p[0].x, p[1].x), y: min(p[0].y, p[1].y), width: abs(p[1].x - p[0].x), height: abs(p[1].y - p[0].y))
            c.stroke(Path(roundedRect: r, cornerRadius: 2 * k), with: .color(color), style: line)
            label(m, in: c, k: k, bounds: bounds) { CGPoint(x: r.minX - k, y: r.minY - 4 * k - $0.height) }
        case .arrow:
            guard p.count == 2 else { return }
            let (a, b) = (p[0], p[1])
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = min(9 * k, hypot(b.x - a.x, b.y - a.y))
            func back(_ d: CGFloat, _ turn: CGFloat = 0) -> CGPoint {
                CGPoint(x: b.x - d * cos(angle + turn), y: b.y - d * sin(angle + turn))
            }
            var shaft = Path()
            shaft.move(to: a)
            shaft.addLine(to: back(head * 0.8))
            c.stroke(shaft, with: .color(color), style: line)
            var tip = Path()
            tip.addLines([b, back(head, -0.45), back(head, 0.45)])
            tip.closeSubpath()
            c.fill(tip, with: .color(color))
            c.stroke(tip, with: .color(color), style: StrokeStyle(lineWidth: k, lineJoin: .round))
            label(m, in: c, k: k, bounds: bounds) { CGPoint(x: a.x - $0.width / 2, y: a.y - $0.height / 2) } // callout at the tail
        case .pen:
            guard p.count > 1 else { return }
            var path = Path()
            path.addLines(p)
            c.stroke(path, with: .color(color), style: line)
        case .text:
            guard let a = p.first else { return }
            label(m, in: c, k: k, bounds: bounds) { _ in a }
        }
    }

    /// Colored pill with the label; `origin` gets the pill size and returns its top-left corner.
    private static func label(_ m: Mark, in c: GraphicsContext, k: CGFloat, bounds: CGRect, origin: (CGSize) -> CGPoint) {
        guard !m.label.isEmpty else { return }
        let ink: Color = m.color == "#FFC21A" ? .black : .white
        let text = c.resolve(Text(m.label).font(.system(size: 12 * k, weight: .semibold)).foregroundColor(ink))
        let pad = CGSize(width: 6 * k, height: 3 * k)
        let size = text.measure(in: CGSize(width: max(120 * k, bounds.width * 0.5), height: .greatestFiniteMagnitude))
        var box = CGRect(origin: .zero, size: CGSize(width: size.width + 2 * pad.width, height: size.height + 2 * pad.height))
        box.origin = origin(box.size)
        box.origin.x = min(max(box.minX, bounds.minX), bounds.maxX - box.width)
        box.origin.y = min(max(box.minY, bounds.minY), bounds.maxY - box.height)
        c.fill(Path(roundedRect: box, cornerRadius: 4 * k), with: .color(Color(hex: m.color)))
        c.draw(text, in: box.insetBy(dx: pad.width, dy: pad.height))
    }

    /// The screenshot with the marks baked in, at full resolution.
    @MainActor
    static func render(_ marks: [Mark], on image: NSImage, pixels: CGSize) -> Data? {
        let u = unit(pixels)
        let view = ZStack {
            Image(nsImage: image).resizable()
            Canvas { ctx, size in draw(marks, in: ctx, scale: 1, unit: u, bounds: CGRect(origin: .zero, size: size)) }
        }
        .frame(width: pixels.width, height: pixels.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage.flatMap(Screenshot.png)
    }
}

/// The annotation window for one comment's screenshot. The original screenshot is kept; the drawing is saved
/// next to it as `<id>-annotated.png`, and the marks as JSON, so you can edit them again later.
@MainActor
final class Annotator: NSObject, NSWindowDelegate {
    private static var open: [String: Annotator] = [:]
    private let id: String
    private let window: NSWindow

    /// "Post & draw" from a composer: open the fresh screenshot, or say why there is none.
    static func showAfterCapture(_ id: String) {
        guard let c = CommentStore.shared.comment(id), c.screenshot != nil else {
            HUD.show("No screenshot to draw on: turn on Screenshots in Settings", isError: true, seconds: 4)
            return
        }
        show(c)
    }

    static func show(_ comment: Comment) {
        if let a = open[comment.id] { NSApp.activate(); a.window.makeKeyAndOrderFront(nil); return }
        guard let path = comment.screenshot, let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let a = Annotator(comment, image: image, pixels: CGSize(width: cg.width, height: cg.height))
        open[comment.id] = a
        NSApp.activate()
        a.window.makeKeyAndOrderFront(nil)
    }

    private init(_ comment: Comment, image: NSImage, pixels: CGSize) {
        id = comment.id
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let pts = CGSize(width: pixels.width / screen.backingScaleFactor, height: pixels.height / screen.backingScaleFactor)
        let size = CGSize(width: min(screen.visibleFrame.width * 0.9, max(760, pts.width + 40)),
                          height: min(screen.visibleFrame.height * 0.9, max(480, pts.height + 90)))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        let id = comment.id
        window.title = "Annotate: " + comment.text.prefix(60)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: AnnotatorView(
            image: image, pixels: pixels, marks: Mark.decode(comment.annotations),
            onSave: { [weak self] marks in
                let png = marks.isEmpty ? nil : MarkPainter.render(marks, on: image, pixels: pixels)
                CommentStore.shared.setAnnotations(Mark.encode(marks), png: png, for: id)
                Thumbs.forget(CommentStore.annotatedURL(id).path)
                Tickets.changed(id)
                self?.window.close()
            },
            onCancel: { [weak self] in self?.window.close() }))
        window.center()
    }

    func windowWillClose(_ notification: Notification) { Self.open[id] = nil }
}

struct AnnotatorView: View {
    let image: NSImage
    let pixels: CGSize
    @State var marks: [Mark]
    let onSave: ([Mark]) -> Void
    let onCancel: () -> Void

    @State private var tool = Mark.Kind.arrow
    @State private var color = Mark.palette[0]
    @State private var drawing: Mark?
    @State private var editing: Int? // index of the mark whose label is being typed
    @State private var labelText = ""
    @FocusState private var labelFocused: Bool

    /// What the canvas shows: the marks, the label as it's typed, the shape being dragged.
    private var shown: [Mark] {
        var all = marks
        if let i = editing, all.indices.contains(i) { all[i].label = labelText }
        if let drawing { all.append(drawing) }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            GeometryReader { geo in
                let s = min(geo.size.width / pixels.width, geo.size.height / pixels.height)
                let size = CGSize(width: pixels.width * s, height: pixels.height * s)
                ZStack {
                    Image(nsImage: image).resizable()
                    Canvas { ctx, sz in
                        MarkPainter.draw(shown, in: ctx, scale: s, unit: MarkPainter.unit(pixels), bounds: CGRect(origin: .zero, size: sz))
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(drag(scale: s, size: size))
                .onHover { inside in inside ? NSCursor.crosshair.push() : NSCursor.pop() }
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(20)
            .background(Color.secondary.opacity(0.08))
            .overlay(alignment: .bottom) { if editing != nil { labelBar } }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onChange(of: color) { _, c in if let i = editing, marks.indices.contains(i) { marks[i].color = c } }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(Mark.Kind.allCases, id: \.self) { k in
                    Button { commitLabel(); tool = k } label: {
                        Image(systemName: k.icon).font(.system(size: 14))
                            .frame(width: 30, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tool == k ? Color.annotBlue : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tool == k ? Color.annotBlue.opacity(0.15) : .clear))
                    .help(k.title)
                }
            }
            HStack(spacing: 6) {
                ForEach(Mark.palette, id: \.self) { hex in
                    Circle().fill(Color(hex: hex))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(color == hex ? 0.55 : 0), lineWidth: 1.5))
                        .contentShape(Circle())
                        .onTapGesture { color = hex }
                }
            }
            Button { commitLabel(); _ = marks.popLast() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z")
                .help("Undo  ⌘Z")
                .disabled(marks.isEmpty)
            Button("Clear") { editing = nil; marks.removeAll() }
                .disabled(marks.isEmpty)
            Spacer()
            Text(tool.hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Button("Cancel", action: onCancel)
            Button("Save") { commitLabel(); onSave(marks) }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .help("Save  ⌘S")
        }
    }

    private var labelBar: some View {
        let text = editing.map { marks.indices.contains($0) && marks[$0].kind == .text } ?? false
        return HStack(spacing: 8) {
            TextField(text ? "Type the label" : "Label (optional)", text: $labelText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($labelFocused)
                .onSubmit(commitLabel)
                .onExitCommand(perform: commitLabel)
            Button("Done", action: commitLabel)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(.bottom, 30)
    }

    private func drag(scale s: CGFloat, size: CGSize) -> some Gesture {
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (min(max(p.x, 0), size.width) / s).rounded(), y: (min(max(p.y, 0), size.height) / s).rounded())
        }
        return DragGesture(minimumDistance: 0)
            .onChanged { v in
                if editing != nil { commitLabel() }
                let a = px(v.startLocation), b = px(v.location)
                switch tool {
                case .text: break
                case .pen:
                    if drawing == nil { drawing = Mark(kind: .pen, points: [a], color: color) }
                    if drawing?.points.last != b { drawing?.points.append(b) }
                default:
                    drawing = Mark(kind: tool, points: [a, b], color: color)
                }
            }
            .onEnded { v in
                let a = px(v.startLocation), b = px(v.location)
                if tool == .text {
                    marks.append(Mark(kind: .text, points: [b], color: color))
                    beginLabel(marks.count - 1)
                    return
                }
                guard let m = drawing else { return }
                drawing = nil
                // a click is not a shape
                guard m.kind == .pen ? m.points.count > 2 : hypot(b.x - a.x, b.y - a.y) * s >= 8 else { return }
                marks.append(m)
                if m.kind != .pen { beginLabel(marks.count - 1) }
            }
    }

    private func beginLabel(_ i: Int) {
        editing = i
        labelText = marks[i].label
        DispatchQueue.main.async { labelFocused = true }
    }

    /// Ends label typing. A text mark without text is dropped.
    private func commitLabel() {
        guard let i = editing else { return }
        editing = nil
        let t = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        labelText = ""
        guard marks.indices.contains(i) else { return }
        if marks[i].kind == .text && t.isEmpty { marks.remove(at: i) } else { marks[i].label = t }
    }
}
