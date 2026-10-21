import AppKit
import SwiftUI

/// Labels of other apps' UI for the setup guide: System Settings, macOS alerts, Safari and Chrome follow the macOS
/// language, so a German Mac gets the German names to look for.
enum Loc {
    static let german = Locale.preferredLanguages.first?.hasPrefix("de") == true
    static func t(_ en: String, _ de: String) -> String { german ? de : en }

    static let privacy = t("Privacy & Security", "Datenschutz & Sicherheit")
    static let accessibility = t("Accessibility", "Bedienungshilfen")
    static let screenRecording = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        ? t("Screen & System Audio Recording", "Aufnahme von Bildschirm & Systemaudio") : t("Screen Recording", "Bildschirmaufnahme")
}

extension Browser {
    var icon: NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "globe", accessibilityDescription: name) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The app menu's title.
    var menuName: String { name.replacingOccurrences(of: "Google ", with: "") }

    /// Where a Chromium browser keeps "Allow JavaScript from Apple Events", as its menus say it. Chrome follows the
    /// macOS language; Arc's menus are English only.
    var jsMenu: (view: String, developer: String, item: String) {
        Loc.german && bundleID != "company.thebrowser.Browser"
            ? ("Darstellung", "Entwickler", "JavaScript von Apple Events zulassen")
            : ("View", "Developer", "Allow JavaScript from Apple Events")
    }
}

// MARK: - The pictures, one per step. Drawn rather than screenshots, so they follow light/dark mode and the language.
// Only the labels to look for are text; everything else is a placeholder bar.

/// Welcome: double-tap ⌥, and a pin with a comment lands on the page.
struct HeroArt: View {
    let keys: [String]
    let taps: Bool
    @State private var shown = false

    var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 8) {
                Keys(keys: keys, taps: taps)
                Caption(taps ? "double-tap" : "press")
            }
            Arrow()
            MockWindow(width: 300, height: 164) {
                VStack(alignment: .leading, spacing: 9) {
                    Capsule().fill(Color.primary.opacity(0.07)).frame(height: 16)
                        .overlay(alignment: .leading) { Bar(width: 90, height: 5).padding(.leading, 10) }
                    Bar(width: 150, height: 9)
                    Bar(width: 230)
                    Bar(width: 196)
                    HStack(alignment: .top, spacing: 8) {
                        SignUpButton()
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.annotBlue, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            .opacity(shown ? 1 : 0.85)
                        PinBubble(name: Settings.authorName)
                            .scaleEffect(shown ? 0.8 : 0.2, anchor: .bottomLeading)
                            .opacity(shown ? 1 : 0)
                        CommentCard(text: "Bigger, please?")
                            .opacity(shown ? 1 : 0)
                            .offset(x: shown ? 0 : -10)
                    }
                    .padding(.top, 2)
                }
                .padding(12)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.35).delay(0.6)) { shown = true } }
    }
}

/// Accessibility: System Settings › Privacy & Security › Accessibility, with ANNOT's switch turning on.
struct AccessibilityArt: View {
    let granted: Bool
    @State private var on = false

    var body: some View {
        MockWindow(width: 450, height: 170) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Bar(width: 80)
                    Bar(width: 64)
                    Bar(width: 72)
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: 4).fill(Color.blue))
                        Text(Loc.privacy).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
                    Bar(width: 70)
                    Bar(width: 56)
                }
                .padding(.horizontal, 10).padding(.top, 4)
                .frame(width: 170, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                .background(Color.primary.opacity(0.035))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text(Loc.accessibility).font(.system(size: 12, weight: .bold))
                    }
                    VStack(spacing: 0) {
                        appRow(nil, on: true)
                        Divider().padding(.leading, 36)
                        appRow(NSApp.applicationIconImage, on: on || granted)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .padding(.horizontal, 14).padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.35).delay(0.9)) { on = true } }
    }

    private func appRow(_ icon: NSImage?, on: Bool) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                Text("ANNOT").font(.system(size: 11, weight: .medium))
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.14)).frame(width: 20, height: 20)
                Bar(width: 60)
            }
            Spacer()
            SwitchMock(on: on).pulse(icon != nil, radius: 8)
        }
        .padding(.horizontal, 8).frame(height: 34)
    }
}

/// Browser control: the alert macOS shows once per browser, Allow highlighted.
struct AutomationArt: View {
    let browser: Browser?

    var body: some View {
        let name = browser?.name ?? "Google Chrome"
        VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 42, height: 42)
                if let browser { Image(nsImage: browser.icon).resizable().frame(width: 22, height: 22).offset(x: 6, y: 4) }
            }
            Text(Loc.t("“ANNOT” wants access to control “\(name)”.", "„ANNOT“ möchte Zugriffsrechte, um „\(name)“ zu steuern."))
                .font(.system(size: 11, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                Bar(width: 190, height: 5)
                Bar(width: 160, height: 5)
            }
            HStack(spacing: 8) {
                AlertButton(label: Loc.t("Don’t Allow", "Nicht erlauben"), prominent: false)
                AlertButton(label: Loc.t("Allow", "Erlauben"), prominent: true).pulse(radius: 6)
            }
            .padding(.top, 6)
        }
        .padding(14)
        .frame(width: 252)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }
}

