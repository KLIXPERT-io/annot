import AppKit
import SwiftUI

/// The Comments window: every comment from Chrome and other apps, with thread, screenshot and context.
struct InboxView: View {
    enum Filter: String, CaseIterable { case open = "Open", resolved = "Resolved", all = "All" }

    /// "" all projects, "-" comments kept on this Mac, else a project key.
    private static let allProjects = "", localOnly = "-"

    @ObservedObject private var store = CommentStore.shared
    @ObservedObject private var tickets = Tickets.shared
    @State private var filter = Filter.open
    @AppStorage("inboxProject") private var projectFilter = InboxView.allProjects
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var pendingDelete: Set<String> = []

    private var visible: [Comment] {
        store.all.filter { c in
            guard filter == .all || (filter == .open) == c.isOpen else { return false }
            switch projectFilter {
            case Self.allProjects: break
            case Self.localOnly: if c.ticket != nil { return false }
            default: if c.ticket?.project != projectFilter { return false }
            }
            guard !query.isEmpty else { return true }
            return [c.text, c.details, c.author, c.place].contains { $0.localizedCaseInsensitiveContains(query) }
                || c.replies.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Projects to filter by: the connected ones, plus any that comments were sent to.
    private var projectKeys: [(key: String, name: String)] {
        var out = tickets.projects.map { ($0.key, "\($0.name) (\($0.key))") }
        for key in Set(store.all.compactMap { $0.ticket?.project }).sorted() where !out.contains(where: { $0.0 == key }) {
            out.append((key, key))
        }
        return out.map { (key: $0.0, name: $0.1) }
    }

    private var selected: [Comment] { store.all.filter { selection.contains($0.id) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Picker("", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if !projectKeys.isEmpty { projectMenu }
                    }
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                Divider()
                if visible.isEmpty {
                    VStack(spacing: 6) {
                        Spacer()
                        Text(query.isEmpty && projectFilter == Self.allProjects
                             ? "No \(filter == .all ? "" : filter.rawValue.lowercased() + " ")comments" : "No matches")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(visible, selection: $selection) { c in
                        CommentRow(comment: c) { pendingDelete = targets(c.id) }
                            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                            .swipeActions { Button("Delete", role: .destructive) { pendingDelete = [c.id] } }
                    }
                    .listStyle(.inset)
                    .environment(\.defaultMinListRowHeight, 20)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if !ids.isEmpty { actions(for: ids) }
                    }
                    .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
                }
            }
            .frame(width: 340)

            Divider()

            Group {
                if selected.count == 1, let c = selected.first {
                    CommentDetail(comment: c).id(c.id)
                } else if selected.count > 1 {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                        Text("\(selected.count) comments selected").font(.headline)
                        HStack { actions(for: selection) }
                            .buttonStyle(.bordered)
                    }
                } else {
                    ContentUnavailableView("No comment selected", systemImage: "text.bubble",
                                           description: Text("Press \(Settings.shared.triggerLabel) anywhere to leave one."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { if selection.isEmpty, let first = visible.first { selection = [first.id] } }
        .onChange(of: store.all.map(\.id)) { selection.formIntersection($1) } // drop deleted ones
        .confirmationDialog(pendingDelete.count == 1 ? "Delete this comment?" : "Delete \(pendingDelete.count) comments?",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                for id in pendingDelete { store.delete(id) }
                pendingDelete = []
            }
        } message: {
            Text(pendingDelete.contains { id in store.all.first { $0.id == id }?.ticket?.noteID != nil }
                 ? "Removed from this Mac with replies and screenshots. What was sent to Rome stays there."
                 : "Removed from this Mac with replies and screenshots.")
        }
    }

    private var projectMenu: some View {
        Menu {
            Picker("Project", selection: $projectFilter) {
                Text("All Projects").tag(Self.allProjects)
                Text("Only on This Mac").tag(Self.localOnly)
                Divider()
                ForEach(projectKeys, id: \.key) { Text($0.name).tag($0.key) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(projectFilter == Self.allProjects ? "All" : projectFilter == Self.localOnly ? "Mac" : projectFilter,
                  systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(projectFilter == Self.allProjects ? Color.secondary : Color.annotBlue)
        .help("Show comments of one project")
    }

    /// The row's comment, or the whole selection when the row is part of it.
    private func targets(_ id: String) -> Set<String> { selection.contains(id) ? selection : [id] }

    @ViewBuilder
    private func actions(for ids: Set<String>) -> some View {
        let items = store.all.filter { ids.contains($0.id) }
        if items.contains(where: \.isOpen) {
            Button { for c in items where c.isOpen { store.setStatus(c.id, "resolved") } } label: {
                Label(items.count == 1 ? "Resolve" : "Resolve All", systemImage: "checkmark.circle")
            }
        }
        if items.contains(where: { !$0.isOpen }) {
            Button { for c in items where !c.isOpen { store.setStatus(c.id, "open") } } label: {
                Label(items.count == 1 ? "Reopen" : "Reopen All", systemImage: "arrow.uturn.backward.circle")
            }
        }
        Button(role: .destructive) { pendingDelete = ids } label: {
            Label(items.count == 1 ? "Delete…" : "Delete \(items.count)…", systemImage: "trash")
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(name: comment.author, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(Person.display(comment.author)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(comment.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if !comment.isOpen {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                    }
                    Spacer(minLength: 0)
                    if let key = comment.ticket?.issueKey ?? comment.ticket?.project {
                        Text(key)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(comment.text).font(.system(size: 12)).lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: comment.isWeb ? "globe" : "macwindow")
                    Text(comment.place).lineLimit(1).truncationMode(.middle)
                    if !comment.replies.isEmpty {
                        Text("· \(comment.replies.count) \(comment.replies.count == 1 ? "reply" : "replies")").fixedSize()
                    }
                    if !comment.details.isEmpty {
                        Image(systemName: "text.alignleft").help("Has details")
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let img = Thumbs.image(comment.bestScreenshot) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.1)))
            }
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottomTrailing) {
            if hover {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 20, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete")
            }
        }
        .onHover { hover = $0 }
    }
}

private struct CommentDetail: View {
    let comment: Comment
    @State private var reply = ""
    @State private var mention = MentionState()
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(comment.isOpen ? "Open" : "Resolved")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(comment.isOpen ? Color.annotBlue.opacity(0.12) : Color.green.opacity(0.14)))
                    .foregroundStyle(comment.isOpen ? Color.annotBlue : Color.green)
                TicketBadge(comment: comment)
                Spacer()
                Button(action: openSource) {
                    Label(comment.url != nil ? "Open in \(browser?.name ?? "Browser")" : "Open App", systemImage: "arrow.up.forward.app")
                }
                Button {
                    CommentStore.shared.setStatus(comment.id, comment.isOpen ? "resolved" : "open")
                } label: {
                    Label(comment.isOpen ? "Resolve" : "Reopen", systemImage: comment.isOpen ? "checkmark.circle" : "arrow.uturn.backward.circle")
                }
                if comment.screenshot != nil {
                    Button { Annotator.show(comment) } label: { Label("Annotate", systemImage: "pencil.tip.crop.circle") }
                        .help("Draw arrows, boxes and labels on the screenshot")
                }
                Menu {
                    Button("Copy for Developer (Markdown)", action: copyMarkdown)
                    Button("Copy as JSON", action: copyJSON)
                    Divider()
                    Button("Open Screenshot in Preview") {
                        if let p = comment.bestScreenshot { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                    }
                    .disabled(comment.screenshot == nil)
                    Button("Show Screenshot in Finder") {
                        if let p = comment.bestScreenshot { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                    }
                    .disabled(comment.screenshot == nil)
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let img = Thumbs.image(comment.bestScreenshot) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.08)))
                            .onTapGesture { Annotator.show(comment) }
                            .help("Click to draw arrows, boxes and labels")
                    }
                    MessageView(author: comment.author, text: comment.text, date: comment.createdAt)
                    DetailsBox(comment: comment).padding(.leading, 38)
                    ContextBox(comment: comment, copy: copyMarkdown).padding(.leading, 38)
                    ForEach(Array(comment.replies.enumerated()), id: \.offset) { _, r in
                        MessageView(author: r.author, text: r.text, date: r.createdAt)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if !mention.people.isEmpty {
                MentionList(people: mention.people, selected: mention.selected) { reply = Mentions.complete(reply, with: $0) }
                Divider()
            }

            HStack(alignment: .top, spacing: 8) {
                Avatar(name: Settings.authorName)
                TextField("Reply", text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .padding(.top, 4)
                    .onSubmit { mention.people.isEmpty ? send() : (reply = Mentions.complete(reply, with: mention.people[mention.selected])) }
                    .mentionKeys($mention, text: reply) { reply = Mentions.complete(reply, with: $0) }
                    .onChange(of: reply) {
                        mention.update(reply, from: Tickets.choices.people(in: comment.ticket?.project ?? Settings.ticketsProjectKey))
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(canSend ? Color.annotBlue : Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(12)
        }
        .task { await Tickets.shared.sync(comment.id) }
        .confirmationDialog("Delete this comment?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { CommentStore.shared.delete(comment.id) }
        } message: {
            Text("The comment, its replies and screenshot are removed from this Mac.")
        }
    }

    private var canSend: Bool { !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        CommentStore.shared.reply(comment.id, text: t)
        reply = ""
    }

    /// The browser the comment was made in, else Chrome/Arc if installed, else the default browser.
    private var browser: Browser? {
        Browser.with(comment.anchor["browser"] as? String ?? comment.anchor("bundle_id")).flatMap { $0.isInstalled ? $0 : nil }
            ?? Browser.installed.first
    }

    private func openSource() {
        let ws = NSWorkspace.shared
        if let u = comment.url.flatMap(URL.init(string:)) { // web comments, and screen-mode ones made on a web page
            if let b = browser, let app = ws.urlForApplication(withBundleIdentifier: b.bundleID) {
                ws.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                ws.open(u)
            }
        } else if let app = ws.urlForApplication(withBundleIdentifier: comment.anchor("bundle_id")) {
            ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func copyJSON() {
        guard let data = try? JSONSerialization.data(withJSONObject: comment.dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        copy(String(decoding: data, as: UTF8.self))
    }

    private func copyMarkdown() { copy(comment.markdown) }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        HUD.show("Copied")
    }
}

/// The comment's note in a project's Triage queue (or the issue it became), or a menu to send it there.
private struct TicketBadge: View {
    let comment: Comment
    @ObservedObject private var tickets = Tickets.shared

    var body: some View {
        if let t = comment.ticket, t.noteID != nil {
            HStack(spacing: 4) {
                Image(systemName: t.issueKey != nil ? "ticket" : "tray")
                Text(t.label)
                if let e = t.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
                    Button("Retry") { Task { await tickets.sync(comment.id) } }.buttonStyle(.link)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help(t.issueKey != nil ? "Triaged into \(t.issueKey!)" : "In the Triage queue of \(t.project)")
        } else if tickets.account != nil {
            HStack(spacing: 4) {
                if let e = comment.ticket?.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
                }
                Menu(comment.ticket?.error != nil ? "Not sent" : "Send to Triage…") {
                    ForEach(tickets.projects) { p in
                        Button("\(p.name) (\(p.key))") { Task { await tickets.sync(comment.id, to: p.key) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(.system(size: 11))
        }
    }
}

/// A longer description under the comment, written any time after posting. Goes into the Triage note,
/// or into one "Details" comment on the issue once triaged.
private struct DetailsBox: View {
    let comment: Comment
    @State private var editing = false
    @State private var draft = ""
    @State private var mention = MentionState()
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 90, maxHeight: 260)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.annotBlue.opacity(0.6)))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Steps to reproduce, what you expected, links…")
                                .font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                        }
                    }
                    .mentionKeys($mention, text: draft) { draft = Mentions.complete(draft, with: $0) }
                    .onChange(of: draft) {
                        mention.update(draft, from: Tickets.choices.people(in: comment.ticket?.project ?? Settings.ticketsProjectKey))
                    }
                    .onKeyPress(.escape) { mention.people.isEmpty ? { editing = false; return .handled }() : .ignored }
                if !mention.people.isEmpty {
                    MentionList(people: mention.people, selected: mention.selected) { draft = Mentions.complete(draft, with: $0) }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                }
                HStack {
                    Text(comment.ticket?.noteID != nil ? "Also updates \(comment.ticket!.label) in Rome" : "Markdown and @mentions work")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save", action: save)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .onAppear { draft = comment.details; DispatchQueue.main.async { focused = true } }
        } else if comment.details.isEmpty {
            Button { editing = true } label: { Label("Add details", systemImage: "text.badge.plus") }
                .buttonStyle(.link)
                .font(.system(size: 12))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Details").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { editing = true }.buttonStyle(.link).font(.system(size: 11))
                }
                Text(comment.details).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            .onTapGesture(count: 2) { editing = true }
        }
    }

    private func save() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != comment.details { CommentStore.shared.setDetails(comment.id, t) }
        editing = false
    }
}

private struct MessageView: View {
    let author: String
    let text: String
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: author, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Person.display(author)).font(.system(size: 13, weight: .semibold))
                    if Person.isAgent(author) {
                        Text("AGENT").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.annotAgent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.annotAgent.opacity(0.1)))
                    }
                    Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What the comment points at — what an agent needs to find it again.
private struct ContextBox: View {
    let comment: Comment
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(comment.contextRows, id: \.0) { label, value, mono in
                    GridRow {
                        Text(label).foregroundStyle(.secondary)
                        Text(value)
                            .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button(action: copy) { Label("Copy for Developer", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Comment, page, element, selector and screenshot path as Markdown")
        }
        .font(.system(size: 12))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }
}

extension Comment {
    private var dom: [String: Any] { anchor["dom"] as? [String: Any] ?? [:] }
    private func dom(_ key: String) -> String { dom[key].map { "\($0)" } ?? "" }

    /// `button#buy.btn.btn-primary`
    private var elementName: String {
        let classes = dom["classes"] as? [String] ?? []
        return anchor("tag") + (dom("id").isEmpty ? "" : "#" + dom("id")) + classes.map { "." + $0 }.joined()
    }

    /// What the comment points at, for a developer or an agent to find it: label, value, monospaced. Empty rows dropped.
    var contextRows: [(String, String, Bool)] {
        let rows: [(String, String, Bool)]
        if isWeb {
            let size = dom["size"] as? [String: Any] ?? [:], style = dom["style"] as? [String: Any] ?? [:]
            let looks = size.isEmpty ? "" : ["\(size["w"] ?? 0)×\(size["h"] ?? 0) px", "\(style["font"] ?? "")",
                                              "\(style["color"] ?? "") on \(style["background"] ?? "")"].joined(separator: " · ")
            rows = [("Page", url ?? "", false),
                    ("Element", "<\(elementName)> \(anchor("text").isEmpty ? "" : "“\(anchor("text"))”")", false),
                    ("Selector", anchor("selector"), true),
                    ("HTML", dom("html"), true),
                    ("DOM path", dom("path"), true),
                    ("Style", looks, false)]
        } else { // raw `ax_path` stays in the JSON for agents
            rows = [("App", anchor("app_name"), false),
                    ("Window", anchor("window_title"), false),
                    ("Page", url ?? "", false),
                    ("Element", [AXNames.role(anchor("ax_role")),
                                 anchor("ax_title").isEmpty ? "" : "“\(anchor("ax_title"))”"].filter { !$0.isEmpty }.joined(separator: " "), false),
                    ("Path", AXNames.path(anchor("ax_path")), false)]
        }
        return rows.filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The comment as a Markdown snippet to paste into an issue, a PR or an agent prompt.
    var markdown: String { markdown(screenshotPath: true) }

    /// `screenshotPath: false` for Rome, where the file is attached and a local path means nothing.
    func markdown(screenshotPath: Bool) -> String {
        var md = ["**\(Person.display(author))**: \(text)", ""]
        if !details.isEmpty { md += [details, ""] }
        let mentioned = Mentions.handles(in: ([text, details] + replies.map(\.text)).joined(separator: "\n"))
        if !mentioned.isEmpty { md.append("- For: " + mentioned.map { "@" + $0 }.joined(separator: ", ")) }
        for (label, value, mono) in contextRows where label != "Style" {
            if isWeb, label == "Element" { // `<tag>` unquoted would vanish as HTML in GitHub
                md.append("- Element: `<\(elementName)>`" + (anchor("text").isEmpty ? "" : " “\(anchor("text"))”"))
                continue
            }
            md.append("- \(label): " + (mono ? "`\(value.replacingOccurrences(of: "`", with: "'"))`" : value))
        }
        if screenshotPath, let s = bestScreenshot { md.append("- Screenshot: \(s)") }
        let marks = Mark.decode(annotations).filter { !$0.label.isEmpty }
        if !marks.isEmpty {
            md.append("- Marked on the screenshot: " + marks.map { "\($0.kind.title.lowercased()) “\($0.label)”" }.joined(separator: ", "))
        }
        for r in replies { md.append("> **\(Person.display(r.author))**: \(r.text)") }
        return md.joined(separator: "\n")
    }
}

enum Thumbs {
    private static let cache = NSCache<NSString, NSImage>()

    static func forget(_ path: String) { cache.removeObject(forKey: path as NSString) }

    static func image(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        if let img = cache.object(forKey: path as NSString) { return img }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}
