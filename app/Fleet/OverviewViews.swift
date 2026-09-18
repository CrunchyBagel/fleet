import SwiftUI

/// The overview: every machine in one table, with what needs you on top.
struct Overview: View {
    @EnvironmentObject var model: FleetModel
    @Binding var selected: Item?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Machines").font(.title2).bold()
                Spacer()
                if model.needsYou > 0 {
                    Label("\(model.needsYou) need\(model.needsYou == 1 ? "s" : "") you", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.headline)
                }
            }
            if let u = model.usage { UsageView(usage: u) }
            MachinesTable(selected: $selected)
            if let t = model.lastRefresh {
                Text("Updated \(t.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

/// The account's 5-hour and 7-day limits, from the freshest status line
/// snapshot fleet has seen on any machine.
struct UsageView: View {
    let usage: UsageLimits
    var body: some View {
        GroupBox {
            HStack(spacing: 28) {
                meter("5-hour limit", usage.fiveHour, usage.fiveHourResets)
                meter("7-day limit", usage.sevenDay, usage.sevenDayResets)
                Spacer()
                Text("as of \(usage.at.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: { Text("Claude usage").font(.headline) }
    }
    @ViewBuilder private func meter(_ title: String, _ pct: Int?, _ resets: Date?) -> some View {
        if let p = pct {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.callout)
                    Text("\(p)%").font(.callout.weight(.semibold)).foregroundStyle(p >= 90 ? Color.red : p >= 70 ? Color.orange : Color.primary)
                }
                ProgressView(value: Double(min(p, 100)), total: 100).frame(width: 160)
                    .tint(p >= 90 ? .red : p >= 70 ? .orange : .accentColor)
                if let r = resets { Text("resets \(r.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Click selects, double-click opens the machine as if picked in the sidebar.
struct MachinesTable: View {
    @EnvironmentObject var model: FleetModel
    @Binding var selected: Item?
    @State private var picked: MachineRow.ID?
    var body: some View {
        Table(model.machines, selection: $picked) {
            TableColumn("Host") { m in
                HStack(spacing: 6) {
                    Circle().fill(m.down == nil ? Color.green : Color.gray.opacity(0.4)).frame(width: 9, height: 9)
                    Text(m.host).fontWeight(.semibold).foregroundStyle(m.down == nil ? .primary : .secondary)
                }
            }.width(min: 110)
            TableColumn("Status") { m in
                Text(m.down == nil ? "Online" : "Offline").foregroundStyle(m.down == nil ? .green : .secondary).help(m.down ?? "")
            }.width(min: 70)
            TableColumn("Model") { m in
                HStack(spacing: 6) {
                    if let i = m.info { Image(systemName: i.symbol).foregroundStyle(.secondary) }
                    Text(m.info?.modelTitle ?? "—")
                }
            }.width(min: 120)
            TableColumn("Chip") { m in Text(m.info?.chip ?? "—") }
            TableColumn("Cores") { m in Text(m.info.map { "\($0.pcores ?? $0.cores)P+\($0.ecores ?? 0)E" } ?? "—") }
            TableColumn("Memory") { m in Text(m.info.map { "\($0.memGB) GB" } ?? "—") }
            TableColumn("Kind") { m in Text(m.info.map { $0.laptop ? "laptop, may sleep" : "desktop" } ?? "—") }
            TableColumn("Sessions") { m in Text(m.info == nil ? "—" : "\(m.sessions)") }
        }
        .contextMenu(forSelectionType: MachineRow.ID.self) { _ in } primaryAction: { ids in
            if let h = ids.first { selected = .host(h) }
        }
    }
}
