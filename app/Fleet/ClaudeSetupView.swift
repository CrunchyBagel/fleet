import SwiftUI

/// The Claude Setup screen: every Claude Code setup item that differs
/// between the Macs (`fleet claude --json`), as a list that says in words
/// what differs, and an inspector showing the selected item on each Mac.
/// Permission rules sit in a collapsed section: they outnumber everything
/// else and matter less. The bar above the list (its choice always in
/// view) turns it into one Mac's report (what it has or lacks
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
                Text(Self.removalNote(r.item, on: r.host))
            }
    }

    /// What Remove does, in plain words, so the confirmation is not scarier than the change.
    static func removalNote(_ item: ClaudeItem, on host: String) -> String {
        let backup = "The first time fleet changes that file it keeps a copy of the original next to it (.fleet-backup)."
        switch item.kind {
        case "setting":
            return "Only the \(item.name) line is taken out of ~/.claude/settings.json on \(host); Claude Code then uses its default. Nothing else in the file changes. " + backup
        case "perm":
            return "Only this rule is taken out of ~/.claude/settings.json on \(host); the other rules stay. " + backup
        case "file":
            return "~/.claude/\(item.name) is deleted on \(host). A copy is kept as \(item.name).fleet-backup, unless fleet already kept one from an earlier change."
        default:
            return "Claude Code on \(host) removes it, as its own remove command would."
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
                // The default model is the setting people look for: first.
                return rows.isEmpty ? nil : (k, rows.filter { $0.name == "model" } + rows.filter { $0.name != "model" })
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
    /// is compared with, and whether to list only what differs. Every control
    /// is always there and sized to its content, so nothing shifts or
    /// truncates when a choice changes; the second one is merely disabled
    /// while every Mac is shown.
    private func scopeBar(answered: [String]) -> some View {
        HStack(spacing: 20) {
            Picker("Mac:", selection: $focus) {
                Text("All Macs").tag(String?.none)
                Divider()
                ForEach(answered, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu).fixedSize()
            .help("Every Mac at once, or one Mac's report: what it has or lacks")
            Picker("Compared with:", selection: $against) {
                Text(focus == nil ? "—" : "All others").tag(String?.none)
                if let f = focus {
                    Divider()
                    ForEach(answered.filter { $0 != f }, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            .pickerStyle(.menu).fixedSize()
            .disabled(focus == nil)
            .help(focus.map { "Compare \($0) with every other Mac, or with one of them" } ?? "Choose a Mac first")
            Spacer(minLength: 0)
            Picker("Show:", selection: $onlyDifferences) {
                Text("Differences").tag(true)
                Text("All").tag(false)
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Show only what differs, or everything")
        }
        .controlSize(.small)
        // A flexible frame, so the bar reports no minimum width of its own:
        // a detail column whose minimum size changes while it is being laid
        // out (switching to this screen with the data already loaded, or a
        // refresh) makes AppKit throw from updateConstraints and the app abort.
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
            .layoutPriority(1)                    // the name stays readable; a long value gives way
            Spacer(minLength: 16)
            Text(status)
                .foregroundStyle(item.kind == "error" ? Color.orange : differs ? Color.primary : Color.secondary)
                .lineLimit(1)
                .help(status)
        }
        .padding(.vertical, 2)
    }
}

/// The selected item on every Mac that answered.
struct ClaudeInspector: View {
    @EnvironmentObject var model: FleetModel
    let item: ClaudeItem
    let hosts: [String]
    @State private var viewing: String?        // a file's contents in a sheet, starting on this Mac
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
                        // A setting's value is what matters there: in full, not greyed out.
                        let value = item.kind == "setting" && item.name != "env" && item.cell(h) != nil
                        Text(item.detail(h, versions: versions))
                            .font(value ? .body.monospaced() : .body)
                            .foregroundStyle(value ? .primary : .secondary).textSelection(.enabled)
                            .padding(.leading, 30)
                        if item.kind == "file", item.cell(h) != nil {
                            Button("View") { viewing = h }.controlSize(.small).padding(.leading, 30)
                                .help("Show \(item.name) as it is on \(h)")
                        }
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
        .sheet(item: Binding(get: { viewing.map { FileOnMac(host: $0) } }, set: { viewing = $0?.host })) { v in
            ClaudeFileSheet(item: item, hosts: hosts.filter { item.cell($0) != nil }, versions: versions, host: v.host)
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

    /// What can be done from this Mac, in the words of what happens: a
    /// plugin is installed from its marketplace (only its enabled state comes
    /// from here), a marketplace is added by its repo, an MCP entry, a
    /// setting, a rule or a file is copied. Or, when this Mac lacks the item,
    /// get it: "Install from <marketplace>", "Add <repo>", "Copy from <Mac>".
    /// Only the Macs that answered are offered.
    @ViewBuilder private func actions(_ h: String) -> some View {
        let others = hosts.filter { $0 != h }
        if let c = item.cell(h), c.plugin != nil {
            Text("Comes with the plugin: remove the plugin to remove it.").font(.caption).foregroundStyle(.secondary)
        } else if let c = item.cell(h) {
            HStack(spacing: 8) {
                // Not onto a Mac that has it through a plugin: it would run twice (the box above says so).
                let behind = others.filter { item.cell($0)?.digest != c.digest && item.cell($0)?.plugin == nil }
                let lacking = behind.filter { item.cell($0) == nil }, differing = behind.filter { item.cell($0) != nil }
                switch item.kind {
                case "plugin":
                    push("Install", "on", to: lacking, from: h, all: others.count)
                    push(c.summary == "disabled" ? "Disable" : "Enable", "on", to: differing, from: h, all: others.count)
                case "marketplace":
                    push("Add", "on", to: lacking, from: h, all: others.count)
                    push("Copy", "to", to: differing, from: h, all: others.count)
                case "mcp":
                    push("Copy entry", "to", to: behind, from: h, all: others.count)
                default:
                    push("Copy", "to", to: behind, from: h, all: others.count)
                }
                Button("Remove…", role: .destructive) { model.claudeConfirmRemove = ClaudeRemoval(item: item, host: h) }
                    .help("Remove it from \(h)")
            }
        } else {
            let sources = others.filter { item.cell($0) != nil && item.cell($0)?.plugin == nil }   // a plugin's server travels as the plugin
            if sources.isEmpty {
                EmptyView()
            } else if item.kind == "plugin" {
                // The install is from the marketplace whichever Mac is the source; take the enabled state from one that has it on.
                let src = sources.first { item.cell($0)?.summary != "disabled" } ?? sources[0]
                Button("Install from \(item.qualifier ?? "its marketplace")") { model.claudeCopy(item, from: src, to: [h]) }
                    .help("claude plugin install on \(h); adds the marketplace there first if it lacks it")
            } else if item.kind == "marketplace" {
                let repo = item.cell(sources[0])?.summary ?? ""
                Button(repo.isEmpty ? "Add from \(sources[0])" : "Add \(repo)") { model.claudeCopy(item, from: sources[0], to: [h]) }
                    .help("claude plugin marketplace add on \(h)")
            } else {
                let verb = item.kind == "mcp" ? "Copy entry" : "Copy"
                if sources.count == 1 {
                    Button("\(verb) from \(sources[0])") { model.claudeCopy(item, from: sources[0], to: [h]) }
                } else {
                    Menu("\(verb) from") {
                        ForEach(sources, id: \.self) { o in Button(o) { model.claudeCopy(item, from: o, to: [h]) } }
                    }
                    .fixedSize()
                }
            }
        }
    }
    /// "<verb> <prep> mini", or a split button "<verb> <prep> Others" (every
    /// other Mac) / "… mini and mbp16" whose menu takes them one at a time.
    @ViewBuilder private func push(_ verb: String, _ prep: String, to targets: [String], from h: String, all: Int) -> some View {
        if targets.count == 1 {
            Button("\(verb) \(prep) \(targets[0])") { model.claudeCopy(item, from: h, to: targets) }
                .help("Make \(targets[0]) match \(h)")
        } else if !targets.isEmpty {
            Menu {
                ForEach(targets, id: \.self) { o in Button("\(verb) \(prep) \(o) Only") { model.claudeCopy(item, from: h, to: [o]) } }
            } label: {
                Text("\(verb) \(prep) " + (targets.count == all && all > 1 ? "Others" : targets.formatted(.list(type: .and))))
            } primaryAction: {
                model.claudeCopy(item, from: h, to: targets)
            }
            .fixedSize()
            .help("Make \(targets.formatted(.list(type: .and))) match \(h)")
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

private struct FileOnMac: Identifiable {
    let host: String
    var id: String { host }
}

/// A file (CLAUDE.md, a script) as it is on one Mac, read with `fleet
/// claude show`; the pop-up switches between the Macs that have it,
/// lettered when their copies differ.
private struct ClaudeFileSheet: View {
    let item: ClaudeItem
    let hosts: [String]
    let versions: [String: String]
    @State var host: String
    @State private var text: [String: String] = [:]
    @State private var failed: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(item.name, systemImage: "doc.text").font(.headline)
                Spacer()
                Picker("On", selection: $host) {
                    ForEach(hosts, id: \.self) { h in
                        Text(versions.count > 1 ? "\(h) · version \(versions[item.cell(h)?.digest ?? ""] ?? "?")" : h).tag(h)
                    }
                }
                .pickerStyle(.menu).fixedSize()
            }
            .padding(12)
            Divider()
            Group {
                if let t = text[host] {
                    ScrollView([.vertical, .horizontal]) {
                        Text(t).font(.body.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    }
                } else if let e = failed[host] {
                    ContentUnavailableView("Could not read it", systemImage: "exclamationmark.triangle", description: Text(e))
                } else {
                    ProgressView("Reading it on \(host)…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 640)
        .task(id: host) {
            guard text[host] == nil else { return }
            let h = host
            do { text[h] = try await FleetCLI.claudeFile(item.name, on: h); failed[h] = nil }
            catch { failed[h] = error.localizedDescription }
        }
    }
}
