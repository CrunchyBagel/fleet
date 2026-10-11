import SwiftUI

// MARK: - One session

struct SessionDetailView: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let id: String
    @State private var ending: Session?
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        if let s = model.session(id: id) {
            List {
                Section { header(s) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section { actions(s) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())

                // The exchange: what you asked, and the agent's side. An idle
                // notification's note is the reply itself, so that is one row,
                // orange while it waits on you; a permission request is its own row.
                let reply = s.said?.isEmpty == false ? s.said : nil
                let ask = s.state == "blocked" && s.note?.isEmpty == false ? s.note : nil
                let askIsReply = ask != nil && reply != nil && (ask == reply || reply!.hasPrefix(ask!.replacingOccurrences(of: "…", with: "")))
                if s.prompt?.isEmpty == false || ask != nil || reply != nil {
                    Section("Conversation") {
                        if let p = s.prompt, !p.isEmpty { message("You asked", p, symbol: "person.fill", tint: .secondary) }
                        if let a = ask, !askIsReply { message("Needs", a, symbol: "hand.raised.fill", tint: .orange, highlight: true) }
                        if let r = reply {
                            message(askIsReply ? "Waiting on you" : s.state == "done" ? "Replied" : "Last reply", r,
                                    symbol: "sparkle", tint: askIsReply ? .orange : .claude, highlight: askIsReply)
                        }
                    }
                }

                GitSection(session: s)

                Section("Details") {
                    if s.hasStats {
                        if let m = s.model, !m.isEmpty { LabeledContent("Model", value: m) }
                        if let c = s.contextPercent {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Context window", value: "\(c)% full")
                                ProgressView(value: Double(min(c, 100)), total: 100).tint(c >= 90 ? .red : c >= 75 ? .orange : .accentColor)
                            }
                        }
                    }
                    LabeledContent("Last activity", value: s.shownTime.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    LabeledContent("Branch") {
                        Text(s.branch + (s.ahead > 0 ? "  ↑\(s.ahead)" : "") + (s.behind > 0 ? "  ↓\(s.behind)" : "")).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Checkout", value: s.worktree ? "Worktree" : "Main repo")
                    if !s.attachedFrom.isEmpty { LabeledContent("Attached from", value: s.attachedFrom.joined(separator: ", ")) }
                    stacked("Last commit", s.subject.isEmpty ? "—" : s.subject)
                    stacked("Path", s.path, mono: true)
                    stacked("tmux session", s.session, mono: true)
                    if let r = s.remote, !r.isEmpty { stacked("Remote", r, mono: true) }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle(s.title)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refresh(host: s.host) }
            .alert("Rename \(s.title)", isPresented: $renaming) {
                TextField("Name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Rename") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    // Its id changes with the name, so this screen would show it as ended.
                    if !n.isEmpty && n != s.name { Task { await model.renameSession(s, to: n); dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It becomes \(s.project)-<name> on \(s.host), and \(s.host)-\(s.project)-<name> in the Claude apps.")
            }
            .endSessionDialog($ending) { dismiss() }
            .overlay(alignment: .bottom) { Banner() }
        } else {
            ContentUnavailableView("Session ended", systemImage: "moon.zzz", description: Text("It is no longer in Fleet's list."))
        }
    }

    private func header(_ s: Session) -> some View {
        VStack(spacing: 8) {
            ProjectIcon(session: s, size: 72)
            Text(s.name == "main" ? s.project : s.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Text(s.badgeWithWait)
                    .font(.caption.weight(.semibold)).foregroundStyle(s.dotColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(s.dotColor.opacity(0.15)))
                Text(s.name == "main" ? "on \(s.host)" : "\(s.project) on \(s.host)").font(.subheadline).foregroundStyle(.secondary)
                ModelTag(session: s)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4).padding(.bottom, 8)
    }

    private func actions(_ s: Session) -> some View {
        HStack(spacing: 10) {
            if let cu = s.claudeURL {
                Button { openURL(cu) } label: { ActionTile(title: "Claude", brand: Brand.claude, tint: .claude) }
            }
            if let gh = s.githubURL {
                Menu {
                    Button("Repository") { openURL(gh) }
                    Button("This branch") { openURL(gh.appending(path: "tree/\(s.branch)")) }
                    Button("Pull requests for this branch") {
                        var c = URLComponents(url: gh.appending(path: "pulls"), resolvingAgainstBaseURL: false)!
                        c.queryItems = [URLQueryItem(name: "q", value: "is:pr head:\(s.branch)")]
                        openURL(c.url!)
                    }
                    Divider()
                    Button("Issues") { openURL(gh.appending(path: "issues")) }
                    Button("Milestones") { openURL(gh.appending(path: "milestones")) }
                } label: { ActionTile(title: "GitHub", brand: Brand.github, tint: .purple) }
            }
            if !s.worktree {   // a worktree session's name is its worktree's
                Button { newName = s.name == "main" ? "" : s.name; renaming = true } label: { ActionTile(title: "Rename", system: "pencil", tint: .blue) }
            }
            Button { ending = s } label: { ActionTile(title: "End", system: "xmark.octagon", tint: .red) }
        }
        .buttonStyle(.plain)   // several buttons in one row: each takes only its own taps
        .disabled(model.busy != nil)
    }

    private func message(_ label: String, _ text: String, symbol: String, tint: Color, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(text).foregroundStyle(highlight ? Color.orange : Color.primary).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func stacked(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
            Text(value).font(mono ? .footnote.monospaced() : .subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// A tinted square with an icon over a caption: the session's actions.
struct ActionTile: View {
    let title: String
    var system: String = ""
    var brand: String? = nil
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let d = brand { SVGShape(d: d).fill(tint).frame(width: 22, height: 22) }
                else { Image(systemName: system).font(.system(size: 20, weight: .medium)) }
            }
            .frame(height: 24)
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 66)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.13)))
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Work that exists only on the session's machine: uncommitted files and
/// unpushed commits are exactly what another Mac cannot see. State only,
/// from the record (fleet is not a git client); "behind" is as of that
/// machine's last fetch.
struct GitSection: View {
    let session: Session

    private var unpushed: (title: String, detail: String, warn: Bool) {
        if session.upstream.isEmpty {
            if session.remote?.isEmpty != false { return ("No remote", "This repository exists only on \(session.host)", true) }
            return ("Never pushed", "\(session.branch) is not on origin yet", true)
        }
        if session.ahead > 0 { return ("\(session.ahead) commit\(session.ahead == 1 ? "" : "s") not pushed", "to \(session.upstream)", true) }
        return ("Everything pushed", "\(session.upstream) has every commit", false)
    }

    var body: some View {
        Section("Only on \(session.host)") {
            row(session.dirty ? "Uncommitted changes" : "Working tree clean",
                session.dirty ? "Changes in the working tree that no other Mac has" : "Nothing uncommitted", warn: session.dirty)
            row(unpushed.title, unpushed.detail, warn: unpushed.warn)
            if session.behind > 0 {
                row("\(session.behind) commit\(session.behind == 1 ? "" : "s") behind",
                    "On \(session.upstream), not here yet (as of \(session.host)'s last fetch)", warn: false, symbol: "arrow.down.circle.fill", tint: .blue)
            }
        }
    }

    private func row(_ title: String, _ detail: String, warn: Bool, symbol: String? = nil, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol ?? (warn ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                .foregroundStyle(tint ?? (warn ? Color.orange : Color.green))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
