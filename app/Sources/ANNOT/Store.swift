import Foundation
import SQLite3

struct Comment: Identifiable {
    struct Reply {
        var author: String
        var text: String
        var createdAt: Date
        var remoteID: String? // Rome comment ID (ncm_… on the note in Triage); older ones: annot.reply.… metafield, "note": only in the note body
    }

    var id: String
    var tempId: String?
    var author: String
    var text: String
    var details = "" // longer description added after posting
    var status: String // open | resolved
    var createdAt: Date
    var projectID: String?
    var anchor: [String: Any]
    var screenshot: String? // absolute path to a PNG
    var annotations: [[String: Any]] = [] // arrows, boxes, labels drawn on the screenshot (see Mark)
    var annotatedScreenshot: String? // the screenshot with them baked in
    var replies: [Reply] = []
    var ticket: TicketLink? // sent to Rome
    var remote = false // made on another Mac, mirrored from Rome: replies and Resolve sync, the rest is its author's
    let pageKey: String? // web comments only

    var isOpen: Bool { status == "open" }
    var isWeb: Bool { anchor["kind"] as? String == "web" }
    var url: String? { anchor["url"] as? String }
    func anchor(_ key: String) -> String { anchor[key].map { "\($0)" } ?? "" }
    /// What to show and hand to an agent: the annotated screenshot if there is one.
    var bestScreenshot: String? { annotatedScreenshot ?? screenshot }

    /// Where it was made: "client.com/pricing" or "Slack — #general".
    var place: String {
        if isWeb, let u = url.flatMap(URL.init(string:)) { return (u.host ?? "") + u.path }
        return [anchor("app_name"), anchor("window_title")].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    init(id: String, tempId: String?, author: String, text: String, status: String, createdAt: Date,
         projectID: String?, anchor: [String: Any], screenshot: String? = nil,
         annotations: [[String: Any]] = [], annotatedScreenshot: String? = nil, replies: [Reply] = [], ticket: TicketLink? = nil) {
        self.id = id
        self.tempId = tempId
        self.author = author
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.projectID = projectID
        self.anchor = anchor
        self.screenshot = screenshot
        self.annotations = annotations
        self.annotatedScreenshot = annotatedScreenshot
        self.replies = replies
        self.ticket = ticket
        pageKey = anchor["kind"] as? String == "web" ? (anchor["url"] as? String).map(CommentStore.pageKey) : nil
    }

    /// JSON shape shared with the overlay and stored in the database.
    var dict: [String: Any] {
        var d: [String: Any] = [
            "id": id, "author": author, "text": text, "status": status, "created_at": ISO.string(createdAt), "anchor": anchor,
            "replies": replies.map { r -> [String: Any] in
                var d: [String: Any] = ["author": r.author, "text": r.text, "created_at": ISO.string(r.createdAt)]
                d["remote_id"] = r.remoteID
                return d
            },
        ]
        d["tempId"] = tempId
        d["project_id"] = projectID
        d["screenshot_path"] = screenshot
        d["annotations"] = annotations.isEmpty ? nil : annotations
        d["annotated_screenshot_path"] = annotatedScreenshot
        d["ticket"] = ticket?.dict
        d["details"] = details.isEmpty ? nil : details
        d["remote"] = remote ? true : nil
        return d
    }

    init?(dict d: [String: Any]) {
        guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
        let replies = (d["replies"] as? [[String: Any]] ?? []).map {
            Reply(author: $0["author"] as? String ?? "", text: $0["text"] as? String ?? "", createdAt: ISO.date($0["created_at"] as? String) ?? Date(),
                  remoteID: $0["remote_id"] as? String)
        }
        self.init(id: id, tempId: d["tempId"] as? String, author: d["author"] as? String ?? "", text: text,
                  status: d["status"] as? String ?? "open", createdAt: ISO.date(d["created_at"] as? String) ?? Date(),
                  projectID: d["project_id"] as? String, anchor: d["anchor"] as? [String: Any] ?? [:],
                  screenshot: d["screenshot_path"] as? String, annotations: d["annotations"] as? [[String: Any]] ?? [],
                  annotatedScreenshot: d["annotated_screenshot_path"] as? String, replies: replies,
                  ticket: TicketLink(dict: d["ticket"] as? [String: Any]))
        details = d["details"] as? String ?? ""
        remote = d["remote"] as? Bool ?? false
    }
}

enum ISO {
    private static let f: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func string(_ d: Date) -> String { f.string(from: d) }
    static func date(_ s: String?) -> Date? { s.flatMap { f.date(from: $0) } }
}

/// Local comment storage: SQLite in ~/Library/Application Support/ANNOT, screenshots next to it.
/// Everything is cached in memory; reads and writes are guarded by a lock, so the Chrome bridge can use it
/// from its own queue while the Comments window observes `all` on the main thread.
final class CommentStore: ObservableObject, @unchecked Sendable {
    static let shared = CommentStore()
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ANNOT", isDirectory: true)
    static let databaseURL = directory.appendingPathComponent("comments.sqlite")
    static let screenshotsURL = directory.appendingPathComponent("Screenshots", isDirectory: true)
    static func annotatedURL(_ id: String) -> URL { screenshotsURL.appendingPathComponent("\(id)-annotated.png") }

