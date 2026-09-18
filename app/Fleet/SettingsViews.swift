import SwiftUI
import ServiceManagement

/// Cmd-, : General (terminal, polling, which sessions, the fleet command)
/// and Buttons (which actions a session shows; web projects have no use for
/// Xcode). Keys and defaults live in `Prefs`.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ButtonSettings().tabItem { Label("Buttons", systemImage: "rectangle.3.group") }
            HostSettings().tabItem { Label("Hosts", systemImage: "network") }
        }
        .frame(width: 480, height: 640)
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.terminal) private var terminal = Terminal.preferred.rawValue
    @AppStorage(Prefs.refreshInterval) private var refresh = Prefs.defaultRefresh
    @AppStorage(Prefs.showAll) private var showAll = false
    @AppStorage(Prefs.fleetBinary) private var fleetBinary = ""
    @AppStorage(Prefs.notify) private var notify = true
    @AppStorage(Prefs.notifySound) private var notifySound = true
    @AppStorage(Prefs.menuBar) private var menuBar = true
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            Section {
                Picker("Open sessions in", selection: $terminal) {
                    ForEach(Terminal.available) { t in Text(t.title).tag(t.rawValue) }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Attach brings that app's window on the session to the front, or opens a new one. Only installed apps are listed.")
            }
            Section {
                Picker("Refresh every", selection: $refresh) {
                    ForEach([5, 8, 15, 30, 60], id: \.self) { n in Text("\(n) seconds").tag(n) }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Fleet asks every machine over ssh each time. ⌘R refreshes now.")
            }
            Section {
                Toggle("Notify when a session needs you", isOn: $notify)
                Toggle("Play a sound", isOn: $notifySound).disabled(!notify)
                Toggle("Show in the menu bar", isOn: $menuBar)
                Toggle("Open at login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { loginItem = SMAppService.mainApp.status == .enabled }
                    }
            } footer: {
                Text("A notification when an agent stops to ask you something; click it to jump to the session. The menu bar item lists what is waiting and keeps Fleet watching after its window is closed.")
            }
            Section {
                Toggle("Show sessions Fleet did not start", isOn: $showAll)
            } footer: {
                Text("Also lists tmux sessions and claude --worktree checkouts that were started outside Fleet (fleet ls --all). They cannot be attached from here.")
            }
            Section {
                TextField("fleet command", text: $fleetBinary, prompt: Text(FleetCLI.defaultBinary))
                    .textFieldStyle(.roundedBorder)
            } footer: {
                Text("Path to the fleet script. Empty uses ~/bin/fleet, or $FLEET_BIN when set. Takes effect after relaunch.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The host list on this Mac (`~/.config/fleet/hosts`); every edit is pushed
/// to every reachable host by the CLI, whose output is shown beneath.
struct HostSettings: View {
    @EnvironmentObject var model: FleetModel
    @State private var name = ""
    @State private var picked: String?
    var body: some View {
        Form {
            Section {
                List(model.hostList, id: \.self, selection: $picked) { h in
                    HStack {
                        Text(h)
                        if model.isSelf(h) { Text("this Mac").foregroundStyle(.secondary) }
                        Spacer()
                        if model.downReason(for: h) != nil { Image(systemName: "bolt.slash").foregroundStyle(.secondary) }
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    TextField("ssh alias or tailnet name", text: $name).textFieldStyle(.roundedBorder)
                        .onSubmit { add() }
                    Button("Add") { add() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") { if let p = picked { model.removeHost(p); picked = nil } }.disabled(picked == nil)
                }
                Button("Add every Mac on the tailnet") { model.addHost(nil) }
            } header: {
                Text("Hosts")
            } footer: {
                Text("Names go straight to ssh (letters, digits, . _ - only). Adding or removing one pushes the list to every host that answers; a host that was off gets it on its next fleet update.")
            }
            if !model.hostsOutput.isEmpty {
                Section("Last result") {
                    Text(model.hostsOutput).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadHosts() }
    }
    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        model.addHost(n); name = ""
    }
}

struct ButtonSettings: View {
    @AppStorage(Prefs.showXcode) private var xcode = true
    @AppStorage(Prefs.showClaude) private var claude = true
    @AppStorage(Prefs.showGitHub) private var github = true
    @AppStorage(Prefs.showScreenSharing) private var screen = true
    @AppStorage(Prefs.showFinder) private var finder = true
    var body: some View {
        Form {
            Section {
                Toggle("Open", isOn: $xcode)
                Toggle("Claude", isOn: $claude)
                Toggle("GitHub", isOn: $github)
                Toggle("Screen Sharing", isOn: $screen)
                Toggle("Finder", isOn: $finder)
            } header: {
                Text("Buttons on a session")
            } footer: {
                Text("The terminal button is always there: attach to the Claude Code session, or open a shell in its directory. Turn off what your projects do not use. Open pulls the branch onto this Mac and opens the checkout in Xcode, Finder, or the editor FLEET_OPEN names in ~/.config/fleet/config. Claude and GitHub only appear when the session has a Claude id or a GitHub remote; Screen Sharing for other machines; Finder for this one.")
            }
        }
        .formStyle(.grouped)
    }
}
