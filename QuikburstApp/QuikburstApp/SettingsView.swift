import SwiftUI

struct SettingsView: View {
    @AppStorage("sampleRateHz") private var sampleRateHz: Double = 25
    @AppStorage("unit") private var unit: String = "units"
    @AppStorage("autoReconnect") private var autoReconnect: Bool = true
    @EnvironmentObject var profileStore: ProfileStore
    @State private var editingUser: User?
    @State private var showingEditSheet = false
    @State private var showingNewUserSheet = false

    var body: some View {
        Form {
            // Users Section
            Section {
                if profileStore.users.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("No users yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Add a new user to get started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(profileStore.users) { user in
                        NavigationLink {
                            UserEditView(
                                user: user,
                                profileStore: profileStore,
                                isPresented: .constant(true)
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.name)
                                    .font(.headline)
                                HStack {
                                    Text(user.primarySport.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if profileStore.selectedUserId == user.id {
                                        Spacer()
                                        Text("Selected")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let user = profileStore.users[index]
                            // Don't allow deleting if it's the only user
                            if profileStore.users.count > 1 {
                                profileStore.deleteUser(user)
                            }
                        }
                    }
                }
            } header: {
                Text("Users")
            } footer: {
                Text("Tap a user to edit their settings. Swipe to delete.")
            }
            
            Section {
                Stepper(value: $sampleRateHz, in: 1...200, step: 1) {
                    HStack {
                        Text("Sample rate")
                        Spacer()
                        Text("\(Int(sampleRateHz)) Hz")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Auto-reconnect", isOn: $autoReconnect)
            } header: {
                Text("Streaming")
            } footer: {
                Text("Sample rate determines how frequently data is collected from the device.")
            }

            Section {
                TextField("Unit label", text: $unit)
                Toggle("Dark Mode (Placeholder)", isOn: .constant(false))
                Toggle("Show Gridlines (Placeholder)", isOn: .constant(true))
            } header: {
                Text("Display")
            }

            Section {
                Button {
                    // TODO: Hook up to Bluetooth connection flow
                } label: {
                    Label("Connect Device", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.plain)

                Button {
                    // TODO: Manage paired devices
                } label: {
                    Label("Paired Devices", systemImage: "link")
                }
                .buttonStyle(.plain)
            } header: {
                Text("Device Management")
            }

            Section {
                Button {
                    // TODO: Clear cached data
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                
                Button {
                    // TODO: Import data
                } label: {
                    Label("Import", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.plain)
                
                Button {
                    // TODO: Export data
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            } header: {
                Text("Data & Storage")
            }

            Section {
                Button {
                    // TODO: Show About sheet
                } label: {
                    Label("About Quikburst", systemImage: "info.circle")
                }
                .buttonStyle(.plain)
                
                Button {
                    // TODO: Show Help sheet
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .buttonStyle(.plain)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingUser = User(name: "New User")
                    showingNewUserSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewUserSheet) {
            if let user = editingUser {
                UserEditView(
                    user: user,
                    profileStore: profileStore,
                    isPresented: $showingNewUserSheet,
                    isNew: true
                )
            }
        }
        .onChange(of: showingNewUserSheet) { _, newValue in
            if !newValue {
                editingUser = nil
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ProfileStore())
}
