import SwiftUI

// MARK: - Overview: usage, what needs you, every machine with its sessions

struct OverviewView: View {
    @EnvironmentObject var model: MobileModel
    @State private var newOn: String?
    @State private var showSettings = false

    var body: some View {
        List {
            if let u = model.usage { Section("Claude usage") { UsageRows(usage: u) } }
            ForEach(model.hosts, id: \.self) { h in
                Section {
                    if let d = model.down[h] {
                        Label(d, systemImage: "bolt.slash").foregroundStyle(.secondary).font(.callout)
                    } else if model.sessions(on: h).isEmpty {
                        Text("No sessions").foregroundStyle(.secondary).font(.callout)
                    } else {
                        ForEach(model.sessions(on: h)) { s in NavigationLink(value: s.id) { SessionRowView(session: s) } }
                    }
                } header: {
                    HStack {
                        Image(systemName: model.infos[h]?.symbol ?? "desktopcomputer")
                        Text(h)
                        Spacer()
                        if model.down[h] == nil {
                            Button { newOn = h } label: { Image(systemName: "plus.circle") }.font(.body)
                        }
                    }
                }
            }
            if let t = model.lastRefresh {
                Section { Text("Updated \(t.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Fleet")
        .navigationDestination(for: String.self) { id in SessionDetailView(id: id) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            ToolbarItem(placement: .topBarTrailing) {
                if model.refreshing { ProgressView() } else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") } }
            }
        }
        .refreshable { await model.refresh() }
        .task { await poll() }
        .sheet(item: $newOn) { h in NewSessionSheet(host: h) }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .overlay(alignment: .bottom) { Banner() }
    }

    /// Poll while this screen is up; SwiftUI cancels the task when it goes.
    private func poll() async {
        while !Task.isCancelled {
            await model.refresh()
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

extension String: @retroactive Identifiable { public var id: String { self } }

/// One line per session; a blocked one adds what it is waiting for. The
/// prompt and the rest are on the detail screen, not in the list.
struct SessionRowView: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(session.dotColor).frame(width: 10, height: 10)
                Text(session.title).fontWeight(.medium)
                Spacer()
                if let w = session.waiting { Text("needs you · \(w)").font(.caption).foregroundStyle(.orange) }
                else { Text(session.badge).font(.caption).foregroundStyle(.secondary) }
            }
            if session.state == "blocked", let n = session.note, !n.isEmpty {
                Text(n).font(.caption).lineLimit(1).foregroundStyle(.orange).padding(.leading, 18)
            }
        }
    }
}

struct UsageRows: View {
    let usage: UsageLimits
    var body: some View {
        meter("5-hour limit", usage.fiveHour, usage.fiveHourResets)
        meter("7-day limit", usage.sevenDay, usage.sevenDayResets)
    }
    @ViewBuilder private func meter(_ title: String, _ pct: Int?, _ resets: Date?) -> some View {
        if let p = pct {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(p)%").fontWeight(.semibold).foregroundStyle(p >= 90 ? Color.red : p >= 70 ? Color.orange : Color.primary)
                }
                ProgressView(value: Double(min(p, 100)), total: 100).tint(p >= 90 ? .red : p >= 70 ? .orange : .accentColor)
                if let r = resets { Text("resets \(r.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Errors and progress, at the bottom, dismissable.
struct Banner: View {
    @EnvironmentObject var model: MobileModel
    var body: some View {
        if let b = model.busy {
            HStack { ProgressView(); Text(b) }.font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
        } else if let e = model.error {
            HStack(alignment: .top) {
                Text(e).font(.callout).foregroundStyle(.red)
                Spacer()
                Button { model.error = nil } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
            }
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
        }
    }
}

// MARK: - One session

struct SessionDetailView: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let id: String
    @State private var confirmEnd = false

    var body: some View {
        if let s = model.session(id: id) {
            List {
                Section {
                    HStack(spacing: 8) {
                        Circle().fill(s.dotColor).frame(width: 12, height: 12)
                        Text(s.badgeWithWait).foregroundStyle(s.dotColor).fontWeight(.semibold)
                        Spacer()
                        Text("on \(s.host)").foregroundStyle(.secondary)
                    }
                }
                let reply = s.said?.isEmpty == false ? s.said : nil
                let ask = s.state == "blocked" && s.note?.isEmpty == false ? s.note : nil
                let askIsReply = ask != nil && reply != nil && (ask == reply || reply!.hasPrefix(ask!.replacingOccurrences(of: "…", with: "")))
                if s.prompt?.isEmpty == false || ask != nil || reply != nil {
                    Section {
                        if let p = s.prompt, !p.isEmpty { row("You asked", p) }
                        if let a = ask, !askIsReply { row("Needs", a, .orange) }
                        if let r = reply { row(askIsReply ? "Waiting on you" : s.state == "done" ? "Replied" : "Last reply", r, askIsReply ? .orange : .primary) }
                    }
                }
                Section {
                    if let cu = s.claudeURL {
                        Button { openURL(cu) } label: { Label("Open in Claude", systemImage: "bubble.left.and.text.bubble.right") }
                    }
                    if let gh = s.githubURL { Link(destination: gh) { Label("GitHub", systemImage: "link") } }
                    Button(role: .destructive) { confirmEnd = true } label: { Label("End session", systemImage: "xmark.octagon") }
                }
                Section {
                    if s.hasStats {
                        if let m = s.model, !m.isEmpty { row("Model", m) }
                        if let c = s.contextPercent {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("Context window").foregroundStyle(.secondary); Spacer(); Text("\(c)% full") }
                                ProgressView(value: Double(min(c, 100)), total: 100).tint(c >= 90 ? .red : c >= 75 ? .orange : .accentColor)
                            }
                        }
                    }
                    row("Last activity", s.shownTime.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    row("Branch", s.branch + (s.dirty ? "  *" : "") + (s.ahead > 0 ? "  ↑\(s.ahead)" : "") + (s.behind > 0 ? "  ↓\(s.behind)" : ""))
                    row("Upstream", s.upstream.isEmpty ? "none (not pushed yet)" : s.upstream)
                    row("Last commit", s.subject.isEmpty ? "—" : s.subject)
                    row("Path", s.path)
                    row("tmux session", s.session)
                    if !s.attachedFrom.isEmpty { row("Attached from", s.attachedFrom.joined(separator: ", ")) }
                }
            }
            .navigationTitle(s.title)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("End \(s.title) on \(s.host)?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End Session", role: .destructive) { Task { await model.endSession(s); dismiss() } }
            } message: {
                Text(s.worktree ? "The agent is asked to exit, then the tmux session is closed. The worktree and its branch stay."
                                : "The agent is asked to exit, then the tmux session is closed. Uncommitted work is untouched.")
            }
            .overlay(alignment: .bottom) { Banner() }
        } else {
            ContentUnavailableView("Session ended", systemImage: "moon.zzz", description: Text("It is no longer in Fleet's list."))
        }
    }
    private func row(_ label: String, _ value: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color).textSelection(.enabled)
        }
    }
}

// MARK: - New session

struct NewSessionSheet: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    let host: String
    @State private var project = ""
    @State private var name = ""
    @State private var starting = false

