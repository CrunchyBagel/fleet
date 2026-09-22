import SwiftUI

/// A machine: what it is, what is running on it, and start something new.
struct HostView: View {
    @EnvironmentObject var model: FleetModel
    let host: String
    @State private var showNew = false
    @State private var pickedSession: Session.ID?

    var body: some View {
        let rows = model.sessions(on: host)
        VStack(alignment: .leading, spacing: 14) {
            let down = model.downReason(for: host) != nil
            HStack {
                Text(host).font(.title2).bold()
                Spacer()
                Button { model.shell(on: host) } label: { Label("Shell", systemImage: "terminal") }
                    .controlSize(.large).help("A login shell on \(host) in \(Terminal.preferred.title)")
                    .disabled(down)
                if !model.isSelf(host) {
                    Button { model.screenShare(host) } label: { Label("Screen Sharing", systemImage: "display") }
                        .controlSize(.large).help("Open Screen Sharing to \(host)")
                        .disabled(down)
                }
                Button { showNew = true } label: { Label("New session", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(down)
            }
            if let d = model.downReason(for: host) {
                Label("Offline: \(d)", systemImage: "bolt.slash").foregroundStyle(.secondary)
            } else if let i = model.info(for: host) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Chip").foregroundStyle(.secondary); Text("\(i.chip)  ·  \(i.pcores ?? i.cores)P+\(i.ecores ?? 0)E  ·  \(i.memGB) GB") }
                    GridRow { Text("Kind").foregroundStyle(.secondary); Text(i.laptop ? "laptop, may sleep" : "desktop, always on") }
                    GridRow { Text("Model").foregroundStyle(.secondary); Text(i.family.isEmpty ? i.model : "\(i.family)  ·  \(i.model)") }
                }.font(.callout)
            }
            Text(rows.isEmpty ? "No Fleet sessions" : "Sessions").font(.headline).padding(.top, 6)
            if !rows.isEmpty {
                Table(rows, selection: $pickedSession) {
                    TableColumn("Session") { s in Text(s.title) }
                    TableColumn("State") { s in HStack(spacing: 6) { StateDot(session: s); Text(s.badgeWithWait) } }
                    TableColumn("Doing") { s in Text(s.doing ?? "—").foregroundStyle(s.state == "blocked" && s.note?.isEmpty == false ? Color.orange : Color.primary).lineLimit(1).help(s.doing ?? "") }.width(min: 160)
                    TableColumn("Branch") { s in BranchText(session: s) }
                    TableColumn("Context") { s in Text(s.contextPercent.map { "\($0)%" } ?? "—").foregroundStyle(.secondary) }.width(60)
                    TableColumn("Last activity") { s in Text(s.shownTime.map { $0.formatted(.relative(presentation: .named)) } ?? "—").foregroundStyle(.secondary) }
                    TableColumn("Attached") { s in Text(s.attachedFrom.joined(separator: ", ")).foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: Session.ID.self) { ids in
                    if let id = ids.first, let s = model.session(id: id) { SessionMenu(session: s) }
                } primaryAction: { ids in
                    if let id = ids.first { model.selected = .session(id) }
                }
                .frame(minHeight: 120)
            }
            DoctorSection(host: host)
            Spacer(minLength: 0)
        }
        .padding()
        .sheet(isPresented: $showNew) { NewSessionSheet(host: host) }
    }
}

/// `fleet doctor <host>` on demand, and `fleet update <host>` to act on what
/// it says. Doctor is read-only apart from a fetch; update pulls fleet there,
/// pushes the host list and seeds what is missing.
struct DoctorSection: View {
    @EnvironmentObject var model: FleetModel
    let host: String
    var body: some View {
        let report = model.doctor[host]
        let running = model.doctorRunning.contains(host)
        let fails = report?.filter { !$0.ok }.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Doctor").font(.headline)
                if let r = report {
                    Text(fails == 0 ? "all \(r.count) checks pass" : "\(fails) to fix").foregroundStyle(fails == 0 ? .green : .orange)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(report == nil ? "Run doctor" : "Run again") { model.runDoctor(on: host) }.disabled(running)
                Button("Update Fleet") { model.updateFleet(on: host) }
                    .disabled(model.hostBusy[host] != nil || model.downReason(for: host) != nil)
                    .help("fleet update \(host): pull Fleet there, push the host list, seed what is missing")
            }
            if let doing = model.hostBusy[host] {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(doing).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let r = report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(r) { l in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: l.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(l.ok ? Color.green : Color.red).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(l.text).textSelection(.enabled)
                                    if let f = l.fix { Text("fix: \(f)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .frame(maxHeight: 260)
            }
        }
        .padding(.top, 6)
    }
}
