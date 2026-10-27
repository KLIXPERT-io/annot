import Combine
import Foundation
import Security

/// Where a comment went in Rome: a note in the project's Triage queue, later an issue.
struct TicketLink {
    var project: String // project key, e.g. FLO
    var noteID: String?
    var state: String? // new | converted | dismissed
    var issueKey: String? // once triaged into an issue
    var noteCommentID: String? // set when the note became a comment on an existing issue rather than its own issue
    var noteVersion: Int?
    var files: [String] = [] // uploaded: "screenshot", "annotated:<mtime>"
    /// Two-way status sync: the comment's status as last agreed with Rome, and Rome's status as last read.
    /// Rome changed → `remoteStatus` differs from what it reads now; we changed → the comment differs from `syncedStatus`.
    var syncedStatus: String?
    var remoteStatus: String?
    /// Details as last sent; after triage they live in one issue comment, kept up to date.
    var syncedDetails: String?
    var detailsCommentID: String?
    var detailsCommentVersion: Int?
    var shared = false // the comment's fields are in Rome's metafields, where the other Macs read them
    var error: String?

    /// The note became its own issue, so resolving the comment closes it.
    var ownsIssue: Bool { issueKey != nil && noteCommentID == nil }

    var dict: [String: Any] {
        var d: [String: Any] = ["project": project, "files": files]
        d["note_id"] = noteID
        d["state"] = state
        d["issue_key"] = issueKey
        d["note_comment_id"] = noteCommentID
        d["note_version"] = noteVersion
        d["synced_status"] = syncedStatus
        d["remote_status"] = remoteStatus
        d["synced_details"] = syncedDetails
        d["details_comment_id"] = detailsCommentID
        d["details_comment_version"] = detailsCommentVersion
        d["shared"] = shared ? true : nil
        d["error"] = error
        return d
    }

    init(project: String) { self.project = project }

    init?(dict d: [String: Any]?) {
        guard let d, let project = d["project"] as? String else { return nil }
        self.project = project
        noteID = d["note_id"] as? String
        state = d["state"] as? String
        issueKey = d["issue_key"] as? String
        noteCommentID = d["note_comment_id"] as? String
        noteVersion = d["note_version"] as? Int
        files = d["files"] as? [String] ?? []
        syncedStatus = d["synced_status"] as? String
        remoteStatus = d["remote_status"] as? String
        syncedDetails = d["synced_details"] as? String
        detailsCommentID = d["details_comment_id"] as? String
        detailsCommentVersion = d["details_comment_version"] as? Int
        shared = d["shared"] as? Bool ?? false
        error = d["error"] as? String
    }

    /// "FLO-12", "FLO · Triage", "FLO · Dismissed".
    var label: String {
        if let issueKey { return issueKey }
        switch state {
        case "dismissed": return "\(project) · Dismissed"
        case "converted": return "\(project) · Triaged"
        default: return "\(project) · Triage"
        }
    }
}

