import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var sessionResultStore: SessionResultStore
    @EnvironmentObject var runStore: DrillRunStore
    @EnvironmentObject var baselineStore: DrillBaselineStore
    @AppStorage("darkModeEnabled") private var darkModeEnabled: Bool = false
    @AppStorage("countdownDuration") private var countdownDuration: Int = 5
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Dark Mode", isOn: $darkModeEnabled)
            } header: {
                Text("Display")
            } footer: {
                Text("Dark mode applies a dark color scheme throughout the app.")
            }
            
            Section {
                Picker("Countdown Timer", selection: $countdownDuration) {
                    Text("2 seconds").tag(2)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            } header: {
                Text("Training")
            } footer: {
                Text("Choose how long the countdown timer lasts before starting a drill or workout.")
            }
            
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete All Session Data", systemImage: "trash")
                }
                .buttonStyle(.plain)
            } header: {
                Text("Data Management")
            } footer: {
                Text("This will permanently delete all session results, drill runs, and baselines. This action cannot be undone.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete All Session Data", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteAllSessionData()
            }
        } message: {
            Text("Are you sure you want to delete all session data? This will permanently remove all session results, drill runs, and baselines. This action cannot be undone.")
        }
    }
    
    private func deleteAllSessionData() {
        sessionResultStore.deleteAllResults()
        runStore.deleteAllRuns()
        baselineStore.deleteAllBaselines()
    }
}

#Preview {
    SettingsView()
        .environmentObject(ProfileStore())
}
