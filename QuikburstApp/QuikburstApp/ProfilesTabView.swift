import SwiftUI

struct ProfilesTabView: View {
    @EnvironmentObject var profileStore: ProfileStore
    let bluetoothManager: BluetoothManager
    @State private var showingUserEdit = false
    @State private var showingBluetoothConsole = false
    @State private var showingPreferences = false
    @State private var showingUserSelection = false
    @State private var showingNewUserSheet = false
    @State private var editingUser: User?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    // User Profile Card
                    VStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(Theme.orange)
                        
                        // User Selection Menu
                        Menu {
                            if profileStore.users.isEmpty {
                                Text("No users available")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(profileStore.users) { user in
                                    Button {
                                        profileStore.selectUser(user.id)
                                    } label: {
                                        HStack {
                                            Text(user.name)
                                            if profileStore.selectedUserId == user.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                                Divider()
                                Button {
                                    editingUser = User(name: "New User")
                                    showingNewUserSheet = true
                                } label: {
                                    Label("Add New User", systemImage: "plus")
                                }
                            }
                        } label: {
                            HStack {
                                Text(profileStore.selectedUser?.name ?? "No User Selected")
                                    .font(Theme.Typography.title2)
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let user = profileStore.selectedUser {
                            VStack(spacing: Theme.Spacing.sm) {
                                if user.height > 0 {
                                    Text("Height: \(String(format: "%.1f", user.height))")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                if user.weight > 0 {
                                    Text("Weight: \(String(format: "%.1f", user.weight))")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                if user.age > 0 {
                                    Text("Age: \(user.age)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        Button {
                            showingUserEdit = true
                        } label: {
                            Text("Edit Profile")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.orange)
                                .foregroundColor(.white)
                                .cornerRadius(Theme.CornerRadius.medium)
                        }
                    }
                    .padding(Theme.Spacing.lg)
                    .background(Color(.systemGray6))
                    .cornerRadius(Theme.CornerRadius.large)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.md)
                    
                    // Settings section
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Settings")
                            .font(.headline)
                            .padding(.horizontal, Theme.Spacing.md)
                        
                        VStack(spacing: Theme.Spacing.sm) {
                            SettingsRow(
                                icon: "link",
                                title: "Device Pairing",
                                subtitle: "Connect Bluetooth devices"
                            ) {
                                showingBluetoothConsole = true
                            }
                            
                            SettingsRow(
                                icon: "gearshape",
                                title: "Preferences",
                                subtitle: "App settings and preferences"
                            ) {
                                showingPreferences = true
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                    }
                }
            }
            .navigationTitle("Profiles")
            .sheet(isPresented: $showingUserEdit) {
                if let user = profileStore.selectedUser {
                    UserEditView(
                        user: user,
                        profileStore: profileStore,
                        isPresented: $showingUserEdit
                    )
                } else {
                    // Fallback: create a new user if none selected
                    UserEditView(
                        user: User(name: ""),
                        profileStore: profileStore,
                        isPresented: $showingUserEdit,
                        isNew: true
                    )
                }
            }
            .sheet(isPresented: $showingBluetoothConsole) {
                NavigationStack {
                    BluetoothConsoleView(bluetooth: bluetoothManager)
                }
            }
            .sheet(isPresented: $showingPreferences) {
                NavigationStack {
                    SettingsView()
                        .environmentObject(profileStore)
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
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(Theme.orange)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(Theme.Spacing.md)
            .background(Color(.systemGray6))
            .cornerRadius(Theme.CornerRadius.medium)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ProfilesTabView(bluetoothManager: BluetoothManager())
        .environmentObject(ProfileStore())
}
