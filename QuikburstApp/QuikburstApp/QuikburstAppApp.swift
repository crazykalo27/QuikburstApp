import SwiftUI
import Combine

@main
struct QuikburstAppApp: App {
    @StateObject private var session = AppSession()
    @StateObject private var runStore = RunStore()
    @StateObject private var profileStore = ProfileStore()
    // Keep a single manager instance for the app lifetime
    let manager = BluetoothManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isAuthenticated {
                    ContentView(manager: manager)
                } else {
                    LoginView()
                }
            }
            .environmentObject(session)
            .environmentObject(runStore)
            .environmentObject(profileStore)
        }
    }
}
