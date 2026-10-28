import AppKit
import Carbon.HIToolbox

struct HotKeyCombo: Codable, Equatable {
    var code: UInt32
    var mods: UInt32 // Carbon modifier mask
    var label: String

    static let `default` = HotKeyCombo(code: UInt32(kVK_ANSI_O), mods: UInt32(cmdKey | optionKey), label: "⌥⌘O")
    static let snip = HotKeyCombo(code: UInt32(kVK_ANSI_4), mods: UInt32(cmdKey | optionKey | shiftKey), label: "⌥⇧⌘4") // macOS's ⇧⌘4, plus ⌥
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
    /// Screenshot to the clipboard (see `SnipCapture`).
    @Published var snipHotKey: HotKeyCombo {
        didSet { Self.d.set(try? JSONEncoder().encode(snipHotKey), forKey: "snipHotKey") }
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
        snipHotKey = Self.d.data(forKey: "snipHotKey").flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) } ?? .snip
    }

    /// The project new comments go to, from any thread.
    static var ticketsProjectKey: String? { d.string(forKey: "ticketsProject") }

    /// The project last picked at a site or app (see `ProjectChoices.place`); "" kept it on this Mac. From any thread.
    static func lastPick(at place: String) -> String? { (d.dictionary(forKey: "projectPicks") as? [String: String])?[place] }

    /// A pick in a comment box: remembered for its site or app, and the default for places without one yet.
    /// Not where a project's domains decide: a different pick there is a one-off. From any thread.
    static func chooseProject(_ key: String?, at place: String?) {
        if let place, Tickets.choices.match(place) != nil { return }
        DispatchQueue.main.async {
            if let place {
                var picks = d.dictionary(forKey: "projectPicks") as? [String: String] ?? [:]
                picks[place] = key ?? ""
                d.set(picks, forKey: "projectPicks")
            }
            if shared.ticketsProject != key { shared.ticketsProject = key }
        }
    }

    static var authorName: String {
        let a = (d.string(forKey: "author") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? NSUserName() : a
    }
}