/// Chrome or Arc: the menu bar with View › Developer › Allow JavaScript from Apple Events open.
struct BrowserMenuArt: View {
    let browser: Browser

    var body: some View {
        let m = browser.jsMenu
        ZStack(alignment: .topLeading) {
            MenuBarStrip()
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "apple.logo").frame(height: 24)
                Text(browser.menuName).fontWeight(.bold).frame(height: 24)
                Bar(width: 18).frame(height: 24)
                Bar(width: 22).frame(height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.view)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.14)))
                        .frame(height: 24)
                    HStack(alignment: .top, spacing: -3) {
                        MenuMock(rows: [.bar(80), .bar(64), .bar(72), .item(m.developer, submenu: true), .separator, .bar(70)])
                        MenuMock(rows: [.bar(70), .bar(90), .bar(80), .separator, .item(m.item, checked: true, pulse: true)])
                            .padding(.top, 3 * MenuMock.rowHeight)
                    }
                }
            }
            .font(.system(size: 11))
            .padding(.leading, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Safari: Settings › Advanced (show the developer features), then Settings › Developer.
struct SafariSettingsArt: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            pane(1, symbol: "gearshape.2", tab: Loc.t("Advanced", "Erweitert"),
                 check: Loc.t("Show features for web developers", "Funktionen für Web-Entwickler anzeigen"))
            pane(2, symbol: "wrench.and.screwdriver", tab: Loc.t("Developer", "Entwickler"),
                 check: Loc.t("Allow JavaScript from Apple Events", "JavaScript von Apple Events erlauben"))
        }
    }

    private func pane(_ n: Int, symbol: String, tab: String, check: String) -> some View {
        MockWindow(title: tab, width: 246, height: 158) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)).frame(width: 18, height: 18)
                    }
                    VStack(spacing: 2) {
                        Image(systemName: symbol).font(.system(size: 13))
                        Text(tab).font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Bar(width: 150)
                    Checkbox(label: check).pulse(radius: 4)
                    Bar(width: 120)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .topLeading) { NumberBadge(n: n).offset(x: -9, y: -9) }
    }
}

/// Restart: ⌘Q, then open each browser again.
struct RestartArt: View {
    let browsers: [Browser]
    @State private var turn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 22) {
            VStack(spacing: 8) {
                Keys(keys: ["⌘", "Q"], taps: false)
                Caption("Quit")
            }
            Arrow()
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ForEach(browsers, id: \.bundleID) { Image(nsImage: $0.icon).resizable().frame(width: 54, height: 54) }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.annotBlue))
                        .rotationEffect(.degrees(turn ? 360 : 0))
                        .offset(x: 12, y: -12)
                }
                Caption("Open again")
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { turn = true }
        }
    }
}

/// Screenshots: the commented element, cropped and kept with the comment.
struct ScreenshotArt: View {
    var body: some View {
        HStack(spacing: 22) {
            MockWindow(width: 250, height: 160) {
                VStack(alignment: .leading, spacing: 9) {
                    Bar(width: 130, height: 9)
                    Bar(width: 200)
                    Bar(width: 170)
                    SignUpButton()
                        .padding(10)
                        .overlay(CropFrame())
                        .padding(.top, 4)
                }
                .padding(14)
            }
            Arrow()
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    SignUpButton().scaleEffect(1.3)
                        .frame(width: 130, height: 84)
                        .background(Color(nsColor: .windowBackgroundColor))
                    PinBubble(name: Settings.authorName).scaleEffect(0.7).offset(x: -4, y: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .rotationEffect(.degrees(-3))
                Caption("saved with the comment")
            }
        }
    }
}

/// Ready: the shortcut, and where ANNOT lives (the menu bar, no Dock icon).
struct ReadyArt: View {
    let keys: [String]
    let taps: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Spacer()
                Bar(width: 14, height: 9)
                Bar(width: 18, height: 9)
                Image(systemName: "text.bubble")
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.14)))
                    .pulse(radius: 4)
                Bar(width: 14, height: 9)
                Text("9:41")
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 14).frame(height: 24)
            .background(MenuBarStrip())
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 8) {
                    Keys(keys: keys, taps: taps, size: 48)
                    Caption(taps ? "double-tap, anywhere" : "anywhere")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                MenuMock(rows: [.item("Add Comment", shortcut: taps ? "⌥⌥" : keys.joined(), highlighted: false),
                                .item("Comments…", shortcut: "⌘K", highlighted: false),
                                .separator, .bar(70), .bar(90), .separator,
                                .item("Setup Guide…", highlighted: false)])
                    .padding(.trailing, 8).padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Pieces

/// Keyboard keys; `taps` presses them twice now and then, like a double-tap.
private struct Keys: View {
    let keys: [String]
    let taps: Bool
    var size: CGFloat = 42
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let caps = HStack(spacing: 5) { ForEach(keys.indices, id: \.self) { KeyCap(label: keys[$0], size: size) } }
        if taps && !reduceMotion {
            caps.phaseAnimator(TapPhase.allCases) { view, phase in
                view.offset(y: phase.down ? 2 : 0).scaleEffect(phase.down ? 0.95 : 1)
            } animation: { phase in
                phase == .rest ? .linear(duration: 1.5) : .easeOut(duration: 0.08)
            }
        } else {
            caps
        }
    }

    private enum TapPhase: CaseIterable {
        case rest, down1, up1, down2, up2
        var down: Bool { self == .down1 || self == .down2 }
    }
}

