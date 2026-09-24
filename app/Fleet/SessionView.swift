import SwiftUI

/// One session: everything fleet knows about it, and what you can do with it.
struct SessionView: View {
    @EnvironmentObject var model: FleetModel
    let session: Session
    @AppStorage(Prefs.terminal) private var terminal = Terminal.preferred.rawValue
    @AppStorage(Prefs.showXcode) private var showXcode = true
    @AppStorage(Prefs.showClaude) private var showClaude = true
    @AppStorage(Prefs.showGitHub) private var showGitHub = true
    @AppStorage(Prefs.showScreenSharing) private var showScreenSharing = true
    @AppStorage(Prefs.showFinder) private var showFinder = true
    private var terminalName: String { (Terminal(rawValue: terminal) ?? .preferred).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StateDot(session: session).scaleEffect(1.5)
                Text(session.title).font(.title).bold()
                Text("on \(session.host)").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Text(session.badgeWithWait).foregroundStyle(session.dotColor).font(.headline)
            }

            HStack(spacing: 10) {
                Menu {
                    Button("Claude Code") { model.attach(session) }
                    Button("Open Shell") { model.shell(on: session.host, dir: session.path) }
                } label: {
                    VStack(spacing: 5) {   // same shape as StackedLabelStyle, with a chevron beside the caption
                        Image(systemName: "terminal").font(.title2).frame(height: 24)
                        HStack(spacing: 3) {
                            Text(terminalName)
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.85)
                        }.font(.caption.weight(.semibold))
                    }
                }
                .menuStyle(.button).buttonStyle(FilledStyle(tint: .green)).menuIndicator(.hidden)
                .help("In \(terminalName): attach to the Claude Code session (its window if one is open, else a new one), or open a fresh shell in this session's directory")
                if showXcode {
                    ActionButton(title: "Open", system: "arrow.up.forward.app", tint: .blue,
                                 help: "Pull this branch onto this Mac and open the checkout: Xcode when it has a project, else Finder, or what FLEET_OPEN in ~/.config/fleet/config says") { model.open(session) }
                        .disabled(model.busy[session.id] != nil)
                }
                if showClaude, let cu = session.claudeURL {
                    ActionButton(title: "Claude", brand: Brand.claude, tint: Color(red: 0.85, green: 0.47, blue: 0.34),
                                 help: "Open this session in the Claude app") { NSWorkspace.shared.open(cu) }
                }
                if showGitHub, let gh = session.githubURL {
                    Menu {
                        Button("Repository") { NSWorkspace.shared.open(gh) }
                        Button("This branch") { NSWorkspace.shared.open(gh.appending(path: "tree/\(session.branch)")) }
                        Button("Pull requests for this branch") {
                            var c = URLComponents(url: gh.appending(path: "pulls"), resolvingAgainstBaseURL: false)!
                            c.queryItems = [URLQueryItem(name: "q", value: "is:pr head:\(session.branch)")]
                            NSWorkspace.shared.open(c.url!)
                        }
                        Divider()
                        Button("Issues") { NSWorkspace.shared.open(gh.appending(path: "issues")) }
                        Button("Milestones") { NSWorkspace.shared.open(gh.appending(path: "milestones")) }
                    } label: {
                        VStack(spacing: 5) {   // same shape as StackedLabelStyle, with a chevron beside the caption
                            SVGShape(d: Brand.github).fill(.white).frame(width: 22, height: 22).frame(height: 24)
                            HStack(spacing: 3) {
                                Text("GitHub")
                                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.85)
                            }.font(.caption.weight(.semibold))
                        }
                    }
                    .menuStyle(.button).buttonStyle(FilledStyle(tint: .purple)).menuIndicator(.hidden)   // the custom style drops the system chevron, so draw our own
                    .help(gh.absoluteString)
                }
                if model.isSelf(session.host) {
                    if showFinder {
                        ActionButton(title: "Finder", system: "folder", tint: .gray,
                                     help: "Reveal the working directory in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
                        }
                    }
                } else if showScreenSharing {
                    ActionButton(title: "Screen Sharing", system: "display", tint: .indigo,
                                 help: "Open Screen Sharing to \(session.host)") { model.screenShare(session.host) }
                        .disabled(model.downReason(for: session.host) != nil)
                }
                Menu {
                    if let mt = model.moveTargets[session.id] {
                        ForEach(mt.targets) { t in
                            Button(t.ok ? t.host : "\(t.host): \(t.why)") {
                                model.confirmMove = PendingMove(session: session, target: t.host)
                            }
                            .disabled(!t.ok)
                        }
                    } else {
                        Text("Finding Macs that have this repo…")
                    }
                } label: {
                    VStack(spacing: 5) {   // same shape as the GitHub menu
                        Image(systemName: "arrow.right.circle").font(.title2).frame(height: 24)
                        HStack(spacing: 3) {
                            Text("Move")
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.85)
                        }.font(.caption.weight(.semibold))
                    }
                }
                .menuStyle(.button).buttonStyle(FilledStyle(tint: .teal)).menuIndicator(.hidden)
                .disabled(session.moveBlocker != nil || model.busy[session.id] != nil
                          || model.moveTargets[session.id]?.targets.contains(where: \.ok) == false)
                .help(moveHelp)
                Spacer()
                ActionButton(title: "End", system: "xmark.octagon", tint: .red,
                             help: "End this session: the agent is asked to exit, then its tmux session is closed (asks first)") { model.confirmEnd = session }
                    .disabled(model.busy[session.id] != nil)
            }

            if let doing = model.busy[session.id] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(doing).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 4)
            }

            if session.prompt?.isEmpty == false || session.note?.isEmpty == false || session.said?.isEmpty == false {
                // The exchange: what you asked, and the agent's side. An idle
                // notification's note is the reply itself, so that is one row,
                // orange while it waits on you; a permission request is its own row.
                let reply = session.said?.isEmpty == false ? session.said : nil
                let ask = session.state == "blocked" && session.note?.isEmpty == false ? session.note : nil
                let askIsReply = ask != nil && reply != nil && (ask == reply || reply!.hasPrefix(ask!.replacingOccurrences(of: "…", with: "")))
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        if let p = session.prompt, !p.isEmpty {
                            GridRow { Text("You asked").foregroundStyle(.secondary).gridColumnAlignment(.leading); Text(p).textSelection(.enabled) }
                        }
                        if let a = ask, !askIsReply {
                            GridRow { Text("Needs").foregroundStyle(.secondary); Text(a).foregroundStyle(.orange).textSelection(.enabled) }
                        }
                        if let r = reply {
                            GridRow {
                                Text(askIsReply ? "Waiting on you" : session.state == "done" ? "Replied" : "Last reply").foregroundStyle(.secondary)
                                Text(r).foregroundStyle(askIsReply ? Color.orange : Color.primary).textSelection(.enabled).lineLimit(12)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GitStateBox(session: session)

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    if session.hasStats {
                        if let m = session.model, !m.isEmpty {
                            GridRow { Text("Model").foregroundStyle(.secondary); Text(m) }
                        }
                        if let c = session.contextPercent {
                            GridRow {
                                Text("Context window").foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    ProgressView(value: Double(min(c, 100)), total: 100).frame(width: 120)
                                        .tint(c >= 90 ? .red : c >= 75 ? .orange : .accentColor)
                                    Text("\(c)% full").foregroundStyle(c >= 90 ? .red : .primary)
                                }
                                .help("How much of this session's context window is used; compaction happens near the top")
                            }
                        }
                    }
                    GridRow { Text("Last activity").foregroundStyle(.secondary); Text(session.shownTime.map { $0.formatted(.relative(presentation: .named)) + "  ·  " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "—") }
                    GridRow { Text("Branch").foregroundStyle(.secondary); BranchText(session: session) }
                    GridRow { Text("Last commit").foregroundStyle(.secondary); Text(session.subject.isEmpty ? "—" : session.subject).lineLimit(2) }
                    GridRow { Text("Path").foregroundStyle(.secondary); Text(session.path).textSelection(.enabled) }
                    GridRow { Text("Checkout").foregroundStyle(.secondary); Text(session.worktree ? "worktree (its own branch and files)" : "main repo") }
                    GridRow { Text("tmux session").foregroundStyle(.secondary); Text(session.session).textSelection(.enabled) }
                    GridRow { Text("Attached from").foregroundStyle(.secondary); Text(session.attachedFrom.isEmpty ? "nobody" : session.attachedFrom.joined(separator: ", ")) }
                    if let r = session.remote, !r.isEmpty {
                        GridRow { Text("Remote").foregroundStyle(.secondary); Text(r).textSelection(.enabled).foregroundStyle(.secondary) }
                    }
                }
                .font(.callout)
                .padding(6)
            }
            Spacer()
        }
        .padding()
        .task(id: "\(session.id)|\(session.moveBlocker ?? "")") {
            if session.moveBlocker == nil { model.loadMoveTargets(session) }
        }
    }

    /// The Move button's tooltip: why it is disabled, else what it does.
    private var moveHelp: String {
        if let b = session.moveBlocker { return b }
        if let mt = model.moveTargets[session.id], !mt.targets.contains(where: \.ok) {
            return "No other Mac can take this session: " + mt.targets.map { "\($0.host): \($0.why)" }.joined(separator: "; ")
        }
        return "Move this session to another Mac: the agent writes a handoff note, this session ends, and a new one starts there with the note"
    }
}