/// The API token, per user, in the login Keychain.
enum Keychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "io.klixpert.annot.rome",
                                               kSecAttrAccount as String: "api-token"]

    static var token: String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String?) {
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// The Rome server the user entered in Settings › Account; "" until then.
enum Rome {
    static var server: String { normalize(UserDefaults.standard.string(forKey: "romeServer") ?? "") }
    static var isConfigured: Bool { isValid(server) }

    /// "rome.example.com/" → "https://rome.example.com".
    static func normalize(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func isValid(_ server: String) -> Bool {
        guard let u = URL(string: normalize(server)), let host = u.host, !host.isEmpty else { return false }
        return u.scheme == "https" || u.scheme == "http"
    }

    static var host: String { URL(string: server)?.host ?? server }

    /// A page of Rome's web app: "/settings/tokens", "/p/KLX/triage".
    static func web(_ path: String) -> URL { URL(string: server + path)! }

    /// The 8 characters after rome_pat_ / rome_sat_ that GET /me/tokens lists as `prefix`.
    static func prefix(of token: String) -> String? {
        let parts = token.split(separator: "_", maxSplits: 2)
        return parts.count == 3 ? String(parts[2].prefix(8)) : nil
    }

    /// Why a pasted string can't be used, before asking the server.
    static func problem(with token: String) -> String? {
        if token.hasPrefix("rome_adm_") { return "That's an Org Admin token, which can't send comments. Create a personal one (rome_pat_…)" }
        if !token.hasPrefix("rome_pat_") && !token.hasPrefix("rome_sat_") { return "That's not a Rome token. Personal tokens start with rome_pat_" }
        return token.contains(where: \.isWhitespace) ? "The token can't contain spaces. Copy it again from Rome" : nil
    }
}

/// RFC 9457 problem from the API; branch on `code`, show `message`.
struct RomeError: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Minimal Rome REST client (JSON in and out, docs/agents.md §4).
struct RomeClient {
    let api: String // https://host:port/api/v1
    let token: String

    init(server: String, token: String) {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        api = s.hasSuffix("/api/v1") ? s : s + "/api/v1"
        self.token = token
    }

    func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: api + path) else { throw RomeError(status: 0, code: "bad-url", message: "Invalid server address") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if method != "GET" { r.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key") } // same key on retries

        for attempt in 1...4 {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: r)
            } catch {
                throw RomeError(status: 0, code: "unreachable", message: "Can't reach \(url.host ?? "the server"). Check your internet connection")
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(status) { return json }
            if status == 429, attempt < 4 { // 10/s per token, bursts of 50
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
                try await Task.sleep(for: .seconds(min(wait, 10)))
                continue
            }
            let code = json["code"] as? String ?? "http-\(status)"
            let message = status == 401 ? code == "token-revoked" ? "The token was revoked in Rome"
                : code == "token-expired" ? "The token has expired" : "Rome doesn't accept this token. Copy it again or create a new one"
                : json["detail"] as? String ?? json["title"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw RomeError(status: status, code: code, message: message)
        }
        throw RomeError(status: 429, code: "rate-limited", message: "Rate limited")
    }

    /// All pages of a list endpoint.
    func list(_ path: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = [], cursor: String?
        repeat {
            let sep = path.contains("?") ? "&" : "?"
            let page = try await call("GET", path + sep + "limit=200" + (cursor.map { "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? ""))
            items += page["items"] as? [[String: Any]] ?? []
            cursor = page["next_cursor"] as? String
        } while cursor != nil
        return items
    }

    /// Two-step upload: `start` returns {attachment, upload}; PUT the bytes, then complete.
    func upload(_ file: URL, start: String, complete: (String) -> String) async throws {
        let data = try Data(contentsOf: file)
        let res = try await call("POST", start, body: ["filename": file.lastPathComponent, "mime": "image/png", "size": data.count])
        guard let id = (res["attachment"] as? [String: Any])?["id"] as? String, let up = res["upload"] as? [String: Any],
              let url = URL(string: up["url"] as? String ?? "") else { throw RomeError(status: 0, code: "bad-response", message: "Unexpected upload answer") }
        var r = URLRequest(url: url, timeoutInterval: 120)
        r.httpMethod = up["method"] as? String ?? "PUT"
        for (k, v) in up["headers"] as? [String: Any] ?? [:] { r.setValue("\(v)", forHTTPHeaderField: k) }
        let (_, resp) = try await URLSession.shared.upload(for: r, from: data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RomeError(status: status, code: "upload-failed", message: "Screenshot upload failed (\(status))") }
        _ = try await call("POST", complete(id))
    }
}

/// Keeps comments and Rome in sync. Each comment becomes an annotation note in the chosen project's Triage queue,
/// with its screenshots. From then on, both ways: replies ⇄ the note's comments (while in Triage) or the issue's
/// comments (once triaged), Resolve/Reopen ⇄ dismiss/restore or Done/To Do. Rome's changes arrive over the WebSocket.
/// Comments stay local when no project is chosen.
@MainActor
final class Tickets: ObservableObject {
    static let shared = Tickets()

    struct Project: Identifiable, Hashable {
        let key: String
        let name: String
        let role: String? // yours in the project: "Admin", "Member"…
        var domains: [String] = [] // the sites it's about, set in Rome: "acme.com", "*.acme.com"
        var people: [Person] = [] // who can be @mentioned: everyone who can browse the project
        var id: String { key }
    }

    /// Who the token belongs to (GET /me).
    struct Account {
        let name: String
        let handle: String
        let email: String
        let avatar: URL?
        let orgAdmin: Bool
        let service: Bool // a service account's token (rome_sat_)
    }

    /// The token's own record (GET /me/tokens, people only); never the secret.
    struct TokenInfo {
        let id: String
        let name: String
        let prefix: String
        let created: Date?
        let lastUsed: Date?
        let expires: Date?
    }

    struct Person: Identifiable, Hashable {
        let handle: String
        let name: String
        let agent: Bool // a service account
        var id: String { handle }
    }

    @Published private(set) var account: Account?
    @Published private(set) var tokenInfo: TokenInfo?
    @Published private(set) var projects: [Project] = [] { didSet { Self.choices.set(projects) } }
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var live = false // WebSocket connected
    @Published private(set) var rejected = false // Rome answered 401 for the saved token: it needs a new one

    /// The projects the comment boxes offer (empty when not connected). The capture code isn't on the main actor.
    nonisolated static let choices = ProjectChoices()

    private var token = Keychain.token
    private var sending: Set<String> = []
    private var again: Set<String> = [] // changed while syncing: run once more
    private var scheduled: Set<String> = []
    private let socket = RomeSocket()
    private var bag = Set<AnyCancellable>()

    var hasToken: Bool { token != nil }
    /// rome_pat_8no3PJma…: the part Rome itself shows to tell tokens apart.
    var maskedToken: String? { token.map { String($0.prefix(17)) + "…" } }
    func dismissError() { error = nil }
    private var client: RomeClient? {
        guard let token, Rome.isConfigured else { return nil }
        return RomeClient(server: Rome.server, token: token)
    }

    private init() {
        socket.onEvent = { [weak self] in self?.handle($0) }
        socket.onResync = { [weak self] in Task { await self?.syncAll(); await self?.importAll() } }
        socket.onLive = { [weak self] in self?.live = $0 }
        socket.onAuthFailed = { [weak self] in self?.reject("The token was rejected. It may have been revoked or have expired") }
        Settings.shared.$ticketsProject.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSocket() }.store(in: &bag)
    }

    // MARK: account

    /// Checks a server and token with GET /me, then keeps them (the token in the Keychain). Without a new token it
    /// tries the saved one. One that fails leaves the current server and token in place.
    @discardableResult
    func connect(server: String, token new: String?) async -> Bool {
        let s = Rome.normalize(server)
        guard Rome.isValid(s) else { error = "Enter your Rome server's address, like https://rome.example.com"; return false }
        guard let t = new.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).flatMap({ $0.isEmpty ? nil : $0 }) ?? token
        else { return false }
        if let problem = Rome.problem(with: t) { error = problem; return false }
        busy = true
        defer { busy = false }
        let c = RomeClient(server: s, token: t), me: [String: Any]
        do {
            me = try await c.call("GET", "/me")
        } catch {
            self.error = error.localizedDescription
            return false
        }
        Settings.shared.romeServer = s
        Keychain.setToken(t)
        token = t
        rejected = false
        do { // connected from here on; projects that don't load show as an error, and the next refresh retries
            try await load(me, c)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        updateSocket()
        return true
    }

    /// Forgets the token on this Mac. With `revoke`, Rome stops accepting it too (a token may revoke itself).
    func disconnect(revoke: Bool = false) async {
        if revoke, let client, let id = tokenInfo?.id {
            do {
                _ = try await client.call("POST", "/me/tokens/\(id)/revoke")
            } catch {
                self.error = "Not revoked: \(error.localizedDescription)"
                return
            }
        }
        Keychain.setToken(nil)
        token = nil
        account = nil
        tokenInfo = nil
        rejected = false
        projects = []
        error = nil
        Settings.shared.ticketsProject = nil
        updateSocket()
    }

    /// Who the token belongs to and which projects take notes, then goes live. Quiet at launch; errors show in Settings.
    func refresh() async {
        guard let client, !busy, !rejected else { return }
        busy = true
        defer { busy = false }
        do {
            try await load(try await client.call("GET", "/me"), client)
            error = nil
            rejected = false
            updateSocket()
        } catch let e as RomeError where e.status == 401 {
            reject(e.message)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var loadedAt = Date.distantPast

    /// Comment mode is starting: projects (and their domains) older than 10 minutes load again for the next comment.
    func refreshIfStale() {
        if Date().timeIntervalSince(loadedAt) > 600 { Task { await refresh() } }
    }

    /// The saved token stopped working: keep it until a new one replaces it, but stop syncing with it.
    private func reject(_ message: String) {
        rejected = true
        account = nil
        tokenInfo = nil
        projects = []
        error = message
        updateSocket()
    }

    private var handle = ""

    private func load(_ me: [String: Any], _ c: RomeClient) async throws {
        setUser(me)
        tokenInfo = account?.service == false ? await loadTokenInfo(c) : nil
        try await loadProjects(c)
    }

    private func setUser(_ me: [String: Any]) {
        let name = me["name"] as? String ?? ""
        handle = me["handle"] as? String ?? ""
        account = Account(name: name, handle: handle, email: me["email"] as? String ?? "",
                          avatar: URL(string: me["avatar_url"] as? String ?? ""),
                          orgAdmin: me["org_role"] as? String == "admin", service: me["kind"] as? String == "service")
        if !name.isEmpty, Settings.shared.author != name { Settings.shared.author = name } // comments carry your Rome name
    }

    /// This token among GET /me/tokens, by its prefix. Only for showing it, so failures just hide it.
    private func loadTokenInfo(_ c: RomeClient) async -> TokenInfo? {
        guard let prefix = token.flatMap(Rome.prefix(of:)),
              let items = try? await c.call("GET", "/me/tokens")["items"] as? [[String: Any]],
              let t = items.first(where: { $0["prefix"] as? String == prefix && $0["state"] as? String == "active" }),
              let id = t["id"] as? String else { return nil }
        return TokenInfo(id: id, name: t["name"] as? String ?? "", prefix: prefix, created: ISO.date(t["created_at"] as? String),
                         lastUsed: ISO.date(t["last_used_at"] as? String), expires: ISO.date(t["expires_at"] as? String))
    }

    /// The projects, then each one's people for @mentions (a project whose people don't load just offers none).
    private func loadProjects(_ c: RomeClient) async throws {
        var list: [Project] = try await c.list("/projects").compactMap { p in
            let viewer = p["viewer"] as? [String: Any]
            guard p["archived"] as? Bool != true, let key = p["key"] as? String,
                  (viewer?["permissions"] as? [String])?.contains("CREATE_NOTE") ?? true else { return nil }
            return Project(key: key, name: p["name"] as? String ?? key, role: (viewer?["role"] as? [String: Any])?["name"] as? String,
                           domains: (p["domains"] as? [String] ?? []).map { $0.lowercased() })
        }
        loadedAt = Date()
        projects = list
        for i in list.indices {
            guard let page = try? await c.call("GET", "/principals?project=\(list[i].key)&limit=200") else { continue }
            list[i].people = (page["items"] as? [[String: Any]] ?? []).compactMap { p in
                guard let h = p["handle"] as? String, !h.isEmpty, h != handle else { return nil }
                return Person(handle: h, name: p["name"] as? String ?? h, agent: p["kind"] as? String == "service")
            }
        }
        projects = list
        Task { await importAll() }
    }

    // MARK: live updates

    /// One topic per project: comments from the other Macs can come from any of them.
    private func updateSocket() {
        var keys = Set(CommentStore.shared.snapshot.compactMap { $0.ticket?.noteID != nil ? $0.ticket?.project : nil })
        keys.formUnion(projects.map(\.key))
        if let p = Settings.shared.ticketsProject { keys.insert(p) }
        socket.configure(server: Rome.server, token: account != nil ? token : nil,
                         topics: Set(keys.map { "project:" + $0 }))
    }

    /// An event names a note or an issue; re-sync the comments linked to it.
    private func handle(_ e: [String: Any]) {
        if (e["type"] as? String)?.hasPrefix("project.") == true { Task { await refresh() } } // e.g. its domains changed
        let data = e["data"] as? [String: Any] ?? [:], entity = e["entity"] as? [String: Any] ?? [:]
        func key(_ o: Any?) -> String? { (o as? [String: Any])?["key"] as? String }
        var notes = Set<String>(), issues = Set<String>()
        if entity["type"] as? String == "note", let id = entity["id"] as? String { notes.insert(id) }
        if let n = data["note"] as? [String: Any] {
            if let id = n["id"] as? String { notes.insert(id) }
            if let k = key(n["issue"]) { issues.insert(k) }
        }
        if let id = (data["comment"] as? [String: Any])?["note_id"] as? String ?? data["note_id"] as? String { notes.insert(id) } // note_comment.*
        for k in [entity["key"] as? String, key(data["issue"]), key((data["comment"] as? [String: Any])?["issue"])] {
            if let k { issues.insert(k) }
        }
        var known = Set<String>()
        for c in CommentStore.shared.snapshot {
            guard let t = c.ticket else { continue }
            if let n = t.noteID { known.insert(n) }
            if t.noteID.map(notes.contains) == true || t.issueKey.map(issues.contains) == true { scheduleSync(c.id) }
        }
        // New here: a comment from another Mac, or one whose closed issue was reopened.
        let closed = Self.closed
        for n in notes.subtracting(known).union(issues.compactMap { closed[$0] }) { Task { await importNote(id: n) } }
    }

    /// Coalesces a burst of events (e.g. a transition with a comment) into one sync.
    private func scheduleSync(_ id: String) {
        guard scheduled.insert(id).inserted else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            scheduled.remove(id)
            await sync(id)
        }
    }

    // MARK: comments from the other Macs

    private var importing: Set<String> = [] // note IDs

    /// Issue key → note ID of ANNOT comments whose issue was done when we found them: not fetched again on each
    /// import, only when the issue changes (it may be reopened).
    private static var closed: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "romeClosed") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "romeClosed") }
    }

    /// Every open ANNOT comment in your projects, from any Mac: notes in Triage and the issues they became.
    /// After loading the projects and after missed events; the WebSocket brings the new ones in between.
    /// Ours sent before ANNOT shared its comments get their metafields first, so the other Macs find them too.
    func importAll() async {
        guard let client else { return }
        for c in CommentStore.shared.snapshot where !c.remote && c.ticket?.noteID != nil && c.ticket?.shared == false {
            await sync(c.id)
        }
        for p in projects {
            for state in ["new", "converted"] {
                guard let notes = try? await client.list("/notes?project=\(p.key)&state=\(state)") else { continue }
                for n in notes { await importNote(n, client) }
            }
        }
    }

    private func importNote(id: String) async {
        guard let client, let n = try? await client.call("GET", "/notes/\(id)") else { return }
        await importNote(n, client)
    }

    /// One note, if it's an ANNOT comment this Mac doesn't have and it's still open: the comment comes from its
    /// metafields (the issue's, once triaged), then a sync brings its replies and screenshots.
    private func importNote(_ n: [String: Any], _ client: RomeClient) async {
        var fields = n["metafields"] as? [String: String] ?? [:]
        guard let id = fields["annot.id"], let noteID = n["id"] as? String, CommentStore.shared.comment(id) == nil,
              n["comment_id"] == nil, // merged into another issue: not a comment of its own anymore
              importing.insert(noteID).inserted else { return }
        defer { importing.remove(noteID) }
        var link = TicketLink(project: (n["project"] as? [String: Any])?["key"] as? String ?? "")
        apply(n, to: &link)
        switch link.state {
        case "new":
            break
        case "converted":
            guard let key = link.issueKey, Self.closed[key] == nil || Self.closed[key] == noteID else { return }
            guard let issue = try? await client.call("GET", "/issues/\(key)") else { return }
            guard (issue["status"] as? [String: Any])?["category"] as? String != "done" else { Self.closed[key] = noteID; return }
            Self.closed[key] = nil
            fields.merge(issue["metafields"] as? [String: String] ?? [:]) { $1 }
        default:
            return
        }
        guard let anchorJSON = fields["annot.anchor"], let anchor = try? JSONSerialization.jsonObject(with: Data(anchorJSON.utf8)) as? [String: Any]
        else { return } // sent before ANNOT shared its comments; its author's ANNOT adds the fields on its next sync
        let author = (n["author"] as? [String: Any])?["name"] as? String ?? ""
        var c = Comment(id: id, tempId: nil, author: fields["annot.author"] ?? author, text: fields["annot.text"] ?? n["title"] as? String ?? "",
                        status: "open", createdAt: ISO.date(fields["annot.created"]) ?? ISO.date(n["created_at"] as? String) ?? Date(),
                        projectID: (anchor["url"] as? String).flatMap { URL(string: $0)?.host } ?? anchor["bundle_id"] as? String, anchor: anchor)
        c.title = fields["annot.title"] ?? ""
        c.details = fields["annot.details"] ?? ""
        c.remote = true
        link.shared = true
        link.syncedStatus = "open"
        link.remoteStatus = "open"
        link.syncedDetails = c.details
        c.ticket = link
        guard CommentStore.shared.addRemote(c) else { return }
        updateSocket()
        await sync(id)
    }

    /// After missed events: re-read every linked comment.
    func syncAll() async {
        for c in CommentStore.shared.snapshot where c.ticket?.noteID != nil { await sync(c.id) }
    }

    // MARK: comments

    /// A new comment: send it to the project picked in the comment box (nil keeps it local). Safe from any thread.
    nonisolated static func autoSend(_ id: String, to project: String?) {
        guard let project else { return }
        Task { @MainActor in await shared.sync(id, to: project, announce: true) }
    }

    /// A comment changed here (reply, resolve, drawing): push it if it's linked. Safe from any thread.
    nonisolated static func changed(_ id: String) {
        Task { @MainActor in await shared.sync(id) }
    }

    /// Pulls Rome's side of one comment, then pushes ours. The first call creates the note (Rome dedupes by
    /// external_id). One run per comment at a time; changes during a run trigger one more.
    func sync(_ id: String, to project: String? = nil, announce: Bool = false) async {
        guard let client, let c = CommentStore.shared.comment(id) else { return }
        guard var link = c.ticket ?? project.map(TicketLink.init(project:)) else { return }
        guard !sending.contains(id) else { again.insert(id); return }
        sending.insert(id)
        defer {
            sending.remove(id)
            if again.remove(id) != nil { Task { await sync(id) } }
        }
        if link.noteID == nil, let project { link.project = project }
        link.error = nil
        do {
            if link.noteID == nil {
                let res = try await client.call("POST", "/projects/\(link.project)/notes", body: c.notePayload)
                apply(res, to: &link)
                link.shared = true // the payload carries the metafields
                link.syncedStatus = c.status
                link.remoteStatus = "open"
                link.syncedDetails = c.details
                CommentStore.shared.setTicket(link, for: id)
                updateSocket()
                if announce { HUD.show("Sent to \(link.project) Triage") }
            } else {
                let project = link.project
                try await pull(client, id, &link)
                if link.project != project { updateSocket() } // moved by a triager
            }
            try await pushFiles(client, id, &link)
            try await pushReplies(client, id, &link)
            try await pushDetails(client, id, &link)
            try await pushStatus(client, id, &link)
            try await pushFields(client, id, &link)
        } catch let e as RomeError where e.status == 404 && c.remote {
            CommentStore.shared.delete(id) // deleted in Rome (a dismissed note goes after 30 days)
            return
        } catch {
            link.error = error.localizedDescription
            if announce { HUD.show("Not sent to \(link.project): \(error.localizedDescription)", isError: true, seconds: 4) }
        }
        CommentStore.shared.setTicket(link, for: id)
    }

    /// Rome → comment: the note's state, the issue's status and comments. Where both changed, Rome wins.
    private func pull(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let noteID = link.noteID else { return }
        let note = try await client.call("GET", "/notes/\(noteID)")
        apply(note, to: &link)
        var fields = note["metafields"] as? [String: String] ?? [:]
        var remote: String? = link.state == "dismissed" ? "resolved" : link.state == "new" ? "open" : nil
        // The replies made in Triage; read-only once triaged, so they stay there
        if note["comment_count"] as? Int ?? 0 > 0 || CommentStore.shared.comment(id)?.replies.contains(where: { $0.remoteID?.hasPrefix("ncm_") == true }) == true {
            merge(try await client.list("/notes/\(noteID)/comments"), into: id, skipping: [])
        }
        if link.state == "converted", let key = link.issueKey {
            if link.ownsIssue {
                let issue = try await client.call("GET", "/issues/\(key)")
                remote = (issue["status"] as? [String: Any])?["category"] as? String == "done" ? "resolved" : "open"
                fields = issue["metafields"] as? [String: String] ?? fields
            }
            let comments = try await client.list("/issues/\(key)/comments")
            if link.detailsCommentID != nil { // deleted in Rome: post a new one on the next change
                let dc = comments.first { $0["id"] as? String == link.detailsCommentID }
                if let dc, !(dc["deleted_at"] is String) { link.detailsCommentVersion = dc["version"] as? Int ?? link.detailsCommentVersion }
                else { link.detailsCommentID = nil; link.detailsCommentVersion = nil }
            }
            merge(comments, into: id, skipping: [link.noteCommentID, link.detailsCommentID, fields["annot.details_comment"]].compactMap { $0 })
        }
        merge(fields: fields, into: id)
        if CommentStore.shared.comment(id)?.remote == true { try await pullFiles(client, id, &link, note: note) }
        if let remote, remote != link.remoteStatus {
            link.remoteStatus = remote
            link.syncedStatus = remote
            CommentStore.shared.applyRemote(id) { c in
                guard c.status != remote else { return false }
                c.status = remote
                return true
            }
        }
    }

    /// Metafields → replies made in Triage before notes took comments, and for a comment from another Mac its details.
    private func merge(fields: [String: String], into id: String) {
        CommentStore.shared.applyRemote(id) { c in
            var changed = false
            for (key, value) in fields where key.hasPrefix("annot.reply.") && !c.replies.contains(where: { $0.remoteID == key }) {
                guard let r = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String] else { continue }
                let text = r["text"] ?? ""
                if let i = c.replies.firstIndex(where: { $0.remoteID == nil && $0.text == text && $0.field.key == key }) {
                    c.replies[i].remoteID = key // ours, racing the PATCH answer
                } else {
                    c.replies.append(.init(author: r["author"] ?? "", text: text, createdAt: ISO.date(r["at"]) ?? Date(), remoteID: key))
                }
                changed = true
            }
            if changed { c.replies.sort { $0.createdAt < $1.createdAt } }
            if c.remote, let details = fields["annot.details"] ?? (fields["annot.id"] != nil ? "" : nil), details != c.details {
                c.details = details
                changed = true
            }
            return changed
        }
    }

    /// The screenshots of a comment from another Mac, from the note (in Triage) or the issue: the newest
    /// <id>.png and <id>-annotated.png, each downloaded once (link.files has "dl:<attachment ID>").
    private func pullFiles(_ client: RomeClient, _ id: String, _ link: inout TicketLink, note: [String: Any]) async throws {
        var files: [(id: String, name: String, download: String)] = []
        if link.state == "new", let noteID = link.noteID {
            for a in note["attachments"] as? [[String: Any]] ?? [] where a["state"] as? String == "ready" {
                if let aid = a["id"] as? String { files.append((aid, a["filename"] as? String ?? "", "/notes/\(noteID)/attachments/\(aid)/download")) }
            }
        } else if link.state == "converted", link.ownsIssue, let key = link.issueKey {
            for a in try await client.list("/issues/\(key)/attachments") where a["state"] as? String ?? "ready" == "ready" {
                if let aid = a["id"] as? String { files.append((aid, a["filename"] as? String ?? "", "/attachments/\(aid)/download")) }
            }
        }
        for (name, annotated) in [("\(id).png", false), ("\(id)-annotated.png", true)] {
            guard let f = files.last(where: { $0.name == name }), !link.files.contains("dl:" + f.id),
                  let url = URL(string: try await client.call("GET", f.download)["url"] as? String ?? "") else { continue }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let file = annotated ? CommentStore.annotatedURL(id) : CommentStore.screenshotsURL.appendingPathComponent(name)
            try data.write(to: file)
            CommentStore.shared.applyRemote(id) { c in
                if annotated { c.annotatedScreenshot = file.path } else { c.screenshot = file.path }
                return true
            }
            link.files.append("dl:" + f.id)
            CommentStore.shared.setTicket(link, for: id)
        }
    }

    /// Note or issue comments → replies. Ours come back with the ID we stored (or, racing the POST answer, the same text).
    private func merge(_ remote: [[String: Any]], into id: String, skipping own: [String]) {
        CommentStore.shared.applyRemote(id) { c in
            var changed = false
            for rc in remote {
                guard let rid = rc["id"] as? String, !own.contains(rid) else { continue }
                let body = rc["body"] as? String ?? "", deleted = rc["deleted_at"] is String
                if let i = c.replies.firstIndex(where: { $0.remoteID == rid }) {
                    if deleted { c.replies.remove(at: i); changed = true }
                    else if c.replies[i].text != body { c.replies[i].text = body; changed = true }
                } else if deleted {
                    continue
                } else if let i = c.replies.firstIndex(where: { $0.remoteID == nil && $0.text == body }) {
                    c.replies[i].remoteID = rid
                    changed = true
                } else {
                    let author = (rc["author"] as? [String: Any])?["name"] as? String ?? "Rome"
                    c.replies.append(.init(author: author, text: body, createdAt: ISO.date(rc["created_at"] as? String) ?? Date(), remoteID: rid))
                    changed = true
                }
            }
            if changed { c.replies.sort { $0.createdAt < $1.createdAt } }
            return changed
        }
    }

    /// Screenshots it doesn't have yet: to the note while it's in Triage, to the issue after.
    private func pushFiles(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let c = CommentStore.shared.comment(id), !c.remote, let noteID = link.noteID else { return }
        do {
            for (tag, path) in pendingFiles(c, link) {
                let file = URL(fileURLWithPath: path)
                if link.state == "new" {
                    try await client.upload(file, start: "/notes/\(noteID)/attachments") { "/notes/\(noteID)/attachments/\($0)/complete" }
                } else if let key = link.issueKey {
                    try await client.upload(file, start: "/issues/\(key)/attachments") { "/attachments/\($0)/complete" }
                } else {
                    return // dismissed
                }
                link.files.append(tag)
                CommentStore.shared.setTicket(link, for: id)
            }
        } catch let e as RomeError where e.code == "feature-disabled" {
            link.error = "Without screenshots: file storage is off on the server" // the rest still syncs
        }
    }

    /// Replies → Rome: note comments while it's in Triage, issue comments after. Anyone who can comment may reply.
    private func pushReplies(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let c = CommentStore.shared.comment(id), let noteID = link.noteID else { return }
        var pending = c.replies.filter { $0.remoteID == nil }
        if link.state == "new" {
            do {
                while let r = pending.first {
                    let res = try await client.call("POST", "/notes/\(noteID)/comments", body: ["body": r.text])
                    if let rid = res["id"] as? String { setRemoteID(rid, of: r, in: id) }
                    pending.removeFirst()
                }
            } catch let e as RomeError where e.code == "state-conflict" {
                apply(try await client.call("GET", "/notes/\(noteID)"), to: &link) // triaged meanwhile: the rest goes to the issue
            }
        }
        if link.state == "converted", let key = link.issueKey {
            for r in pending {
                let res = try await client.call("POST", "/issues/\(key)/comments", body: ["body": r.text])
                if let rid = res["id"] as? String { setRemoteID(rid, of: r, in: id) }
            }
        }
    }

    /// Details changed → Rome. In Triage: the note body and its metafield. After triage: one "Details" comment on
    /// the issue, created once and then edited.
    private func pushDetails(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let c = CommentStore.shared.comment(id), !c.remote, c.details != (link.syncedDetails ?? ""), let noteID = link.noteID else { return }
        if link.state == "new" {
            try await patchNote(client, noteID, &link, ["body": c.noteBody, "metafields": ["annot.details": Comment.field(c.details) ?? NSNull()] as [String: Any]])
            link.syncedDetails = c.details
            return
        }
        guard link.state == "converted", let key = link.issueKey else { return }
        let body = c.details.isEmpty ? "**Details** (removed in ANNOT)" : "**Details**\n\n" + c.details
        if let cid = link.detailsCommentID {
            let res = try await client.call("PATCH", "/comments/\(cid)", body: ["body": body, "version": link.detailsCommentVersion ?? 1])
            link.detailsCommentVersion = res["version"] as? Int ?? link.detailsCommentVersion
        } else if !c.details.isEmpty {
            let res = try await client.call("POST", "/issues/\(key)/comments", body: ["body": body])
            link.detailsCommentID = res["id"] as? String
            link.detailsCommentVersion = res["version"] as? Int
        }
        link.syncedDetails = c.details
        if link.ownsIssue { // for the other Macs, which don't show that comment as a reply
            try? await patchIssue(client, key, fields: ["annot.details": Comment.field(c.details) ?? NSNull(),
                                                        "annot.details_comment": link.detailsCommentID ?? NSNull()])
        }
    }

    /// Patches a note in Triage at the version it has now.
    private func patchNote(_ client: RomeClient, _ noteID: String, _ link: inout TicketLink, _ patch: [String: Any]) async throws {
        var patch = patch
        do {
            patch["version"] = link.noteVersion ?? 1
            apply(try await client.call("PATCH", "/notes/\(noteID)", body: patch), to: &link)
        } catch let e as RomeError where e.code == "version-conflict" {
            apply(try await client.call("GET", "/notes/\(noteID)"), to: &link)
            patch["version"] = link.noteVersion ?? 1
            apply(try await client.call("PATCH", "/notes/\(noteID)", body: patch), to: &link)
        }
    }

    /// Merges metafields into an issue (null removes one), at the version it has now.
    private func patchIssue(_ client: RomeClient, _ key: String, fields: [String: Any]) async throws {
        for attempt in 1...2 {
            let version = try await client.call("GET", "/issues/\(key)")["version"] as? Int ?? 1
            do {
                _ = try await client.call("PATCH", "/issues/\(key)", body: ["version": version, "metafields": fields])
                return
            } catch let e as RomeError where e.code == "version-conflict" && attempt == 1 {
                continue
            }
        }
    }

    /// Our comments sent before ANNOT shared them: their fields, and the replies that only went into the note body,
    /// into the note's metafields (or the issue's once triaged), so the other Macs show them too. Once per comment;
    /// where Rome doesn't let us, it stays as it is.
    private func pushFields(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard !link.shared, let c = CommentStore.shared.comment(id), !c.remote, let noteID = link.noteID else { return }
        let old = c.replies.filter { $0.remoteID == "note" }
        var fields: [String: Any] = c.fields
        for r in old { fields[r.field.key] = r.field.value }
        do {
            switch link.state {
            case "new":
                try await patchNote(client, noteID, &link, ["metafields": fields])
            case "converted" where link.ownsIssue:
                try await patchIssue(client, link.issueKey!, fields: fields)
            default:
                break // dismissed, or merged into another issue: not shown on the other Macs
            }
        } catch let e as RomeError where [403, 409].contains(e.status) {
            bridgeLog.notice("fields of \(id, privacy: .public) not shared: \(e.message, privacy: .public)")
        }
        for r in old { setRemoteID(r.field.key, of: r, in: id, was: "note") }
        link.shared = true
    }

    /// Resolve/Reopen → Rome: dismiss/restore the note in Triage; Done/To Do on the issue it became.
    /// A note merged into an existing issue as a comment doesn't own that issue, so its status stays.
    private func pushStatus(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let local = CommentStore.shared.comment(id)?.status, local != link.syncedStatus, let noteID = link.noteID else { return }
        switch link.state {
        case "new" where local == "resolved":
            apply(try await client.call("POST", "/notes/\(noteID)/dismiss", body: ["reason": "Resolved in ANNOT"]), to: &link)
            link.remoteStatus = local
        case "dismissed" where local == "open":
            apply(try await client.call("POST", "/notes/\(noteID)/restore"), to: &link)
            link.remoteStatus = local
        case "converted" where link.ownsIssue:
            if try await transition(client, link.issueKey!, done: local == "resolved") {
                link.remoteStatus = local
            } else {
                link.error = "\(link.issueKey!) waits for approval in Rome"
            }
        default:
            break
        }
        link.syncedStatus = local
    }

    /// Moves the issue to a Done status, or back to To Do (else In Progress). false: the transition waits for approval.
    private func transition(_ client: RomeClient, _ key: String, done: Bool) async throws -> Bool {
        let options = try await client.call("GET", "/issues/\(key)/transitions")["transitions"] as? [[String: Any]] ?? []
        func category(_ t: [String: Any]) -> String? { (t["to"] as? [String: Any])?["category"] as? String }
        let pick = done ? options.first { category($0) == "done" }
            : options.first { category($0) == "todo" } ?? options.first { category($0) == "in_progress" }
        guard let tid = pick?["id"] as? String else {
            throw RomeError(status: 0, code: "no-transition", message: "\(key) can't be \(done ? "closed" : "reopened") from its current status")
        }
        let res = try await client.call("POST", "/issues/\(key)/transitions", body: ["transition_id": tid])
        return res["outcome"] as? String != "pending_approval"
    }

    private func setRemoteID(_ rid: String, of reply: Comment.Reply, in id: String, was: String? = nil) {
        CommentStore.shared.applyRemote(id) { c in
            guard let i = c.replies.firstIndex(where: { $0.remoteID == was && $0.createdAt == reply.createdAt && $0.text == reply.text }) else { return false }
            c.replies[i].remoteID = rid
            return true
        }
    }

    /// A note, or an answer that wraps one ({note, ...}).
    private func apply(_ res: [String: Any], to link: inout TicketLink) {
        let note = res["note"] as? [String: Any] ?? res
        link.noteID = note["id"] as? String ?? link.noteID
        link.state = note["state"] as? String ?? link.state
        link.noteVersion = note["version"] as? Int ?? link.noteVersion
        link.issueKey = (note["issue"] as? [String: Any])?["key"] as? String ?? link.issueKey
        if note["state"] != nil { link.noteCommentID = note["comment_id"] as? String }
        if let key = (note["project"] as? [String: Any])?["key"] as? String { link.project = key } // a triager may move it
    }

    /// Screenshots not uploaded yet. A redrawn annotation counts as new (keyed by modification time).
    private func pendingFiles(_ c: Comment, _ link: TicketLink) -> [(String, String)] {
        var out: [(String, String)] = []
        if let s = c.screenshot, !link.files.contains("screenshot") { out.append(("screenshot", s)) }
        if let a = c.annotatedScreenshot,
           let mtime = (try? FileManager.default.attributesOfItem(atPath: a)[.modificationDate] as? Date)?.timeIntervalSince1970 {
            let tag = "annotated:\(Int(mtime))"
            if !link.files.contains(tag) { out.append((tag, a)) }
        }
        return out
    }
}

