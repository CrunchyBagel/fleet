import SwiftUI

/// Where the overview's rows lead.
enum Route: Hashable { case session(String), host(String) }

// MARK: - Overview: usage, a count of what needs you, every machine with its sessions

struct OverviewView: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.openURL) private var openURL
    @State private var newOn: String?
    @State private var ending: Session?
    @State private var showSettings = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        List {
            if !model.sessions.isEmpty || model.usage != nil {
                Section { SummaryCard() }
            }
            ForEach(model.orderedHosts, id: \.self) { h in
                Section {
                    NavigationLink(value: Route.host(h)) { HostRowView(host: h) }
                    if let d = model.down[h] {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                    } else if !model.loading(h) {
                        ForEach(model.sessions(on: h)) { s in
                            NavigationLink(value: Route.session(s.id)) { SessionRowView(session: s) }
                                .swipeActions(edge: .trailing) {
                                    Button { ending = s } label: { Label("End", systemImage: "xmark.octagon") }.tint(.red)
                                }
                                .swipeActions(edge: .leading) {
                                    if let u = s.claudeURL {
                                        Button { openURL(u) } label: { Label("Claude", systemImage: "bubble.left.and.text.bubble.right") }.tint(.claude)
                                    }
                                }
                                .contextMenu { SessionMenu(session: s, ending: $ending) }
                        }
                        Button { newOn = h } label: {
                            Label("New session", systemImage: "plus.circle.fill").font(.subheadline.weight(.medium))
                        }
                    }
                }
            }
            if let t = model.lastRefresh {
                Section { } footer: {
                    Text("Updated \(t.formatted(date: .omitted, time: .standard))").frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Fleet")
        .navigationDestination(for: Route.self) { r in
            switch r {
            case .session(let id): SessionDetailView(id: id)
            case .host(let h): HostDetailView(host: h)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            ToolbarItem(placement: .topBarTrailing) {
                if model.refreshing { ProgressView() } else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") } }
            }
        }
        .refreshable { await model.refresh() }
        .task(id: model.hosts) { await poll() }
        // Connections do not survive the phone sleeping: close them on the
        // way out rather than finding them dead on the way back.
        .onChange(of: phase) { _, p in if p == .background { model.resetConnections() } }
        .sheet(item: $newOn) { h in NewSessionSheet(host: h) }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .endSessionDialog($ending)
        .overlay(alignment: .bottom) { Banner() }
    }

    /// Poll while this screen is up; SwiftUI cancels the task when it goes.
    /// Each host is its own loop, so a slow one only delays its own section.
    private func poll() async {
        await withTaskGroup(of: Void.self) { g in
            for h in model.hosts {
                g.addTask {
                    while !Task.isCancelled {
                        await model.refresh(host: h)
                        try? await Task.sleep(for: .seconds(10))
                    }
                }
            }
        }
    }
}

extension String: @retroactive Identifiable { public var id: String { self } }

extension Color {
    /// The Claude mark's colour, for its buttons.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// The top of the overview: the account's limits as two rings, and how
/// many agents are working or waiting on you.
struct SummaryCard: View {
    @EnvironmentObject var model: MobileModel
    var body: some View {
        let waiting = model.needsYou.count
        let running = model.sessions.filter { $0.state == "running" }.count
        HStack(spacing: 18) {
            if let u = model.usage {
                UsageRing(title: "5-hour", pct: u.fiveHour, resets: u.fiveHourResets)
                UsageRing(title: "7-day", pct: u.sevenDay, resets: u.sevenDayResets)
                Divider().frame(height: 56)
            }
            VStack(alignment: .leading, spacing: 8) {
                if waiting > 0 {
                    stat("\(waiting)", waiting == 1 ? "needs you" : "need you", .orange)
                } else {
                    Label("Nothing waiting", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.medium)).foregroundStyle(.green)
                }
                stat("\(running)", "working", running > 0 ? .green : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
    private func stat(_ n: String, _ what: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(n).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(tint)
            Text(what).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// One usage limit as a ring, with when it resets.
struct UsageRing: View {
    let title: String
    let pct: Int?
    let resets: Date?
    var body: some View {
        let p = pct ?? 0
        VStack(spacing: 4) {
            Gauge(value: Double(min(p, 100)), in: 0...100) { Text(title) } currentValueLabel: {
                Text(pct.map { "\($0)%" } ?? "–").font(.system(.body, design: .rounded).weight(.semibold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(p >= 90 ? .red : p >= 70 ? .orange : .accentColor)
            Text(title).font(.caption.weight(.medium))
            if let r = resets {
                Text(r, format: .relative(presentation: .numeric, unitsStyle: .abbreviated)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// A machine's row: what kind of Mac, its chip, and whether it answers.
struct HostRowView: View {
    @EnvironmentObject var model: MobileModel
    let host: String
    var body: some View {
        let info = model.infos[host], down = model.down[host] != nil
        let waiting = model.sessions(on: host).filter { $0.state == "blocked" }.count
        HStack(spacing: 12) {
            Image(systemName: info?.symbol ?? "desktopcomputer")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(down ? Color.secondary : Color.accentColor)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((down ? Color.secondary : Color.accentColor).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(host).font(.headline)
                Group {
                    if down { Text("Offline") }
                    else if model.loading(host) { Text("Connecting…") }
                    else if let i = info { Text([i.modelTitle, i.chip].filter { !$0.isEmpty }.joined(separator: " · ")) }
                    else { Text(" ") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.loading(host) { ProgressView() }
            else if waiting > 0 {
                Text("\(waiting)").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(.orange))
            }
        }
    }
}

/// One session: its project's icon with the state dot, the name, and a
/// second line with what it is doing (the question, orange, while blocked).
struct SessionRowView: View {
    let session: Session
    var body: some View {
        let blocked = session.state == "blocked"
        HStack(spacing: 12) {
            ProjectIcon(session: session, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.name == "main" ? session.project : session.name).font(.body.weight(.semibold)).lineLimit(1)
                    if session.name != "main" { Text(session.project).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    trailing.font(.caption).monospacedDigit()
                }
                HStack(spacing: 6) {
                    ModelTag(session: session)
                    Text(session.doing ?? session.branch)
                        .font(.subheadline)
                        .foregroundStyle(blocked && session.note?.isEmpty == false ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
    @ViewBuilder private var trailing: some View {
        switch session.state {
        case "blocked": Text(session.waiting ?? "needs you").foregroundStyle(.orange)
        case "running": Text("working").foregroundStyle(.green)
        default:
            if let t = session.shownTime { Text(t, format: .relative(presentation: .numeric, unitsStyle: .abbreviated)).foregroundStyle(.secondary) }
        }
    }
}

/// The project's app icon (`fleet icon`), else its initials on its own
/// colour, rounded like an app icon, with the state dot on its corner.
struct ProjectIcon: View {
    @EnvironmentObject var model: MobileModel
    let session: Session
    var size: CGFloat = 40
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let image = model.icons[session.projectKey] {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                shape.fill(session.projectColor.gradient)
                    .overlay(Text(session.projectInitials)
                        .font(.system(size: size * (session.projectInitials.count > 1 ? 0.4 : 0.5), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(session.dotColor)
                .frame(width: max(10, size * 0.26), height: max(10, size * 0.26))
                .overlay(Circle().strokeBorder(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2.5))
                .offset(x: 4, y: 4)
        }
        .task(id: session.projectKey) { model.loadIcon(for: session) }
    }
}

/// Long-press menu on a session row.
struct SessionMenu: View {
    @Environment(\.openURL) private var openURL
    let session: Session
    @Binding var ending: Session?
    var body: some View {
        if let u = session.claudeURL { Button { openURL(u) } label: { Label("Open in Claude", systemImage: "bubble.left.and.text.bubble.right") } }
        if let gh = session.githubURL { Button { openURL(gh) } label: { Label("Open on GitHub", systemImage: "link") } }
        Divider()
        Button(role: .destructive) { ending = session } label: { Label("End Session…", systemImage: "xmark.octagon") }
    }
}

extension View {
    /// The End confirmation, shared by the overview's swipe and the session screen.
    func endSessionDialog(_ ending: Binding<Session?>, then: @escaping () -> Void = {}) -> some View {
        modifier(EndSessionDialog(ending: ending, then: then))
    }
}

private struct EndSessionDialog: ViewModifier {
    @EnvironmentObject var model: MobileModel
    @Binding var ending: Session?
    let then: () -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog("End \(ending?.title ?? "") on \(ending?.host ?? "")?",
                                   isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                                   titleVisibility: .visible, presenting: ending) { s in
            Button("End Session", role: .destructive) { Task { await model.endSession(s); then() } }
        } message: { s in
            Text(s.worktree ? "The agent is asked to exit, then the tmux session is closed. The worktree and its branch stay."
                            : "The agent is asked to exit, then the tmux session is closed. Uncommitted work is untouched.")
        }
    }
}

/// Errors and progress, at the bottom, dismissable.
struct Banner: View {
    @EnvironmentObject var model: MobileModel
    var body: some View {
        Group {
            if let b = model.busy {
                HStack(spacing: 10) { ProgressView(); Text(b) }.font(.callout)
            } else if let e = model.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.callout)
                    Spacer(minLength: 0)
                    Button { model.error = nil } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding()
        .opacity(model.busy == nil && model.error == nil ? 0 : 1)
        .allowsHitTesting(model.busy != nil || model.error != nil)
        .animation(.easeInOut(duration: 0.2), value: model.busy == nil && model.error == nil)
    }
}