/// Work that exists only on the session's machine. Git is the only transport
/// between Macs, so uncommitted files and unpushed commits are exactly what
/// another machine cannot see. State only, from the record: fleet is not a
/// git client. `fleet status` never fetches, so "behind" is as of that
/// machine's last fetch.
struct GitStateBox: View {
    let session: Session

    private var unpushed: (text: String, warn: Bool) {
        if session.upstream.isEmpty {
            if session.remote?.isEmpty != false { return ("No remote: this repository exists only on \(session.host)", true) }
            return ("\(session.branch) has never been pushed", true)
        }
        if session.ahead > 0 { return ("\(session.ahead) commit\(session.ahead == 1 ? "" : "s") not pushed to \(session.upstream)", true) }
        return ("Nothing: \(session.upstream) has every commit", false)
    }

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Uncommitted").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    line(session.dirty ? "Changes in the working tree on \(session.host)" : "Nothing: the working tree is clean", warn: session.dirty)
                }
                GridRow { Text("Unpushed").foregroundStyle(.secondary); line(unpushed.text, warn: unpushed.warn) }
                if session.behind > 0 {
                    GridRow {
                        Text("Behind").foregroundStyle(.secondary)
                        line("\(session.behind) commit\(session.behind == 1 ? "" : "s") on \(session.upstream) not here yet (as of \(session.host)'s last fetch)", warn: false, symbol: "arrow.down.circle")
                    }
                }
            }
            .font(.callout)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ text: String, warn: Bool, symbol: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol ?? (warn ? "exclamationmark.circle.fill" : "checkmark.circle"))
                .foregroundStyle(warn ? Color.orange : Color.secondary)
            Text(text).textSelection(.enabled)
        }
    }
}

