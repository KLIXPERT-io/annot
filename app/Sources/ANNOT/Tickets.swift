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
/// with its screenshots. From then on, both ways: replies ⇄ the note body (while in Triage) or the issue's comments
/// (once triaged), Resolve/Reopen ⇄ dismiss/restore or Done/To Do. Rome's changes arrive over the WebSocket.
/// Comments stay local when no project is chosen.
@MainActor
final class Tickets: ObservableObject {
    static let shared = Tickets()

    struct Project: Identifiable, Hashable {
        let key: String
        let name: String
        let role: String? // yours in the project: "Admin", "Member"…
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
        socket.onResync = { [weak self] in Task { await self?.syncAll() } }
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
            return Project(key: key, name: p["name"] as? String ?? key, role: (viewer?["role"] as? [String: Any])?["name"] as? String)
        }
        projects = list
        for i in list.indices {
            guard let page = try? await c.call("GET", "/principals?project=\(list[i].key)&limit=200") else { continue }
            list[i].people = (page["items"] as? [[String: Any]] ?? []).compactMap { p in
                guard let h = p["handle"] as? String, !h.isEmpty, h != handle else { return nil }
                return Person(handle: h, name: p["name"] as? String ?? h, agent: p["kind"] as? String == "service")
            }
        }
        projects = list
    }

    // MARK: live updates

    /// One topic per project that has sent comments, plus the one new comments go to.
    private func updateSocket() {
        var keys = Set(CommentStore.shared.snapshot.compactMap { $0.ticket?.noteID != nil ? $0.ticket?.project : nil })
        if let p = Settings.shared.ticketsProject { keys.insert(p) }
        socket.configure(server: Rome.server, token: account != nil ? token : nil,
                         topics: Set(keys.map { "project:" + $0 }))
    }

    /// An event names a note or an issue; re-sync the comments linked to it.
    private func handle(_ e: [String: Any]) {
        let data = e["data"] as? [String: Any] ?? [:], entity = e["entity"] as? [String: Any] ?? [:]
        func key(_ o: Any?) -> String? { (o as? [String: Any])?["key"] as? String }
        var notes = Set<String>(), issues = Set<String>()
        if entity["type"] as? String == "note", let id = entity["id"] as? String { notes.insert(id) }
        if let n = data["note"] as? [String: Any] {
            if let id = n["id"] as? String { notes.insert(id) }
            if let k = key(n["issue"]) { issues.insert(k) }
        }
        for k in [entity["key"] as? String, key(data["issue"]), key((data["comment"] as? [String: Any])?["issue"])] {
            if let k { issues.insert(k) }
        }
        for c in CommentStore.shared.snapshot {
            guard let t = c.ticket else { continue }
            if t.noteID.map(notes.contains) == true || t.issueKey.map(issues.contains) == true { scheduleSync(c.id) }
        }
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
                link.syncedStatus = c.status
                link.remoteStatus = "open"
                link.syncedDetails = c.details
                CommentStore.shared.setTicket(link, for: id)
                let sent = Set(c.replies.map(\.createdAt)) // already in the note body
                CommentStore.shared.applyRemote(id) { c in
                    for i in c.replies.indices where c.replies[i].remoteID == nil && sent.contains(c.replies[i].createdAt) { c.replies[i].remoteID = "note" }
                    return !sent.isEmpty
                }
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
        } catch {
            link.error = error.localizedDescription
            if announce { HUD.show("Not sent to \(link.project): \(error.localizedDescription)", isError: true, seconds: 4) }
        }
        CommentStore.shared.setTicket(link, for: id)
    }

    /// Rome → comment: the note's state, the issue's status and comments. Where both changed, Rome wins.
    private func pull(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let noteID = link.noteID else { return }
        apply(try await client.call("GET", "/notes/\(noteID)"), to: &link)
        var remote: String? = link.state == "dismissed" ? "resolved" : link.state == "new" ? "open" : nil
        if link.state == "converted", let key = link.issueKey {
            if link.ownsIssue {
                let issue = try await client.call("GET", "/issues/\(key)")
                remote = (issue["status"] as? [String: Any])?["category"] as? String == "done" ? "resolved" : "open"
            }
            let comments = try await client.list("/issues/\(key)/comments")
            if link.detailsCommentID != nil { // deleted in Rome: post a new one on the next change
                let dc = comments.first { $0["id"] as? String == link.detailsCommentID }
                if let dc, !(dc["deleted_at"] is String) { link.detailsCommentVersion = dc["version"] as? Int ?? link.detailsCommentVersion }
                else { link.detailsCommentID = nil; link.detailsCommentVersion = nil }
            }
            merge(comments, into: id, skipping: [link.noteCommentID, link.detailsCommentID].compactMap { $0 })
        }
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

    /// Issue comments → replies. Ours come back with the ID we stored (or, racing the POST answer, the same text).
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
            return changed
        }
    }

    /// Screenshots it doesn't have yet: to the note while it's in Triage, to the issue after.
    private func pushFiles(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let c = CommentStore.shared.comment(id), let noteID = link.noteID else { return }
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

    /// Replies and details → Rome: rewrite the note body while in Triage (it shows the thread), issue comments after.
    private func pushReplies(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let c = CommentStore.shared.comment(id), let noteID = link.noteID else { return }
        let pending = c.replies.filter { $0.remoteID == nil }
        let detailsChanged = c.details != (link.syncedDetails ?? "")
        if link.state == "new" {
            guard !pending.isEmpty || detailsChanged else { return }
            let body = String(c.markdown(screenshotPath: false).prefix(20_000))
            do {
                apply(try await client.call("PATCH", "/notes/\(noteID)", body: ["body": body, "version": link.noteVersion ?? 1]), to: &link)
            } catch let e as RomeError where e.code == "version-conflict" {
                apply(try await client.call("GET", "/notes/\(noteID)"), to: &link)
                apply(try await client.call("PATCH", "/notes/\(noteID)", body: ["body": body, "version": link.noteVersion ?? 1]), to: &link)
            }
            for r in pending { setRemoteID("note", of: r, in: id) }
            link.syncedDetails = c.details
        } else if link.state == "converted", let key = link.issueKey {
            for r in pending {
                let res = try await client.call("POST", "/issues/\(key)/comments", body: ["body": r.text])
                if let rid = res["id"] as? String { setRemoteID(rid, of: r, in: id) }
            }
        }
    }

    /// Details changed after triage → one "Details" comment on the issue, created once and then edited.
    private func pushDetails(_ client: RomeClient, _ id: String, _ link: inout TicketLink) async throws {
        guard let c = CommentStore.shared.comment(id), link.state == "converted", let key = link.issueKey,
              c.details != (link.syncedDetails ?? "") else { return }
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

    private func setRemoteID(_ rid: String, of reply: Comment.Reply, in id: String) {
        CommentStore.shared.applyRemote(id) { c in
            guard let i = c.replies.firstIndex(where: { $0.remoteID == nil && $0.createdAt == reply.createdAt && $0.text == reply.text }) else { return false }
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

    /// For the web overlay: {projects: [{key, name, people: [{handle, name, agent}]}], project: default}.
    var overlayOptions: [String: Any] {
        let all = self.all
        guard !all.isEmpty else { return [:] }
        var o: [String: Any] = ["projects": all.map { p in
            ["key": p.key, "name": p.name, "people": p.people.map { ["handle": $0.handle, "name": $0.name, "agent": $0.agent] }] as [String: Any]
        }]
        o["project"] = Settings.ticketsProjectKey.flatMap { key in all.contains { $0.key == key } ? key : nil }
        return o
    }
}

extension Comment {
    /// POST /projects/{key}/notes body: the comment as Markdown, the page and what was clicked as source context.
    var notePayload: [String: Any] {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = firstLine.trimmingCharacters(in: .whitespaces).isEmpty ? "Annotation" : String(firstLine.prefix(200))
        var source: [String: Any] = ["app": "annot", "external_id": id, "context": noteContext]
        if var u = url.flatMap({ URLComponents(string: $0) }), ["http", "https"].contains(u.scheme) {
            u.user = nil
            u.password = nil
            if let s = u.string, s.count <= 2048 { source["url"] = s }
        }
        let pageTitle = isWeb ? (anchor["dom"] as? [String: Any])?["page_title"] as? String : anchor("window_title")
        if let pageTitle, !pageTitle.isEmpty { source["page_title"] = String(pageTitle.prefix(255)) }
        return ["title": title, "body": String(markdown(screenshotPath: false).prefix(20_000)), "kind": "annotation", "source": source]
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