/// Thread-safe copy of `Tickets.projects` for the comment boxes.
final class ProjectChoices: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Tickets.Project] = []

    var all: [Tickets.Project] { lock.withLock { items } }
    func set(_ projects: [Tickets.Project]) { lock.withLock { items = projects } }

    /// Who can be @mentioned in a comment for `project`; everyone in any project when it's not known.
    func people(in project: String?) -> [Tickets.Person] {
        let all = self.all
        if let p = all.first(where: { $0.key == project }) { return p.people }
        var seen = Set<String>()
        return all.flatMap(\.people).filter { seen.insert($0.handle).inserted }
    }

    /// Where a comment is made, for picking its project: the page's host ("shop.acme.com"), or "app:<bundle ID>"
    /// outside the browser. nil when there's nothing to tell places apart by.
    static func place(url: String?, bundleID: String = "") -> String? {
        if let u = url.flatMap(URLComponents.init(string:)), ["http", "https"].contains(u.scheme), let host = u.host, !host.isEmpty {
            return host.lowercased()
        }
        return bundleID.isEmpty ? nil : "app:" + bundleID
    }

    /// The project whose domains cover `place`: a domain itself (or www. in front of it) before *.wildcards,
    /// the longest wildcard first. A wildcard covers the bare domain too.
    func match(_ place: String) -> (key: String, rule: String)? {
        guard !place.hasPrefix("app:") else { return nil }
        let bare = place.hasPrefix("www.") ? String(place.dropFirst(4)) : place
        var best: (key: String, rule: String, score: Int)?
        for p in all {
            for rule in p.domains {
                let score: Int
                if rule == place || rule == bare { score = 1000 + rule.count }
                else if rule.hasPrefix("*."), bare == rule.dropFirst(2) || place.hasSuffix(rule.dropFirst(1)) { score = rule.count }
                else { continue }
                if score > best?.score ?? 0 { best = (p.key, rule, score) }
            }
        }
        return best.map { ($0.key, $0.rule) }
    }

    /// Where a new comment at `place` goes: the project whose domains cover it, else the last pick there, else the
    /// default. `why` says which, for the comment box; nil for the default.
    func pick(for place: String?) -> (project: String?, why: String?) {
        let all = self.all
        func known(_ key: String?) -> String? { key.flatMap { k in all.contains { $0.key == k } ? k : nil } }
        if let place, let m = match(place) { return (m.key, "matches \(m.rule)") }
        if let place, let last = Settings.lastPick(at: place), last.isEmpty || known(last) != nil {
            return (known(last), place.hasPrefix("app:") ? "last used in this app" : "last used on this site")
        }
        return (known(Settings.ticketsProjectKey), nil)
    }

    /// For the web overlay: {projects: [{key, name, people: [{handle, name, agent}]}], project: the pick for this page, why}.
    func overlayOptions(for place: String?) -> [String: Any] {
        let all = self.all
        guard !all.isEmpty else { return [:] }
        var o: [String: Any] = ["projects": all.map { p in
            ["key": p.key, "name": p.name, "people": p.people.map { ["handle": $0.handle, "name": $0.name, "agent": $0.agent] }] as [String: Any]
        }]
        let pick = pick(for: place)
        o["project"] = pick.project
        o["why"] = pick.why
        return o
    }
}

