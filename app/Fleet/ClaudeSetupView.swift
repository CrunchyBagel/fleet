import SwiftUI

/// The Claude Setup screen: every Claude Code setup item that differs
/// between the Macs (`fleet claude --json`), as a list that says in words
/// what differs, and an inspector showing the selected item on each Mac.
/// Permission rules sit in a collapsed section: they outnumber everything
/// else and matter less. The bar above the list (segmented, so the choice
/// is always in view) turns it into one Mac's report (what it has or lacks
/// against the other Macs, or against one chosen Mac): the rows, the
/// Differences filter and the wording are then relative to it.
struct ClaudeSetupView: View {
    @EnvironmentObject var model: FleetModel
    @State private var onlyDifferences = true
    @State private var search = ""
    @State private var focus: String?          // the Mac whose report this is; nil = every Mac at once
    @State private var against: String?        // the one Mac it is compared with; nil = all the others

    static let kinds = ["error", "marketplace", "plugin", "mcp", "setting", "file"]

    static func icon(_ kind: String) -> String {
        switch kind {
        case "marketplace": return "bag"
        case "plugin": return "puzzlepiece.extension"
        case "mcp": return "server.rack"
        case "setting": return "slider.horizontal.3"
        case "file": return "doc.text"
        case "perm": return "lock.shield"
        default: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        content
            .navigationTitle("Claude Setup")
            .navigationSubtitle(subtitle)
            .searchable(text: $search, placement: .toolbar, prompt: "Plugin, server, setting or rule")
            .task { model.loadClaudeSetup() }
            .onChange(of: focus) { _, f in if f == nil || against == f { against = nil } }
            .onDisappear { if !model.claudeActionRunning { model.claudeAction = nil } }
            .confirmationDialog(
                "Remove \(model.claudeConfirmRemove?.item.displayName ?? "") from \(model.claudeConfirmRemove?.host ?? "")?",
                isPresented: Binding(get: { model.claudeConfirmRemove != nil }, set: { if !$0 { model.claudeConfirmRemove = nil } }),
                presenting: model.claudeConfirmRemove
            ) { r in
                Button("Remove", role: .destructive) { model.claudeRemove(r.item, from: r.host) }
            } message: { r in
                Text(r.item.kind == "file" || r.item.kind == "setting" || r.item.kind == "perm"
                     ? "fleet claude rm runs on \(r.host). The file it changes is backed up once as .fleet-backup."
                     : "fleet claude rm runs on \(r.host) and removes it through Claude Code.")
            }
    }

    private var subtitle: String {
        if model.claudeSetupLoading { return "Asking every Mac…" }
        if let e = model.claudeSetupError { return "Could not refresh: \(e)" }
        if let t = model.claudeSetupAt { return "Updated \(t.formatted(date: .omitted, time: .shortened))" }
        return ""
    }

    @ViewBuilder private var content: some View {
        if let s = model.claudeSetup {
            let view = Perspective(answered: columns(s), focus: focus, against: against)
            let hosts = view.hosts
            let sections = Self.kinds.compactMap { k -> (String, [ClaudeItem])? in
                let rows = s.items.filter { $0.kind == k && (k == "error" || !onlyDifferences || view.differs($0)) && matches($0) }
                return rows.isEmpty ? nil : (k, rows)
            }
            let rules = s.items.filter { $0.kind == "perm" && (!onlyDifferences || view.differs($0)) && matches($0) }
            VStack(spacing: 0) {
                scopeBar(answered: columns(s))
                Divider()
                if sections.isEmpty && rules.isEmpty && search.isEmpty {
                    ContentUnavailableView(onlyDifferences ? view.matchTitle : "Nothing set up",
                                           systemImage: "checkmark.seal",
                                           description: Text(downNote(s) ?? view.matchNote))
                } else {
                    List(selection: $model.claudeSelected) {
                        if !s.down.isEmpty {
                            ForEach(s.down.sorted { $0.key < $1.key }, id: \.key) { h, why in
                                Label("\(h) isn't answering: \(why)", systemImage: "bolt.slash")
                                    .font(.callout).foregroundStyle(.secondary).selectionDisabled()
                            }
                        }
                        ForEach(sections, id: \.0) { kind, rows in
                            Section(ClaudeItem.title(kind)) {
                                ForEach(rows) { ClaudeRow(item: $0, status: view.status($0), differs: view.differs($0)).tag($0.id) }
                            }
                        }
                        if !rules.isEmpty {
                            Section(isExpanded: $model.claudeShowRules) {
                                ForEach(rules) { ClaudeRow(item: $0, status: view.status($0), differs: view.differs($0)).tag($0.id) }
                            } header: {
                                let n = rules.filter(view.differs).count
                                Text("Permission rules — \(n) differ" + (onlyDifferences ? "" : ", \(rules.count - n) the same"))
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .overlay { if sections.isEmpty && rules.isEmpty { ContentUnavailableView.search(text: search) } }
                }
            }
            .inspector(isPresented: .constant(true)) {
                Group {
                    if let id = model.claudeSelected, let item = s.items.first(where: { $0.id == id }) {
                        ClaudeInspector(item: item, hosts: hosts)
                    } else {
                        ContentUnavailableView("Select an item", systemImage: "sidebar.right",
                                               description: Text("See it on every Mac, and copy or remove it."))
                    }
                }
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
            }
        } else if let e = model.claudeSetupError {
            ContentUnavailableView("Could not read the Claude setups", systemImage: "exclamationmark.triangle", description: Text(e))
        } else {
            ProgressView("Asking every Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The controls above the list, always in view with their choice showing:
    /// which Mac's report this is (every Mac at once, or one), what that Mac
    /// is compared with, and whether to list only what differs.
    private func scopeBar(answered: [String]) -> some View {
        HStack(spacing: 16) {
            Picker("Mac", selection: $focus) {
                Text("All Macs").tag(String?.none)
                ForEach(answered, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .help("Every Mac at once, or one Mac's report: what it has or lacks")
            if let f = focus {
                Picker("Compared with", selection: $against) {
                    Text("All others").tag(String?.none)
                    ForEach(answered.filter { $0 != f }, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .help("Compare \(f) with every other Mac, or with one of them")
            }
            Spacer(minLength: 0)
            Picker("Show", selection: $onlyDifferences) {
                Text("Differences").tag(true)
                Text("All").tag(false)
            }
            .help("Show only what differs, or everything")
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        // A flexible frame, so the bar reports no minimum width of its own:
        // segmented controls cannot shrink, and a detail column whose minimum
        // size changes while it is being laid out (switching to this screen
        // with the data already loaded) makes AppKit throw from
        // updateConstraints and the app abort.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
    /// The Macs that answered, this one first.
    private func columns(_ s: ClaudeSetup) -> [String] {
        let me = model.selfHost
        return s.hosts.filter { $0 == me } + s.hosts.filter { $0 != me }
    }
    private func matches(_ item: ClaudeItem) -> Bool {
        search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
    }
    private func downNote(_ s: ClaudeSetup) -> String? {
        s.down.isEmpty ? nil : "Not answering: " + s.down.keys.sorted().joined(separator: ", ") + "."
    }
}

/// Which Macs the screen looks at: all of them, or one against the others
/// (or against one). Row wording, the Differences filter and the order the
/// inspector lists the Macs in all follow it.
private struct Perspective {
    let answered: [String]
    let focus: String?
    let others: [String]
    init(answered: [String], focus: String?, against: String?) {
        self.answered = answered
        self.focus = focus.flatMap { answered.contains($0) ? $0 : nil }
        if let f = self.focus {
            others = against.flatMap { $0 != f && answered.contains($0) ? [$0] : nil } ?? answered.filter { $0 != f }
        } else {
            others = []
        }
    }
    /// The Macs in the order the inspector shows them: the focused one, the
    /// ones it is compared with, then the rest.
    var hosts: [String] {
        guard let f = focus else { return answered }
        return [f] + others + answered.filter { $0 != f && !others.contains($0) }
    }
    func differs(_ item: ClaudeItem) -> Bool {
        guard let f = focus else { return item.differs }
        return item.differs(among: [f] + others)
    }
    func status(_ item: ClaudeItem) -> String {
        guard let f = focus else { return item.status(answered) }
        return item.status(on: f, against: others)
    }
    var matchTitle: String {
        guard let f = focus else { return "All Macs match" }
        return "\(f) matches " + (others.count == 1 ? others[0] : "the other Macs")
    }
    var matchNote: String {
        guard let f = focus else { return "Every Mac that answered has the same Claude Code setup." }
        return "\(f) has the same Claude Code setup as " + (others.count == 1 ? others[0] : "every other Mac that answered") + "."
    }
}

/// A row: kind icon, plain name (marketplace or rule list under it), and
/// what differs in words.
private struct ClaudeRow: View {
    let item: ClaudeItem
    let status: String
    let differs: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ClaudeSetupView.icon(item.kind))
                .foregroundStyle(item.kind == "error" ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                if let q = item.qualifier { Text(q).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 16)
            Text(status)
                .foregroundStyle(item.kind == "error" ? Color.orange : differs ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// The selected item on every Mac that answered.
struct ClaudeInspector: View {
    @EnvironmentObject var model: FleetModel
    let item: ClaudeItem
    let hosts: [String]
    var body: some View {
        let versions = item.versions(hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(item.displayName, systemImage: ClaudeSetupView.icon(item.kind))
                        .font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text([ClaudeItem.title(item.kind).dropLast().description, item.qualifier].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if item.kind == "mcp", let plugin = item.providingPlugin, item.differs {
                    sameEverywhere(plugin)
                }
                ForEach(hosts, id: \.self) { h in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: symbol(h)).foregroundStyle(color(h)).imageScale(.large)
                            Text(h).font(.headline)
                        }
                        Text(item.detail(h, versions: versions))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                            .padding(.leading, 30)
                        if item.kind != "error" {
                            actions(h).padding(.leading, 30).padding(.top, 2)
                                .controlSize(.small).disabled(model.claudeActionRunning)
                        }
                    }
                    Divider()
                }
                if let out = model.claudeAction, model.claudeActionItem == item.id, !out.isEmpty || model.claudeActionRunning {
                    HStack(alignment: .top, spacing: 8) {
                        if model.claudeActionRunning { ProgressView().controlSize(.small) }
                        Text(out.isEmpty ? "Starting…" : out).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    /// An MCP server some Macs get from a plugin and others from their own
    /// entry: one button makes every Mac use the plugin, one copies a Mac's
    /// entry to the rest.
    @ViewBuilder private func sameEverywhere(_ plugin: String) -> some View {
        let short = plugin.split(separator: "@").first.map(String.init) ?? plugin
        let standalone = hosts.filter { item.cell($0) != nil && item.cell($0)?.plugin == nil }
        VStack(alignment: .leading, spacing: 6) {
            Text("Make it run the same on every Mac").font(.subheadline.weight(.semibold))
            Button("Use the \(short) plugin everywhere") { model.claudeUsePlugin(item, hosts: hosts) }
                .help("Installs the \(short) plugin where it is missing, then removes the standalone entries")
            if let src = standalone.first {
                Button("Use \(src)'s entry everywhere") {
                    model.claudeCopy(item, from: src, to: hosts.filter { $0 != src && (item.cell($0) == nil || item.cell($0)?.plugin != nil) })
                }
                Text("Macs with the \(short) plugin would then run it twice; remove the plugin there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small).disabled(model.claudeActionRunning)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// What can be done from this Mac: copy its version to the Macs that
    /// lack it or differ, or remove it here; or, when it lacks the item, get
    /// it from a Mac that has it. Only the Macs that answered are offered.
    @ViewBuilder private func actions(_ h: String) -> some View {
        let others = hosts.filter { $0 != h }
        if let c = item.cell(h), c.plugin != nil {
            Text("Comes with the plugin: remove the plugin to remove it.").font(.caption).foregroundStyle(.secondary)
        } else if let c = item.cell(h) {
            HStack(spacing: 8) {
                // Not onto a Mac that has it through a plugin: it would run twice (the box above says so).
                let behind = others.filter { item.cell($0)?.digest != c.digest && item.cell($0)?.plugin == nil }
                if behind.count == 1 {
                    Button("Copy to \(behind[0])") { model.claudeCopy(item, from: h, to: behind) }
                        .help("Make \(behind[0]) match \(h)")
                } else if !behind.isEmpty {
                    Menu {
                        ForEach(behind, id: \.self) { o in Button("Copy to \(o) Only") { model.claudeCopy(item, from: h, to: [o]) } }
                    } label: {
                        Text(behind.count == others.count && others.count > 1 ? "Copy to Others" : "Copy to " + behind.formatted(.list(type: .and)))
                    } primaryAction: {
                        model.claudeCopy(item, from: h, to: behind)
                    }
                    .fixedSize()
                    .help("Make \(behind.formatted(.list(type: .and))) match \(h)")
                }
                Button("Remove…", role: .destructive) { model.claudeConfirmRemove = ClaudeRemoval(item: item, host: h) }
                    .help("Remove it from \(h)")
            }
        } else {
            let sources = others.filter { item.cell($0) != nil && item.cell($0)?.plugin == nil }   // a plugin's server travels as the plugin
            if sources.count == 1 {
                Button("Get from \(sources[0])") { model.claudeCopy(item, from: sources[0], to: [h]) }
            } else if !sources.isEmpty {
                Menu("Get from") {
                    ForEach(sources, id: \.self) { o in Button(o) { model.claudeCopy(item, from: o, to: [h]) } }
                }
                .fixedSize()
            }
        }
    }
    private func symbol(_ h: String) -> String {
        guard let c = item.cell(h) else { return "minus.circle" }
        if item.kind == "error" { return "exclamationmark.triangle.fill" }
        return c.summary == "disabled" && item.kind == "plugin" ? "pause.circle.fill" : "checkmark.circle.fill"
    }
    private func color(_ h: String) -> Color {
        guard let c = item.cell(h) else { return .secondary }
        if item.kind == "error" || (item.kind == "plugin" && c.summary == "disabled") { return .orange }
        return .green
    }
}

/// A removal waiting for its confirmation.
struct ClaudeRemoval: Identifiable {
    let item: ClaudeItem
    let host: String
    var id: String { item.id + "\u{1F}" + host }
}
