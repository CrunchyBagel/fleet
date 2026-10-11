import SwiftUI

// MARK: - Settings and onboarding

struct SettingsView: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var discovering = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("ssh") {
                TextField("Username on your Macs", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                KeyRow()
            }
            Section {
                ForEach(model.hosts, id: \.self) { h in
                    HStack { Text(h); Spacer(); if model.down[h] != nil { Image(systemName: "bolt.slash").foregroundStyle(.secondary) } }
                }
                .onDelete { idx in var h = model.hosts; h.remove(atOffsets: idx); model.hosts = h }
                HStack {
                    TextField("Add a Mac by tailnet name", text: $entry).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") { model.hosts = model.hosts + [entry.trimmingCharacters(in: .whitespaces)]; entry = "" }
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if discovering { HStack { ProgressView(); Text("Asking your Macs…") } }
                else { Button("Refresh host list from a Mac") { discover() }.disabled(model.hosts.isEmpty) }
                if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Hosts") } footer: {
                Text("Refresh asks the first Mac that answers for ~/.config/fleet/hosts, the list every Mac shares. The phone must be on the tailnet (Tailscale app).")
            }
            Section {
                Button("Forget pinned host keys") { HostKeys.forgetAll(); model.resetConnections(); message = "Host keys forgotten; the next connection to each Mac pins its key again." }
            } footer: {
                Text("Each Mac's ssh host key is pinned on first connection. Forget them only after reinstalling macOS on a Mac.")
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func discover() {
        discovering = true; message = nil
        Task {
            do { let (h, from) = try await model.refreshHosts(); model.hosts = h; message = "From \(from): \(h.joined(separator: ", "))" }
            catch { message = error.localizedDescription }
            discovering = false
        }
    }
}

/// The phone's public key, with the one command that authorizes it everywhere.
struct KeyRow: View {
    @State private var line = (try? KeyStore.publicKeyLine()) ?? ""
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This phone's key").font(.caption).foregroundStyle(.secondary)
            Text(line).font(.caption2.monospaced()).lineLimit(3).truncationMode(.middle)
            HStack {
                Button(copied ? "Copied" : "Copy `fleet keys add` command") {
                    UIPasteboard.general.string = "fleet keys add \"\(line)\""; copied = true
                }
                .font(.callout)
            }
            Text("Run that on any Mac with Fleet installed: it authorizes the key on every Mac in the fleet. Revoke with fleet keys rm \(KeyStore.comment).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: MobileModel
    @State private var entry = ""
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Text("Fleet runs the fleet command on your Macs over ssh, through Tailscale. Three things to set up: your username there, this phone's key on the Macs, and one Mac to ask for the host list.")
                    .font(.callout)
            }
            Section("1. Username on your Macs") {
                TextField("username", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("2. Authorize this phone") { KeyRow() }
            Section("3. One Mac's tailnet name") {
                TextField("e.g. mini", text: $entry).textInputAutocapitalization(.never).autocorrectionDisabled()
                if working { HStack { ProgressView(); Text("Connecting…") } }
                else { Button("Connect and fetch the host list") { connect() }.disabled(entry.isEmpty || model.username.isEmpty) }
                if let m = message { Text(m).font(.callout).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Set up Fleet")
    }
    private func connect() {
        working = true; message = nil
        Task {
            do { model.hosts = try await model.discoverHosts(from: entry) }
            catch { message = error.localizedDescription }
            working = false
        }
    }
}
