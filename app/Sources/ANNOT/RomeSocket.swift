import AppKit
import Foundation

/// Rome's live event stream: wss://host/ws with subprotocol rome.v1, one topic per project that has sent comments.
/// Events only say what changed; Tickets re-reads it over REST. After a reconnect the stream resumes from the
/// last seq; when that's not possible (new epoch, resync) `onResync` asks for everything to be re-read.
@MainActor
final class RomeSocket {
    var onEvent: (([String: Any]) -> Void)?
    var onResync: (() -> Void)?
    var onLive: ((Bool) -> Void)?
    var onAuthFailed: (() -> Void)?

    private static let d = UserDefaults.standard
    private var seq: Int? {
        get { Self.d.object(forKey: "romeSeq") as? Int }
        set { Self.d.set(newValue, forKey: "romeSeq") }
    }
    private var epoch: String? {
        get { Self.d.string(forKey: "romeEpoch") }
        set { Self.d.set(newValue, forKey: "romeEpoch") }
    }

    private var server = ""
    private var token: String?
    private var topics: Set<String> = []
    private var subscribed: Set<String> = []
    private var task: URLSessionWebSocketTask?
    private var ready = false // hello received
    private var generation = 0 // bumps on every (re)connect, so a dead socket's loop stops
    private var backoff: Double = 1
    private var pinger: Timer?
    private var retry: DispatchWorkItem?
    private var wakeObserver: Any?

    /// Connects, reconnects or changes topics as needed; no token or no topics disconnects.
    func configure(server: String, token: String?, topics: Set<String>) {
        let reconnect = server != self.server || token != self.token || task == nil
        self.server = server
        self.token = token
        self.topics = topics
        guard token != nil, !topics.isEmpty else { stop(); return }
        if reconnect { connect() } else { resubscribe() }
    }

    func stop() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
        subscribed = []
        pinger?.invalidate()
        pinger = nil
        retry?.cancel()
        retry = nil
        onLive?(false)
    }

    private func connect() {
        stop()
        guard let token, !topics.isEmpty, let url = Self.url(server) else { return }
        if wakeObserver == nil { // the socket dies in sleep; don't wait for the backoff
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.backoff = 1
                    if self?.token != nil { self?.connect() }
                }
            }
        }
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("rome.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let t = URLSession.shared.webSocketTask(with: r)
        task = t
        let gen = generation
        t.resume()
        Task { await receive(t, gen) }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) async {
        while gen == generation {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await t.receive()
            } catch {
                guard gen == generation else { return }
                stop()
                if (t.response as? HTTPURLResponse)?.statusCode == 401 { onAuthFailed?(); return }
                scheduleReconnect()
                return
            }
            guard case .string(let s) = message,
                  let f = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { continue }
            frame(f)
        }
    }

    private func scheduleReconnect() {
        let delay = backoff
        backoff = min(backoff * 2, 60)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.connect() } }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func frame(_ f: [String: Any]) {
        switch f["type"] as? String {
        case "hello":
            backoff = 1
            ready = true
            onLive?(true)
            let e = f["epoch"] as? String
            let fresh = e != epoch || seq == nil // the server's log was reset, or first run: no replay possible
            if fresh {
                epoch = e
                seq = f["head_seq"] as? Int
            }
            subscribed = []
            resubscribe()
            let ms = f["ping_ms"] as? Int ?? 25_000
            pinger?.invalidate()
            pinger = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(["type": "ping"]) }
            }
            if fresh { onResync?() }
        case "event":
            guard let e = f["event"] as? [String: Any] else { return }
            if let s = e["seq"] as? Int { seq = max(seq ?? 0, s) }
            onEvent?(e)
        case "cursor":
            if let s = f["seq"] as? Int { seq = max(seq ?? 0, s) }
        case "resync": // we fell behind the server's buffer: re-read everything, continue from now
            seq = f["head_seq"] as? Int
            onResync?()
            connect()
        case "ping":
            send(["type": "pong"])
        case "unsubscribed":
            if let t = f["topic"] as? String { subscribed.remove(t) }
        default: // subscribed, live, presence, pong, error
            break
        }
    }

    private func resubscribe() {
        guard ready else { return } // hello subscribes
        let add = topics.subtracting(subscribed), drop = subscribed.subtracting(topics)
        if !drop.isEmpty { send(["type": "unsubscribe", "topics": Array(drop)]) }
        if !add.isEmpty {
            var f: [String: Any] = ["type": "subscribe", "id": UUID().uuidString.lowercased(), "topics": Array(add)]
            f["after_seq"] = seq
            f["epoch"] = epoch
            send(f)
        }
        subscribed = topics
    }

    private func send(_ f: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: f) else { return }
        task?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    /// https://host:port[/api/v1] → wss://host:port/ws
    static func url(_ server: String) -> URL? {
        guard var c = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        var p = c.path
        while p.hasSuffix("/") { p.removeLast() }
        if p.hasSuffix("/api/v1") { p.removeLast(7) }
        c.path = p + "/ws"
        return c.url
    }
}
