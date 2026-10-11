import SwiftUI

// MARK: - New session: pick a project, then how to start it

struct NewSessionSheet: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    let host: String
    @State private var filter = ""

    /// Projects there narrowed by the search (any part of the name), as `fleet projects` ranks them.
    private var shown: [ProjectEntry] {
        let all = model.projects[host] ?? []
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.project.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List(shown, id: \.project) { p in
                NavigationLink(value: p) {
                    HStack(spacing: 12) {
                        ProjectGlyph(project: p)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.project).font(.body.weight(.medium))
                            Text(p.layout).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.claude {
                            Text("claude").font(.caption2.weight(.semibold)).foregroundStyle(Color.claude)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.claude.opacity(0.14)))
                        }
                    }
                }
            }
            .overlay {
                if model.projects[host] == nil {
                    ProgressView("Listing projects on \(host)…")
                } else if model.projects[host]?.isEmpty == true {
                    // Nothing at all: FLEET_ROOT there is empty or wrong.
                    ContentUnavailableView("No projects", systemImage: "folder",
                                           description: Text("Nothing under FLEET_ROOT on \(host). Set FLEET_ROOT in its ~/.config/fleet/config; Doctor on the machine screen shows the path."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: filter)
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Projects on \(host)")
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ProjectEntry.self) { p in NewSessionOptions(host: host, project: p.project) { dismiss() } }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                async let m: Void = model.loadModels(on: host)
                await model.loadProjects(on: host)
                await m
            }
        }
    }
}

/// The project's icon when one was already fetched for a session, else its
/// first letter on a quiet tile (no `fleet icon` per row: it can run actool).
struct ProjectGlyph: View {
    @EnvironmentObject var model: MobileModel
    let project: ProjectEntry
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Group {
            if let i = model.icons[Session.repoKey(project.remote) ?? project.project.lowercased()] {
                Image(uiImage: i).resizable()
            } else {
                shape.fill(Color.secondary.opacity(0.15))
                    .overlay(Text(project.project.prefix(1).uppercased()).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.secondary))
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(shape)
    }
}

/// Second step: a new conversation or an earlier one (`fleet history`),
/// the model (`fleet models`), and the session's name. Stays up while
/// starting and says what went wrong if it fails.
struct NewSessionOptions: View {
    @EnvironmentObject var model: MobileModel
    let host: String
    let project: String
    let done: () -> Void
    @State private var name = ""
    @State private var chosenModel = ""        // catalog id; "" = the default row (no --model)
    @State private var resume = ""             // conversation id; "" = New conversation
    @State private var history: [HistoryEntry]?
    @State private var historyError: String?
    @State private var starting = false
    @State private var failure: String?
    private var picked: HistoryEntry? { history?.first { $0.id == resume } }

    var body: some View {
        Form {
            Section {
                choice(resume.isEmpty) { resume = "" } label: {
                    Label("New conversation", systemImage: "plus.bubble")
                }
                if let h = history {
                    ForEach(h) { c in
                        choice(resume == c.id) { resume = c.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(c.label).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text(c.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated)).font(.caption).foregroundStyle(.secondary)
                                }
                                if !c.prompt.isEmpty { Text(c.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                    }
                } else if let e = historyError {
                    Text(e).font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) { ProgressView(); Text("Earlier conversations…").foregroundStyle(.secondary) }.font(.callout)
                }
            } header: { Text("Conversation") } footer: {
                if history?.isEmpty == true { Text("No earlier conversations in \(project).") }
            }

            Section {
                // The host's Claude Code catalog, its own default first. That
                // row passes no --model, so what Claude Code would pick on its
                // own, a [1m] variant included, is what it gets.
                Picker("Model", selection: $chosenModel) {
                    if let list = model.models[host] {
                        if let d = list.resolvedDefault { Text("\(d.name) (default)").tag("") } else { Text("Automatic").tag("") }
                        ForEach(list.models.filter { $0.section == "main" && $0.id != list.resolvedDefault?.id }, id: \.id) { Text($0.name).tag($0.id) }
                        ForEach(list.models.filter { $0.section != "main" && $0.id != list.resolvedDefault?.id }, id: \.id) { Text($0.name).tag($0.id) }
                    } else {
                        Text("Automatic").tag("")
                    }
                }
                .disabled(model.models[host] == nil)
                TextField(picked.map { $0.name.isEmpty ? "Name (empty = main)" : "Name (empty = \($0.name))" } ?? "Name (empty = main)", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("A name adds a second session in the same repo, or a worktree once the project is converted. It starts Claude Code with Remote Control, so it shows in the Claude app.")
            }

            if let f = failure {
                Section { Label(f, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }
            }
        }
        .navigationTitle(project)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if starting { ProgressView() } else { Button(picked == nil ? "Start" : "Resume") { start() }.fontWeight(.semibold) }
            }
        }
        .disabled(starting)
        .task {
            guard history == nil, historyError == nil else { return }
            do { history = try await model.history(on: host, project: project) }
            catch { historyError = "Could not list conversations: \(error.localizedDescription)" }
        }
    }

    private func choice<L: View>(_ on: Bool, _ pick: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: pick) {
            HStack {
                label().foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor).opacity(on ? 1 : 0)
            }
        }
    }

    private func start() {
        failure = nil; starting = true
        Task {
            do {
                try await model.newSession(on: host, project: project, name: name.trimmingCharacters(in: .whitespaces),
                                           model: chosenModel, resume: resume)
                starting = false
                done()
            } catch {
                starting = false
                failure = error.localizedDescription
            }
        }
    }
}
