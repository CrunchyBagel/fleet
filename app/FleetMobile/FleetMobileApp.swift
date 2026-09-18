import SwiftUI

/// The iOS app: the same fleet, reached over ssh (Tailscale) from a phone.
/// It runs the CLI on each Mac exactly as the Mac app runs it locally, so the
/// CLI stays the single source of truth. No attach, no editor: start
/// sessions, see what needs you, open a session in the Claude app, end it.
@main
struct FleetMobileApp: App {
    @StateObject private var model = MobileModel()
    init() {
        #if DEBUG
        // In the simulator there is no UI automation to copy the key out; print it.
        if let k = try? KeyStore.publicKeyLine() { print("fleet public key: \(k)") }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: MobileModel
    var body: some View {
        if model.setupComplete {
            NavigationStack { OverviewView() }
        } else {
            NavigationStack { OnboardingView() }
        }
    }
}
