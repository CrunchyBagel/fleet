import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: FleetModel
    @Environment(\.openWindow) private var openWindow
    @State private var collapsed: Set<String> = []      // machines the user folded; everything starts expanded
    @State private var query = ""                        // sidebar search (⌘F)

    func expanded(_ host: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(host) },
                set: { open in if open { collapsed.remove(host) } else { collapsed.insert(host) } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selected) {
                Label("Overview", systemImage: "square.grid.2x2").tag(Item.overview)
                Section("Machines") {
                ForEach(model.tree(matching: query)) { node in
                    if case .host(let h) = node.item {
                        if let kids = node.children {
                            DisclosureGroup(isExpanded: expanded(h)) {
                                // Keyed on the set of sessions: a session appearing or
                                // ending rebuilds the rows instead of shuffling cells.
                                Group {
                                    ForEach(kids) { k in
                                        if case .session(let id) = k.item, let s = model.session(id: id) {
                                            SessionRow(session: s).tag(Item.session(id))
                                                .contextMenu { SessionMenu(session: s) }
                                        }
                                    }
                                }
                                .id(kids.map(\.id.id).joined(separator: "|"))
                                if kids.isEmpty && query.isEmpty {       // an empty group looks broken; give it something to do
                                    Button { model.newSessionOn = NewSessionTarget(host: h) } label: {
                                        HStack(spacing: 8) {     // same shape as SessionRow so it lines up
                                            Image(systemName: "plus.circle").frame(width: 10)
                                            Text("New session…")
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } label: { HostRow(host: h).tag(Item.host(h)).contextMenu { HostMenu(host: h) } }
                        } else {
                            HostRow(host: h).tag(Item.host(h)).contextMenu { HostMenu(host: h) }   // not answering: nothing beneath
                        }
                    }
                }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Project, branch or session")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .sheet(item: $model.newSessionOn) { t in NewSessionSheet(host: t.host) }
            .overlay {
                if model.hosts.hosts.isEmpty && model.hosts.down.isEmpty && model.lastRefresh != nil {
                    Text("No hosts. Run `fleet hosts add`.").foregroundStyle(.secondary)
                }
            }
        } detail: {
            switch model.selected {
            case .host(let h): HostView(host: h)
            case .session(let id):
                if let s = model.session(id: id) { SessionView(session: s) }
                else { ContentUnavailableView("Session ended", systemImage: "moon.zzz", description: Text("It is no longer in Fleet's list.")) }
            case .overview, nil: Overview(selected: $model.selected)
            }
        }
        .onAppear { model.openMain = { openWindow(id: "main") } }
        .confirmationDialog(
            "End \(model.confirmEnd?.title ?? "") on \(model.confirmEnd?.host ?? "")?",
            isPresented: Binding(get: { model.confirmEnd != nil }, set: { if !$0 { model.confirmEnd = nil } }),
            presenting: model.confirmEnd
        ) { s in
            Button("End Session", role: .destructive) { model.endSession(s) }
        } message: { s in
            Text(s.worktree
                 ? "The agent is asked to exit (a running turn is interrupted), then the tmux session is closed. The worktree and its branch stay; fleet reap removes it once merged."
                 : "The agent is asked to exit (a running turn is interrupted), then the tmux session is closed. Uncommitted work in the checkout is untouched.")
        }
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
                    .disabled(model.refreshing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let e = model.actionError ?? model.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(6).textSelection(.enabled)
                    Spacer()
                    if model.actionError != nil {
                        Button { model.actionError = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
    }
}

/// Right-click on a session in the sidebar.
struct SessionMenu: View {
    @EnvironmentObject var model: FleetModel
    let session: Session
    var body: some View {
        Button("Attach") { model.attach(session) }
        Button("Shell Here") { model.shell(on: session.host, dir: session.path) }
        Button("Open Checkout Here") { model.open(session) }
        if let cu = session.claudeURL { Button("Open in Claude") { NSWorkspace.shared.open(cu) } }
        if let gh = session.githubURL { Button("GitHub") { NSWorkspace.shared.open(gh) } }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.path, forType: .string) }
        Divider()
        Button("End Session…") { model.confirmEnd = session }
    }
}

/// Right-click on a machine in the sidebar.
struct HostMenu: View {
    @EnvironmentObject var model: FleetModel
    let host: String
    var body: some View {
        let down = model.downReason(for: host) != nil
        Button("New Session…") { model.newSessionOn = NewSessionTarget(host: host) }.disabled(down)
        Button("Shell") { model.shell(on: host) }.disabled(down)
        if !model.isSelf(host) { Button("Screen Sharing") { screenShare(host) }.disabled(down) }
        Divider()
        Button("Run Doctor") { model.runDoctor(on: host) }
        Button("Update Fleet…") { model.updateFleet(on: host) }.disabled(down)
    }
}

struct HostRow: View {
    @EnvironmentObject var model: FleetModel
    let host: String
    var body: some View {
        let down = model.downReason(for: host)
        HStack {
            Image(systemName: model.info(for: host)?.symbol ?? "desktopcomputer")
                .foregroundStyle(down == nil ? .primary : .secondary)
            Text(host).fontWeight(.semibold).foregroundStyle(down == nil ? .primary : .secondary)
            Spacer()
            if model.loading.contains(host) {
                ProgressView().controlSize(.mini).help("Asking \(host)…")
            } else if down != nil {
                Image(systemName: "bolt.slash").foregroundStyle(.secondary).help(down!)
            } else {
                let n = model.sessions(on: host).filter { $0.state == "blocked" }.count
                if n > 0 { Text("\(n)").font(.caption).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(.orange)) }
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                StateDot(session: session)
                Text(session.title)
                Spacer()
                if let w = session.waiting { Text(w).font(.caption).foregroundStyle(.orange) }
                if !session.attachedFrom.isEmpty { Image(systemName: "rectangle.connected.to.line.below").foregroundStyle(.secondary).help("attached: \(session.attachedFrom.joined(separator: ", "))") }
            }
            // Always a second line: the List caches row heights, and a row that
            // grows when a prompt first appears is drawn over its neighbour.
            Text(session.doing ?? session.branch).font(.caption).lineLimit(1)
                .foregroundStyle(session.doing != nil && session.state == "blocked" ? Color.orange : Color.secondary)
                .padding(.leading, 18)
        }
    }
}