extension Comment {
    /// A first line longer than this makes a poor title: the comment box then asks for one (also in overlay.js).
    static let titleAfter = 80

    /// The note's title: the one given in the comment box, else the text's first line.
    var noteTitle: String {
        let given = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = given.isEmpty ? firstLine.trimmingCharacters(in: .whitespaces) : given
        return t.isEmpty ? "Annotation" : String(t.prefix(200))
    }

    /// POST /projects/{key}/notes body: the comment as Markdown, the page and what was clicked as source context.
    var notePayload: [String: Any] {
        var source: [String: Any] = ["app": "annot", "external_id": id, "context": noteContext]
        if var u = url.flatMap({ URLComponents(string: $0) }), ["http", "https"].contains(u.scheme) {
            u.user = nil
            u.password = nil
            if let s = u.string, s.count <= 2048 { source["url"] = s }
        }
        let pageTitle = isWeb ? (anchor["dom"] as? [String: Any])?["page_title"] as? String : anchor("window_title")
        if let pageTitle, !pageTitle.isEmpty { source["page_title"] = String(pageTitle.prefix(255)) }
        return ["title": noteTitle, "body": noteBody, "kind": "annotation", "source": source, "metafields": fields]
    }

    /// The note's Markdown. Replies are the note's comments; only those from before Rome had them stay in the body.
    var noteBody: String {
        var c = self
        c.replies = replies.filter { $0.remoteID == "note" || $0.remoteID?.hasPrefix("annot.reply.") == true }
        return String(c.markdown(screenshotPath: false).prefix(20_000))
    }