    /// All comments, newest first (main thread).
    @Published private(set) var all: [Comment] = []
    /// Called with the page key of a changed web comment, so the bridge can refresh that tab.
    var onChange: ((String) -> Void)?

    private let lock = NSLock()
    private var items: [String: Comment] = [:]
    private var db: OpaquePointer?

    private init() {
        openDatabase()
        publish(nil)
    }

    // MARK: reads

    func comment(_ id: String) -> Comment? { lock.withLock { items[id] } }

    /// Current state, unlike `all`, which reaches the main thread a moment later.
    var snapshot: [Comment] { lock.withLock { Array(items.values) } }

    func comments(forURL url: String) -> [Comment] {
        let key = Self.pageKey(url)
        return lock.withLock { items.values.filter { $0.pageKey == key } }
    }

    // MARK: writes

    @discardableResult
    func create(text: String, anchor: [String: Any], tempId: String? = nil) -> Comment {
        let project = (anchor["url"] as? String).flatMap { URL(string: $0)?.host } ?? anchor["bundle_id"] as? String
        let c = Comment(id: "cmt_" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)),
                        tempId: tempId, author: Settings.authorName, text: text, status: "open", createdAt: Date(),
                        projectID: project, anchor: anchor)
        lock.withLock {
            items[c.id] = c
            save(c)
        }
        publish(c.pageKey)
        return c
    }

    /// A comment from another Mac, found in Rome. false if it's here already.
    @discardableResult
    func addRemote(_ c: Comment) -> Bool {
        let added: Bool = lock.withLock {
            guard items[c.id] == nil else { return false }
            items[c.id] = c
            save(c)
            return true
        }
        if added { publish(c.pageKey) }
        return added
    }

    func reply(_ id: String, text: String) {
        update(id) { $0.replies.append(.init(author: Settings.authorName, text: text, createdAt: Date())) }
        Tickets.changed(id)
    }

    func setDetails(_ id: String, _ details: String) {
        update(id) { $0.details = details }
        Tickets.changed(id)
    }

    func setStatus(_ id: String, _ status: String) {
        update(id) { $0.status = status }
        Tickets.changed(id)
    }

    func setTicket(_ link: TicketLink, for id: String) {
        applyRemote(id) { c in
            guard (c.ticket?.dict as NSDictionary?) != (link.dict as NSDictionary) else { return false }
            c.ticket = link
            return true
        }
    }

    /// A change that came from Rome: saved without syncing it back. `change` returns whether anything changed.
    func applyRemote(_ id: String, _ change: (inout Comment) -> Bool) {
        let changed: Comment? = lock.withLock {
            guard var c = items[id], change(&c) else { return nil }
            items[id] = c
            save(c)
            return c
        }
        if let changed { publish(changed.pageKey) }
    }

    func attachScreenshot(_ png: Data, to id: String) {
        let file = Self.screenshotsURL.appendingPathComponent("\(id).png")
        guard (try? png.write(to: file)) != nil else { return }
        update(id) { $0.screenshot = file.path }
    }

    /// Saves the drawn marks and the screenshot with them baked in (`png` nil: all marks removed).
    func setAnnotations(_ marks: [[String: Any]], png: Data?, for id: String) {
        let file = Self.annotatedURL(id)
        try? FileManager.default.removeItem(at: file)
        let saved = png.map { (try? $0.write(to: file)) != nil } ?? false
        update(id) {
            $0.annotations = marks
            $0.annotatedScreenshot = saved ? file.path : nil
        }
    }

    func delete(_ id: String) {
        let removed: Comment? = lock.withLock {
            guard let c = items.removeValue(forKey: id) else { return nil }
            run("DELETE FROM comments WHERE id = ?", [id])
            return c
        }
        guard let removed else { return }
        for path in [removed.screenshot, removed.annotatedScreenshot].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
        publish(removed.pageKey)
    }

    private func update(_ id: String, _ change: (inout Comment) -> Void) {
        let changed: Comment? = lock.withLock {
            guard var c = items[id] else { return nil }
            change(&c)
            items[id] = c
            save(c)
            return c
        }
        if let changed { publish(changed.pageKey) }
    }

    private func publish(_ pageKey: String?) {
        let snapshot = lock.withLock { items.values.sorted { $0.createdAt > $1.createdAt } }
        DispatchQueue.main.async { self.all = snapshot }
        if let pageKey { onChange?(pageKey) }
    }

    // MARK: SQLite

    private func openDatabase() {
        let legacy = Self.adoptLegacyDirectory()
        try? FileManager.default.createDirectory(at: Self.screenshotsURL, withIntermediateDirectories: true)
        guard sqlite3_open_v2(Self.databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { return }
        run("PRAGMA journal_mode = WAL")
        run("""
            CREATE TABLE IF NOT EXISTS comments (
              id TEXT PRIMARY KEY, page_key TEXT, status TEXT, created_at TEXT, data TEXT NOT NULL)
            """)
        run("CREATE INDEX IF NOT EXISTS comments_page ON comments(page_key)")
        // Screenshot paths are stored absolute.
        if let legacy { run("UPDATE comments SET data = replace(data, ?, ?)", [legacy.path + "/", Self.directory.path + "/"]) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM comments", -1, &stmt, nil) == SQLITE_OK else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 0),
                  let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any],
                  let c = Comment(dict: obj) else { continue }
            items[c.id] = c
        }
        sqlite3_finalize(stmt)
    }

    /// Before ANNOT the app was "Klixpert Comments": its folder moves over on the first launch.
    /// Returns where it was, nil if there was nothing to move.
    private static func adoptLegacyDirectory() -> URL? {
        let fm = FileManager.default
        let legacy = directory.deletingLastPathComponent().appendingPathComponent("Klixpert Comments", isDirectory: true)
        guard !fm.fileExists(atPath: directory.path), fm.fileExists(atPath: legacy.path),
              (try? fm.moveItem(at: legacy, to: directory)) != nil else { return nil }
        return legacy
    }

    private func save(_ c: Comment) {
        guard let data = try? JSONSerialization.data(withJSONObject: c.dict, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        run("INSERT OR REPLACE INTO comments (id, page_key, status, created_at, data) VALUES (?, ?, ?, ?, ?)",
            [c.id, c.pageKey, c.status, ISO.string(c.createdAt), String(decoding: data, as: UTF8.self)])
    }

    private func run(_ sql: String, _ args: [String?] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            if let arg { sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient) } else { sqlite3_bind_null(stmt, Int32(i + 1)) }
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: page identity

    /// Same page, same comments: drop plain #anchors (keep #/ and #! routes), tracking params, trailing slash.
    static func pageKey(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return raw }
        if let f = c.fragment, !(f.hasPrefix("/") || f.hasPrefix("!")) { c.fragment = nil }
        if let q = c.queryItems {
            let kept = q.filter { !($0.name.hasPrefix("utm_") || $0.name.hasPrefix("mc_") || ["fbclid", "gclid"].contains($0.name)) }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        while c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        return c.string ?? raw
    }
}