    var body: some View {
        NavigationStack {
            Form {
                let projects = model.projects[host] ?? []
                Section("Project on \(host)") {
                    if projects.isEmpty {
                        HStack { ProgressView(); Text("Listing projects…").foregroundStyle(.secondary) }
                    } else {
                        Picker("Project", selection: $project) {
                            ForEach(projects, id: \.project) { p in Text(p.claude ? "\(p.project)  ·  claude" : p.project).tag(p.project) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
                }
                Section {
                    TextField("Session name (empty = main)", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("A name adds a second session in the same repo, or a worktree once the project is converted. The session starts Claude Code with Remote Control, so it appears in the Claude app.")
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if starting { ProgressView() } else {
                        Button("Start") {
                            starting = true
                            Task { _ = await model.newSession(on: host, project: project, name: name); starting = false; dismiss() }
                        }.disabled(project.isEmpty)
                    }
                }
            }
            .task {
                await model.loadProjects(on: host)
                if project.isEmpty, let f = model.projects[host]?.first { project = f.project }
            }
        }
    }
}

// MARK: - Settings and onboarding

struct SettingsView: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var discovering = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("ssh") {
                TextField("Username on your Macs", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                KeyRow()
            }
            Section {
                ForEach(model.hosts, id: \.self) { h in
                    HStack { Text(h); Spacer(); if model.down[h] != nil { Image(systemName: "bolt.slash").foregroundStyle(.secondary) } }
                }
                .onDelete { idx in var h = model.hosts; h.remove(atOffsets: idx); model.hosts = h }
                HStack {
                    TextField("Add a Mac by tailnet name", text: $entry).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") { model.hosts = model.hosts + [entry.trimmingCharacters(in: .whitespaces)]; entry = "" }
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if discovering { HStack { ProgressView(); Text("Asking your Macs…") } }
                else { Button("Refresh host list from a Mac") { discover() }.disabled(model.hosts.isEmpty) }
                if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Hosts") } footer: {
                Text("Refresh asks the first Mac that answers for ~/.config/fleet/hosts, the list every Mac shares. The phone must be on the tailnet (Tailscale app).")
            }
            Section {
                Button("Forget pinned host keys") { HostKeys.forgetAll(); model.resetConnections(); message = "Host keys forgotten; the next connection to each Mac pins its key again." }
            } footer: {
                Text("Each Mac's ssh host key is pinned on first connection. Forget them only after reinstalling macOS on a Mac.")
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func discover() {
        discovering = true; message = nil
        Task {
            do { let (h, from) = try await model.refreshHosts(); model.hosts = h; message = "From \(from): \(h.joined(separator: ", "))" }
            catch { message = error.localizedDescription }
            discovering = false
        }
    }
}

/// The phone's public key, with the one command that authorizes it everywhere.
struct KeyRow: View {
    @State private var line = (try? KeyStore.publicKeyLine()) ?? ""
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This phone's key").font(.caption).foregroundStyle(.secondary)
            Text(line).font(.caption2.monospaced()).lineLimit(3).truncationMode(.middle)
            HStack {
                Button(copied ? "Copied" : "Copy `fleet keys add` command") {
                    UIPasteboard.general.string = "fleet keys add \"\(line)\""; copied = true
                }
                .font(.callout)
            }
            Text("Run that on any Mac with Fleet installed: it authorizes the key on every Mac in the fleet. Revoke with fleet keys rm \(KeyStore.comment).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: MobileModel
    @State private var entry = ""
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Text("Fleet runs the fleet command on your Macs over ssh, through Tailscale. Three things to set up: your username there, this phone's key on the Macs, and one Mac to ask for the host list.")
                    .font(.callout)
            }
            Section("1. Username on your Macs") {
                TextField("username", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("2. Authorize this phone") { KeyRow() }
            Section("3. One Mac's tailnet name") {
                TextField("e.g. mini", text: $entry).textInputAutocapitalization(.never).autocorrectionDisabled()
                if working { HStack { ProgressView(); Text("Connecting…") } }
                else { Button("Connect and fetch the host list") { connect() }.disabled(entry.isEmpty || model.username.isEmpty) }
                if let m = message { Text(m).font(.callout).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Set up Fleet")
    }
    private func connect() {
        working = true; message = nil
        Task {
            do { model.hosts = try await model.discoverHosts(from: entry) }
            catch { message = error.localizedDescription }
            working = false
        }
    }
}
