import AppKit
import Carbon.HIToolbox

struct HotKeyCombo: Codable, Equatable {
    var code: UInt32
    var mods: UInt32 // Carbon modifier mask
    var label: String

    static let `default` = HotKeyCombo(code: UInt32(kVK_ANSI_O), mods: UInt32(cmdKey | optionKey), label: "⌥⌘O")
}

/// User settings, persisted in UserDefaults. The static accessors are safe to read from any thread.
final class Settings: ObservableObject {
    static let shared = Settings()
    private static let d = UserDefaults.standard

    @Published var author: String { didSet { Self.d.set(author, forKey: "author") } }
    @Published var onboarded: Bool { didSet { Self.d.set(onboarded, forKey: "onboarded") } }
    @Published var hotKey: HotKeyCombo {
        didSet { Self.d.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey") }
    }
    @Published var doubleTapOption: Bool { didSet { Self.d.set(doubleTapOption, forKey: "doubleTapOption") } }
    /// The Rome server, e.g. https://rome.example.com; "" until connected. Read it as `Rome.server`.
    @Published var romeServer: String { didSet { Self.d.set(romeServer, forKey: "romeServer") } }
    /// Project key new comments are sent to; nil keeps them on this Mac. The token is in the Keychain.
    @Published var ticketsProject: String? { didSet { Self.d.set(ticketsProject, forKey: "ticketsProject") } }

    /// How to start comment mode, for hints.
    var triggerLabel: String { doubleTapOption ? "⌥⌥ (double-tap Option)" : hotKey.label }

    private init() {
        Self.d.register(defaults: ["author": NSUserName(), "doubleTapOption": true])
        author = Self.d.string(forKey: "author") ?? NSUserName()
        onboarded = Self.d.bool(forKey: "onboarded")
        doubleTapOption = Self.d.bool(forKey: "doubleTapOption")
        romeServer = Self.d.string(forKey: "romeServer") ?? ""
        ticketsProject = Self.d.string(forKey: "ticketsProject")
        hotKey = Self.d.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) } ?? .default
    }

    /// The project new comments go to, from any thread.
    static var ticketsProjectKey: String? { d.string(forKey: "ticketsProject") }

    /// A pick in a comment box becomes the default for the next comment. From any thread.
    static func chooseProject(_ key: String?) {
        DispatchQueue.main.async { if shared.ticketsProject != key { shared.ticketsProject = key } }
    }

    static var authorName: String {
        let a = (d.string(forKey: "author") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? NSUserName() : a
    }
}