private struct KeyCap: View {
    let label: String
    let size: CGFloat

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.42, weight: .medium))
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, label.count > 1 ? size * 0.2 : 0)
            .background(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.3), radius: 0, y: 2))
            .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }
}

private struct MockWindow<Content: View>: View {
    var title: String?
    var width: CGFloat
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 9, height: 9) }
                    Spacer()
                }
                if let title { Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(height: 24)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

/// A menu; `.item`s are text, highlighted when they're the path to click.
private struct MenuMock: View {
    enum Row {
        case bar(CGFloat)
        case separator
        case item(String, shortcut: String = "", highlighted: Bool = true, checked: Bool = false, submenu: Bool = false, pulse: Bool = false)
    }

    static let rowHeight: CGFloat = 20
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { row(rows[$0]) }
        }
        .padding(5)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
    }

    @ViewBuilder private func row(_ r: Row) -> some View {
        switch r {
        case let .bar(width):
            Bar(width: width).padding(.leading, 20).frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        case .separator:
            Divider().padding(.horizontal, 6).padding(.vertical, 4)
        case let .item(label, shortcut, highlighted, checked, submenu, pulse):
            HStack(spacing: 0) {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).opacity(checked ? 1 : 0).frame(width: 20)
                Text(label)
                Spacer(minLength: submenu || !shortcut.isEmpty ? 24 : 12)
                if submenu { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                if !shortcut.isEmpty { Text(shortcut).foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)) }
            }
            .font(.system(size: 11))
            .padding(.trailing, 8)
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 4).fill(highlighted ? Color.accentColor : .clear))
            .pulse(pulse, radius: 4)
        }
    }
}

private struct MenuBarStrip: View {
    var body: some View {
        Rectangle().fill(.bar).frame(height: 24)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
    }
}

private struct SwitchMock: View {
    let on: Bool

    var body: some View {
        Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.2))
            .frame(width: 28, height: 16)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5).frame(width: 13, height: 13).padding(1.5)
            }
    }
}

private struct Checkbox: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3.5).fill(Color.accentColor).frame(width: 14, height: 14)
                .overlay(Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white))
            Text(label).font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.vertical, 2).padding(.trailing, 4)
    }
}

private struct AlertButton: View {
    let label: String
    let prominent: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? Color.accentColor : Color.primary.opacity(0.1)))
    }
}

private struct SignUpButton: View {
    var body: some View {
        Text("Sign up").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 84, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.annotBlue))
    }
}

private struct CommentCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Avatar(name: Settings.authorName, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(Settings.authorName).font(.system(size: 9, weight: .bold)).lineLimit(1)
                Text(text).font(.system(size: 9.5))
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

/// Dashed selection with corner handles, like a screenshot crop.
private struct CropFrame: View {
    var body: some View {
        Rectangle().strokeBorder(Color.annotBlue, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .overlay(alignment: .topLeading) { handle }
            .overlay(alignment: .topTrailing) { handle }
            .overlay(alignment: .bottomLeading) { handle }
            .overlay(alignment: .bottomTrailing) { handle }
    }

    private var handle: some View {
        Rectangle().fill(.white).frame(width: 6, height: 6).overlay(Rectangle().strokeBorder(Color.annotBlue, lineWidth: 1.5))
            .padding(-3)
    }
}

private struct NumberBadge: View {
    let n: Int

    var body: some View {
        Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            .frame(width: 22, height: 22).background(Circle().fill(Color.annotBlue))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

private struct Bar: View {
    let width: CGFloat
    var height: CGFloat = 6

    var body: some View { Capsule().fill(Color.primary.opacity(0.13)).frame(width: width, height: height) }
}

private struct Arrow: View {
    var body: some View { Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary) }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View { Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
}

/// A ring rippling out from the thing to click.
private struct Pulse: ViewModifier {
    let radius: CGFloat
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                .stroke(Color.annotBlue, lineWidth: 2)
                .padding(out ? -9 : -3)
                .opacity(out ? 0 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeOut(duration: 1.3).delay(0.2).repeatForever(autoreverses: false)) { out = true }
                }
        )
    }
}

private extension View {
    @ViewBuilder func pulse(_ active: Bool = true, radius: CGFloat) -> some View {
        if active { modifier(Pulse(radius: radius)) } else { self }
    }
}
