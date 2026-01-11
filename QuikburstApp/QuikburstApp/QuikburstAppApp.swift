import SwiftUI
import Combine

@main
struct QuikburstAppApp: App {
    @StateObject private var session = AppSession()
    @StateObject private var runStore = RunStore()
    @StateObject private var profileStore = ProfileStore()
    @AppStorage("darkModeEnabled") private var darkModeEnabled: Bool = false
    // Keep a single manager instance for the app lifetime
    let manager = BluetoothManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isAuthenticated {
                    ContentView(manager: manager)
                        .environmentObject(session)
                        .environmentObject(runStore)
                        .environmentObject(profileStore)
                } else {
                    LoginView()
                        .environmentObject(session)
                }
            }
            .preferredColorScheme(darkModeEnabled ? .dark : .light)
        }
    }
}
