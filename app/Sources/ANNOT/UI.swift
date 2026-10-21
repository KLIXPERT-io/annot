import AppKit
import SwiftUI

extension Color {
    static let annotBlue = Color(red: 13 / 255, green: 153 / 255, blue: 1)
    static let annotAgent = Color(red: 151 / 255, green: 71 / 255, blue: 1)
}

/// Same name → color/initials mapping as the web overlay, so people look the same everywhere.
enum Person {
    static let palette: [UInt32] = [0x0D99FF, 0xF24822, 0x14AE5C, 0xFF7A00, 0xFF24BD, 0x00B5CE, 0x5B6BFF]

    static func isAgent(_ name: String) -> Bool { name.hasPrefix("agent:") }
    static func display(_ name: String) -> String { name.replacingOccurrences(of: "agent:", with: "") }

    static func color(_ name: String) -> Color {
        if isAgent(name) { return .annotAgent }
        var x: Int32 = 0
        for u in name.utf16 { x = x &* 31 &+ Int32(u) }
        let hex = palette[Int(x.magnitude % UInt32(palette.count))]
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func initials(_ name: String) -> String {
        let parts = name.replacingOccurrences(of: "agent:", with: "")
            .split(whereSeparator: { " ._-".contains($0) })
        let a = parts.first?.first.map(String.init) ?? "?"
        let b = parts.count > 1 ? parts[1].first.map(String.init) ?? "" : ""
        return (a + b).uppercased()
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 24
    var body: some View {
        let agent = Person.isAgent(name)
        RoundedRectangle(cornerRadius: agent ? size * 0.3 : size / 2).fill(Person.color(name))
            .frame(width: size, height: size)
            .overlay(Text(agent ? "✦" : Person.initials(name))
                .font(.system(size: size * (agent ? 0.5 : 0.42), weight: .semibold)).foregroundStyle(.white))
    }
}

/// Figma-style comment pin: a bubble whose sharp bottom-left corner marks the spot.
struct PinBubble: View {
    let name: String
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 3, bottomTrailingRadius: 16, topTrailingRadius: 16)
            .fill(Person.color(name))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 3, bottomTrailingRadius: 16, topTrailingRadius: 16)
                .strokeBorder(.white, lineWidth: 2))
            .overlay(Text(Person.initials(name)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
            .frame(width: 32, height: 32)
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }
}

/// Small dark capsule at the bottom of the screen ("Comment sent", hints).
enum HUD {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    static func show(_ message: String, isError: Bool = false, seconds: Double = 1.8) {
        DispatchQueue.main.async {
            panel?.orderOut(nil)
            let view = NSHostingView(rootView: Capsule_(message: message, isError: isError))
            let size = view.fittingSize
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 72, width: size.width, height: size.height)
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1) // above the comment-mode panels
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = view
            p.orderFrontRegardless()
            panel = p
            hide?.cancel()
            let work = DispatchWorkItem { p.orderOut(nil) }
            hide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private struct Capsule_: View {
        let message: String
        let isError: Bool
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.orange : Color.green)
                Text(message).foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color(white: 0.12)))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(16)
        }
    }
}
