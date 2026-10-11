import SwiftUI

// MARK: - One machine: what it is, its sessions, and its doctor report

struct HostDetailView: View {
    @EnvironmentObject var model: MobileModel
    let host: String
    @State private var showNew = false
    @State private var ending: Session?
    @State private var copied = false

    var body: some View {
        let info = model.infos[host], down = model.down[host]
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: info?.symbol ?? "desktopcomputer")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(down == nil ? Color.accentColor : Color.secondary)
                        .frame(width: 76, height: 76)
                        .background(Circle().fill((down == nil ? Color.accentColor : Color.secondary).opacity(0.13)))
                    Text(host).font(.title2.weight(.bold))
                    Label(down == nil ? "Online" : "Offline", systemImage: "circle.fill")
                        .labelStyle(DotLabel())
                        .font(.caption.weight(.semibold)).foregroundStyle(down == nil ? .green : .secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)

            if let d = down {
                Section { Label(d, systemImage: "bolt.slash").font(.callout).foregroundStyle(.secondary) }
            } else if let i = info {
                Section("Machine") {
                    LabeledContent("Model", value: i.family.isEmpty ? i.model : "\(i.family) (\(i.model))")
                    LabeledContent("Chip", value: i.chip)
                    LabeledContent("Cores", value: "\(i.cores) (\(i.pcores ?? i.cores) performance, \(i.ecores ?? 0) efficiency)")
                    LabeledContent("Memory", value: "\(i.memGB) GB")
                    LabeledContent("Kind", value: i.laptop ? "Laptop, may sleep" : "Desktop, always on")
                }
            }

            if down == nil {
                Section("Sessions") {
                    ForEach(model.sessions(on: host)) { s in
                        NavigationLink(value: Route.session(s.id)) { SessionRowView(session: s) }
                            .contextMenu { SessionMenu(session: s, ending: $ending) }
                    }
                    Button { showNew = true } label: { Label("New session", systemImage: "plus.circle.fill").font(.subheadline.weight(.medium)) }
                }
                doctorSection
            }
        }
        .navigationTitle(host)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(host: host) }
        .sheet(isPresented: $showNew) { NewSessionSheet(host: host) }
        .endSessionDialog($ending)
        .overlay(alignment: .bottom) { Banner() }
    }

    /// `fleet doctor --local` there, on demand: read-only apart from a fetch.
    @ViewBuilder private var doctorSection: some View {
        let report = model.doctor[host], running = model.doctorRunning.contains(host)
        let fails = report?.filter { !$0.ok }.count ?? 0
        Section {
            if let r = report {
                ForEach(r) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: l.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(l.ok ? Color.green : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.text).font(.subheadline).textSelection(.enabled)
                            if let f = l.fix { Text("fix: \(f)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
            }
            Button { Task { await model.runDoctor(on: host) } } label: {
                HStack {
                    Label(report == nil ? "Run Doctor" : "Run Again", systemImage: "stethoscope")
                    Spacer()
                    if running { ProgressView() }
                }
            }
            .disabled(running)
            if let text = model.doctorText[host] {
                Button { UIPasteboard.general.string = text; copied = true } label: {
                    Label(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        } header: {
            HStack {
                Text("Doctor")
                Spacer()
                if let r = report {
                    Text(fails == 0 ? "All \(r.count) checks pass" : "\(fails) to fix").foregroundStyle(fails == 0 ? .green : .orange)
                }
            }
        } footer: {
            Text("Checks fleet's setup on \(host). To fix what it reports, run fleet update \(host) from a Mac.")
        }
    }
}

/// A small coloured dot before the text, for a status line.
struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 7)); configuration.title }
    }
}