    /// The comment as metafields, which Rome carries into the issue the note becomes. Every ANNOT reads its
    /// colleagues' comments from them: `annot.*` is the comment and where its pin goes, the rest is there to filter
    /// by. Replies made in Triage before notes took comments are `annot.reply.*` (see `Reply.field`). Values of
    /// 1–2,000 characters, so empty ones are left out.
    var fields: [String: String] {
        var m = ["annot.id": id, "annot.author": author, "annot.text": text, "annot.created": ISO.string(createdAt),
                 "os": "macOS " + ProcessInfo.processInfo.operatingSystemVersionString]
        m["annot.title"] = title
        m["annot.anchor"] = anchorField
        m["annot.details"] = details
        if let u = url.flatMap({ URLComponents(string: $0) }), ["http", "https"].contains(u.scheme) {
            var page = u
            page.user = nil
            page.password = nil
            m["page.host"] = page.host?.lowercased()
            m["page.url"] = page.string
        }
        if isWeb {
            m["browser"] = Browser.with(anchor("browser"))?.name
        } else {
            m["app"] = anchor("app_name")
            m["app.bundle_id"] = anchor("bundle_id")
        }
        return m.compactMapValues(Self.field)
    }

    /// A metafield value: at most 2,000 characters, nil when blank.
    static func field(_ v: String) -> String? {
        let s = String(v.prefix(2000))
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    /// Where the pin goes, as JSON within 2,000 characters: without the HTML snippet and styles, and with less of
    /// the element if it's still too long. nil if even that doesn't fit.
    private var anchorField: String? {
        var a = anchor
        func encoded() -> String? {
            (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
        }
        if var dom = a["dom"] as? [String: Any] {
            dom["html"] = nil
            dom["style"] = nil
            a["dom"] = dom
        }
        if let s = encoded(), s.count <= 2000 { return s }
        if let dom = a["dom"] as? [String: Any] { a["dom"] = ["path": dom["path"], "page_title": dom["page_title"]].compactMapValues { $0 } }
        for (key, n) in [("text", 200), ("ax_title", 200), ("ax_value", 0), ("ax_path", 400), ("window_title", 200)] {
            if let v = a[key] as? String { a[key] = n == 0 ? nil : String(v.prefix(n)) }
        }
        if let s = encoded(), s.count <= 2000 { return s }
        return nil
    }

    /// At most 16 KB: the recommended keys, plus the AX element for comments outside the browser.
    private var noteContext: [String: Any] {
        func cut(_ s: String, _ n: Int = 1000) -> String { String(s.prefix(n)) }
        var ctx: [String: Any] = ["os": "macOS " + ProcessInfo.processInfo.operatingSystemVersionString, "author": author]
        let mentioned = Mentions.handles(in: text + "\n" + details)
        if !mentioned.isEmpty { ctx["mentions"] = mentioned }
        if isWeb {
            let dom = anchor["dom"] as? [String: Any] ?? [:]
            ctx["selector"] = cut(anchor("selector"))
            ctx["element_text"] = cut(anchor("text"), 500)
            ctx["tag"] = anchor("tag")
            ctx["html"] = cut(dom["html"] as? String ?? "", 3000)
            ctx["dom_path"] = cut(dom["path"] as? String ?? "")
            if let vp = anchor["viewport"] as? [String: Any] { ctx["viewport"] = ["width": vp["w"] ?? 0, "height": vp["h"] ?? 0] }
            if let pct = anchor["page_pct"] as? [String: Any] { ctx["page_pct"] = pct }
            if let b = Browser.with(anchor("browser")) { ctx["browser"] = b.name }
        } else {
            ctx["app"] = anchor("app_name")
            ctx["window_title"] = cut(anchor("window_title"), 255)
            ctx["element_role"] = anchor("ax_role")
            ctx["element_text"] = cut(anchor("ax_title"), 500)
            ctx["ax_path"] = cut(anchor("ax_path"), 3000)
            if let p = anchor["point"] as? [String: Any] { ctx["x"] = p["x"]; ctx["y"] = p["y"] }
        }
        return ctx.filter { ($0.value as? String)?.isEmpty != true }
    }
}

extension Comment.Reply {
    /// The reply as a metafield, as replies in Triage were before notes took comments: still read, and written for
    /// replies that only went into the note body. The key is the same on every retry: annot.reply.<milliseconds>.<author>.
    var field: (key: String, value: String) {
        let who = String(author.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(20))
        let value = ["author": author, "text": String(text.prefix(1800)), "at": ISO.string(createdAt)]
        let json = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
        return ("annot.reply.\(Int64(createdAt.timeIntervalSince1970 * 1000)).\(who.isEmpty ? "x" : who)", json ?? "{}")
    }
}