/// Pick a project on this machine (Claude-used first, as `fleet projects`
/// ranks them), name the session, go.
struct NewSessionSheet: View {
    @EnvironmentObject var model: FleetModel
    @Environment(\.dismiss) private var dismiss
    let host: String
    @State private var filter: String = ""
    @State private var project: String?
    @State private var name: String = ""
    @State private var chosenModel: String = ""   // catalog id; "" = the default row (no --model)
    @State private var attach = true
    @State private var status: String?       // while starting: what fleet is doing
    @State private var failure: String?
    @FocusState private var filterFocused: Bool

    /// Projects on the host narrowed by the filter (any part of the name, case-insensitive).
    private var shown: [ProjectEntry] {
        let all = model.projects[host] ?? []
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.project.localizedCaseInsensitiveContains(q) }
    }
    private var loading: Bool { model.projects[host] == nil }
    private var chosen: String? { project.flatMap { p in shown.contains { $0.project == p } ? p : nil } ?? (shown.count == 1 ? shown[0].project : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New session on \(host)").font(.headline)
            // The field and list are always there, so the sheet does not
            // change size when the projects arrive; loading shows in the list.
            TextField("Type to filter projects", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit { if chosen != nil { start() } }
            List(shown, id: \.project, selection: $project) { p in
                HStack {
                    Text(p.project)
                    Spacer()
                    Text(p.layout).foregroundStyle(.secondary).font(.caption)
                    if p.claude { Text("claude").foregroundStyle(.secondary).font(.caption).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                }
                .tag(p.project)
            }
            .frame(height: 180)
            // A double-click starts the session, as Enter does. This is the
            // List's own double-click hook: a tap gesture on the rows would
            // take the click before the List selects, so a single click no
            // longer highlighted.
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let p = ids.first { project = p; start(project: p) }
            }
            .overlay {
                if loading { ProgressView("Listing projects on \(host)…").controlSize(.small) }
                else if (model.projects[host] ?? []).isEmpty {
                    // Nothing at all: FLEET_ROOT there is empty or wrong (the example config's ~/code).
                    Text("No projects under FLEET_ROOT on \(host).\nSet FLEET_ROOT in its ~/.config/fleet/config; Doctor on the machine screen shows the path.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                } else if shown.isEmpty { Text("No project matches").foregroundStyle(.secondary) }
            }
            // Which model the session starts with: the host's Claude Code
            // catalog (fleet models), with its own default as the first row.
            // That row passes no --model at all, so what Claude Code would
            // pick on its own, a [1m] variant included, is what it gets.
            Picker("Model", selection: $chosenModel) {
                if let list = model.models[host] {
                    if let d = list.resolvedDefault { Text("\(d.name)  (default)").tag("") } else { Text("Automatic").tag("") }
                    let main = list.models.filter { $0.section == "main" && $0.id != list.resolvedDefault?.id }
                    let rest = list.models.filter { $0.section != "main" && $0.id != list.resolvedDefault?.id }
                    if !main.isEmpty { Divider(); ForEach(main, id: \.id) { Text($0.name).tag($0.id) } }
                    if !rest.isEmpty { Divider(); ForEach(rest, id: \.id) { Text($0.name).tag($0.id) } }
                } else {
                    Text("Automatic").tag("")
                }
            }
            .disabled(model.models[host] == nil)
            TextField("Session name (empty = main)", text: $name).textFieldStyle(.roundedBorder)
            Toggle("Open in \(Terminal.preferred.title) when ready", isOn: $attach)
            // Always laid out, two lines tall, so the sheet does not grow
            // when starting begins; only a long error makes it taller.
            Group {
                if let status {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                } else if let failure {
                    Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(status != nil)
                Button("Start") { start() }.keyboardShortcut(.defaultAction).disabled(chosen == nil || status != nil)
            }
        }
        .padding().frame(width: 480)
        .onAppear { model.loadProjects(on: host); model.loadModels(on: host); filterFocused = true }
        .onChange(of: model.projects[host]?.first?.project) { _, first in if project == nil, let f = first { project = f } }
    }

    /// Runs fleet with the sheet up, showing each stage; closes on success,
    /// shows the error and stays otherwise.
    private func start(project override: String? = nil) {
        guard let p = override ?? chosen, status == nil else { return }
        failure = nil
        Task {
            do {
                try await model.newSession(host: host, project: p, name: name.isEmpty ? nil : name,
                                           model: chosenModel.isEmpty ? nil : chosenModel, thenAttach: attach) { status = $0 }
                status = nil
                dismiss()
            } catch {
                status = nil
                failure = error.localizedDescription
            }
        }
    }
}
