import SwiftUI
import ServiceManagement
import UserNotifications

/// Run as a bare executable (no .app bundle) macOS treats the process as
/// background: no Dock icon, and the window may never come to the front.
/// Becoming a regular app once launching has finished fixes that. Inside the
/// bundle Xcode builds this is a no-op. Also the notification delegate: a
/// click on "X needs you" selects that session.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        if Bundle.main.bundleIdentifier != nil {     // UNUserNotificationCenter aborts outside a bundle
            let c = UNUserNotificationCenter.current()
            c.delegate = self
            c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }
    /// With the menu bar item on, closing the window leaves fleet watching.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Prefs.on(Prefs.menuBar) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        if let id = r.notification.request.content.userInfo["session"] as? String {
            await MainActor.run { FleetModel.shared.reveal(.session(id)) }
        }
    }
}

@main
struct FleetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = FleetModel.shared
    @AppStorage(Prefs.menuBar) private var menuBar = true

    var body: some Scene {
        WindowGroup("Fleet", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 480)
                .onAppear { model.start() }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refresh() }.keyboardShortcut("r")
            }
            CommandMenu("Session") {
                Button("Attach") { if let s = model.selectedSession { model.attach(s) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedSession == nil)
                Button("End Session…") { model.confirmEnd = model.selectedSession }
                    .disabled(model.selectedSession == nil)
                Divider()
                Button("New Session…") { if let h = model.selectedHost { model.newSessionOn = NewSessionTarget(host: h) } }
                    .keyboardShortcut("n")
                    .disabled(model.selectedHost == nil)
            }
        }
        Settings { SettingsView().environmentObject(model) }
        MenuBarExtra(isInserted: $menuBar) {
            MenuBarMenu().environmentObject(model)
        } label: {
            // A Label here draws its icon only; separate views draw both.
            if model.needsYou > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(model.needsYou)")
            } else {
                Image(systemName: "rectangle.3.group")
            }
        }
    }
}

/// The menu bar item: what needs you, one line each; click to show it.
struct MenuBarMenu: View {
    @EnvironmentObject var model: FleetModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if model.blocked.isEmpty {
            Text(model.sessions.isEmpty ? "No Fleet sessions" : "Nothing needs you")
        } else {
            ForEach(model.blocked) { s in
                Button("\(s.title) on \(s.host)  ·  \(s.waiting ?? "")") { openWindow(id: "main"); model.reveal(.session(s.id)) }
            }
        }
        if let u = model.usage {
            Divider()
            Text("Usage  ·  " + [u.fiveHour.map { "5-hour \($0)%" }, u.sevenDay.map { "7-day \($0)%" }].compactMap { $0 }.joined(separator: "  ·  "))
        }
        Divider()
        Button("Open Fleet") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Refresh") { model.refresh() }.keyboardShortcut("r")
        Divider()
        Button("Quit Fleet") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
