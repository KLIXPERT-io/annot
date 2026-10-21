import SwiftUI

/// @handle mentions of Rome people. Typing "@ma" offers the project's people whose handle or name starts with "ma";
/// the chosen one is written as "@handle", which Rome turns into a notification in issue comments.
enum Mentions {
    /// The "@ma" being typed at the end of `text` (SwiftUI fields don't tell where the caret is).
    static func typing(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil } // an email address
        let q = text[text.index(after: at)...]
        return q.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } ? String(q) : nil
    }

    static func matches(_ q: String, in people: [Tickets.Person]) -> [Tickets.Person] {
        let q = q.lowercased()
        let byHandle = people.filter { $0.handle.lowercased().hasPrefix(q) }
        let byName = people.filter { p in
            !byHandle.contains(p) && p.name.lowercased().split(whereSeparator: { " ._-".contains($0) }).contains { $0.hasPrefix(q) }
        }
        return Array((byHandle + byName).prefix(5))
    }

    /// Replaces the "@ma" at the end of `text` with "@handle ".
    static func complete(_ text: String, with p: Tickets.Person) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + p.handle + " "
    }

    /// Every @handle in `text`, in order, once each.
    static func handles(in text: String) -> [String] {
        var seen = Set<String>()
        return text.matches(of: #/(?:^|[\s(])@([A-Za-z0-9][A-Za-z0-9._-]*)/#).compactMap { m in
            var h = String(m.output.1)
            while h.last.map({ ".-".contains($0) }) == true { h.removeLast() } // "thanks @bob."
            return seen.insert(h.lowercased()).inserted ? h : nil
        }
    }
}

/// The suggestions under a comment field while an @handle is typed.
struct MentionList: View {
    let people: [Tickets.Person]
    let selected: Int
    let pick: (Tickets.Person) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(people.enumerated()), id: \.element.id) { i, p in
                Button { pick(p) } label: {
                    HStack(spacing: 8) {
                        Avatar(name: p.agent ? "agent:" + p.name : p.name, size: 20)
                        Text(p.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("@" + p.handle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(i == selected ? Color.annotBlue.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Wires a comment field to a MentionList: ↑↓ move, ↩ picks, ⎋ closes.
struct MentionState {
    var people: [Tickets.Person] = []
    var selected = 0
    var dismissed: String? // the text when ⎋ was pressed; the list stays closed until it changes

    /// Call on every change of the text.
    mutating func update(_ text: String, from all: [Tickets.Person]) {
        if dismissed != nil, dismissed != text { dismissed = nil }
        people = dismissed == nil ? Mentions.typing(text).map { Mentions.matches($0, in: all) } ?? [] : []
        selected = min(selected, max(people.count - 1, 0))
    }

    mutating func move(_ by: Int) {
        guard !people.isEmpty else { return }
        selected = (selected + by + people.count) % people.count
    }
}

extension View {
    /// ↑↓ ↩ ⎋ for the @ list, while it's showing. `pick` gets the highlighted person.
    func mentionKeys(_ state: Binding<MentionState>, text: String, pick: @escaping (Tickets.Person) -> Void) -> some View {
        onKeyPress(.downArrow) { state.wrappedValue.people.isEmpty ? .ignored : { state.wrappedValue.move(1); return .handled }() }
            .onKeyPress(.upArrow) { state.wrappedValue.people.isEmpty ? .ignored : { state.wrappedValue.move(-1); return .handled }() }
            .onKeyPress(.escape) {
                guard !state.wrappedValue.people.isEmpty else { return .ignored }
                state.wrappedValue.dismissed = text
                state.wrappedValue.people = []
                return .handled
            }
            .onKeyPress(.tab) {
                let s = state.wrappedValue
                guard !s.people.isEmpty else { return .ignored }
                pick(s.people[s.selected])
                return .handled
            }
    }
}
