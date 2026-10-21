import AppKit
import SwiftUI

/// Settings › Account: enter the Rome server and paste a personal token once; name, projects and people come from the account.
/// Then pick where new comments go.
struct AccountSettings: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var tickets = Tickets.shared
    @State private var replacing = false
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            if let account = tickets.account, !replacing {
                profile(account)
                destination
                tokenSection
            } else if tickets.hasToken, !tickets.rejected, !replacing, Rome.isConfigured {
                offline
            } else {
                TokenEntry(replacing: replacing) { replacing = false }
            }
        }
        .settingsPage()
        .task { await tickets.refresh() } // e.g. projects added in Rome since launch
        .confirmationDialog("Disconnect from Rome?", isPresented: $confirmDisconnect) {
            Button("Disconnect") { Task { await tickets.disconnect() } }
            if tickets.tokenInfo != nil {
                Button("Disconnect and Revoke Token", role: .destructive) { Task { await tickets.disconnect(revoke: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Comments already sent stay in Rome but stop syncing until you connect again. Revoking also stops the token from working anywhere else.")
        }
    }

    private func profile(_ a: Tickets.Account) -> some View {
        Section {
            HStack(spacing: 12) {
                AccountAvatar(account: a, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 14, weight: .semibold))
                    Text([a.handle.isEmpty ? "" : "@" + a.handle, a.email].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Disconnect…") { confirmDisconnect = true }
            }
            .padding(.vertical, 2)
            LabeledContent("Server") { Link(Rome.host, destination: Rome.web("/")) }
            LabeledContent("Sync") {
                HStack(spacing: 5) {
                    Circle().fill(tickets.live ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    Text(tickets.live ? "Live" : settings.ticketsProject == nil ? "Off" : "Connecting…")
                }
            }
            if let error = tickets.error { ErrorLine(error) }
        } header: {
            Text("Rome")
        } footer: {
            Text(markdown: a.service ? "A service account's token: comments are sent as \(a.name)."
                 : "Name and picture come from your Rome profile. [Edit profile](\(Rome.web("/settings/profile"))) · [Notifications](\(Rome.web("/settings/notifications")))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var destination: some View {
        Section {
            Picker("Send to", selection: $settings.ticketsProject) {
                Text("Keep on This Mac").tag(String?.none)
                if !tickets.projects.isEmpty { Divider() }
                ForEach(tickets.projects) { Text("\($0.name) (\($0.key))").tag(String?.some($0.key)) }
            }
            if let p = tickets.projects.first(where: { $0.key == settings.ticketsProject }) {
                LabeledContent {
                    Link("Open Triage", destination: Rome.web("/p/\(p.key)/triage"))
                } label: {
                    Text("\(p.name) Triage queue")
                    Text([p.role.map { "You're \($0)" },
                          p.people.isEmpty ? "nobody else to @mention yet" : "\(p.people.count) \(p.people.count == 1 ? "person" : "people") to @mention"]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            } else if tickets.projects.isEmpty, !tickets.busy {
                Text("None of your projects takes notes from you yet. A project admin can give you a role.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("New comments")
        } footer: {
            Text("They land in the Triage queue with their screenshots, and replies and Resolve stay in sync both ways. The Send to picker in each comment box changes this default.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tokenSection: some View {
        Section {
            LabeledContent {
                Button("Replace…") { replacing = true }
            } label: {
                Text(tickets.maskedToken ?? "").font(.system(size: 12, design: .monospaced))
                if let t = tickets.tokenInfo { details(t) }
            }
        } header: {
            Text("API token")
        } footer: {
            Text(markdown: "Kept in your Keychain on this Mac. [Manage your tokens in Rome](\(Rome.web("/settings/tokens")))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// “Annot” · created 21 Oct 2026 · never expires. Orange from two weeks before it expires.
    private func details(_ t: Tickets.TokenInfo) -> some View {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let soon = t.expires.map { $0.timeIntervalSinceNow < 14 * 86_400 } ?? false
        let expiry = t.expires.map { "expires \($0.formatted(day))" + (soon ? " (\($0.formatted(.relative(presentation: .named))))" : "") }
        return Text([t.name.isEmpty ? nil : "“\(t.name)”", t.created.map { "created \($0.formatted(day))" }, expiry ?? "never expires"]
            .compactMap { $0 }.joined(separator: " · "))
            .foregroundStyle(soon ? Color.orange : Color.secondary)
    }

    /// A saved token, but Rome didn't answer (offline at launch, server down).
    private var offline: some View {
        Section("Rome") {
            HStack(spacing: 8) {
                if tickets.busy {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(Rome.host)…")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(tickets.error ?? "Not connected")
                }
                Spacer()
                Button("Try Again") { Task { await tickets.refresh() } }.disabled(tickets.busy)
            }
            HStack {
                Button("Use a Different Token…") { replacing = true }
                Spacer()
                Button("Disconnect") { Task { await tickets.disconnect() } }
            }
        }
    }
}

/// Not connected, or replacing the token: which server, where to get a token and where to paste it.
/// Pasting a whole token connects.
private struct TokenEntry: View {
    @ObservedObject private var tickets = Tickets.shared
    @State private var server = Settings.shared.romeServer
    @State private var token = ""
    @State private var reveal = false
    @FocusState private var focused: Bool
    let replacing: Bool
    let done: () -> Void // connected, or cancelled

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var serverValid: Bool { Rome.isValid(server) }
    /// A token saved before the server was entered (or for another server) can be tried again without pasting.
    private var savedToken: Bool { tickets.hasToken && !replacing && !tickets.rejected }

    var body: some View {
        Section {
            if !replacing {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22)).foregroundStyle(Color.annotBlue)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Send your comments to Rome").font(.system(size: 13, weight: .semibold))
                        Text("Each one lands in a project's Triage queue with its screenshots. Replies and Resolve stay in sync both ways, and you can @mention your team.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            Step(number: 1, title: "Your Rome server", detail: "The address you open Rome at in the browser.") { EmptyView() }
            TextField("Server", text: $server, prompt: Text("https://rome.example.com"))
                .labelsHidden()
                .textContentType(.URL)
                .onSubmit(connect)
            Step(number: 2, title: "Create a token in Rome",
                 detail: "Settings › API tokens › New token. Name it “ANNOT”, then Create token and Copy.") {
                Button("Open Rome") { NSWorkspace.shared.open(URL(string: Rome.normalize(server) + "/settings/tokens")!) }
                    .disabled(!serverValid)
            }
            Step(number: 3, title: "Paste it here",
                 detail: savedToken ? "Or leave it empty to use the token saved on this Mac." : "It starts with rome_pat_. Rome shows it only once.") { EmptyView() }
            HStack(spacing: 6) {
                Group {
                    if reveal {
                        TextField("API token", text: $token, prompt: Text("rome_pat_…"))
                    } else {
                        SecureField("API token", text: $token, prompt: Text("rome_pat_…"))
                    }
                }
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit(connect)
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(reveal ? "Hide the token" : "Show the token")
            }
            if let error = tickets.error { ErrorLine(error) }
            HStack {
                Spacer()
                if replacing {
                    Button("Cancel") {
                        tickets.dismissError()
                        done()
                    }
                }
                Button(tickets.busy ? "Connecting…" : "Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!serverValid || (trimmed.isEmpty && !savedToken) || tickets.busy)
            }
        } header: {
            Text(replacing ? "Replace token" : "Rome")
        } footer: {
            Text("The token is kept in your Keychain and only sent to \(serverValid ? URL(string: Rome.normalize(server))?.host ?? "your server" : "your server").")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { focused = true }
        .onChange(of: token) { old, new in
            // A paste brings the whole token at once; typing waits for Connect.
            if old.isEmpty, new.count >= 20, serverValid, Rome.problem(with: trimmed) == nil { connect() }
        }
    }

    private func connect() {
        let t = trimmed
        guard serverValid, !t.isEmpty || savedToken, !tickets.busy else { return }
        Task {
            if await tickets.connect(server: server, token: t.isEmpty ? nil : t) {
                token = ""
                done()
            }
        }
    }
}

private struct Step<Accessory: View>: View {
    let number: Int
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.annotBlue))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }
}

/// The Rome picture, or the initials bubble comments use while it loads or when there's none.
private struct AccountAvatar: View {
    let account: Tickets.Account
    let size: CGFloat

    var body: some View {
        AsyncImage(url: account.avatar) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Avatar(name: account.service ? "agent:" + account.name : account.name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct ErrorLine: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
    }
}
