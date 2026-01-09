import Foundation
import SwiftUI
import Combine

class ProfileStore: ObservableObject {
    @Published var profiles: [TorqueProfile] = []
    @Published var users: [User] = []
    @Published var selectedUserId: UUID? // Currently selected user for recording
    
    private let profilesKey = "savedTorqueProfiles"
    private let usersKey = "savedUsers"
    private let selectedUserIdKey = "selectedUserId"
    
    init() {
        loadProfiles()
        loadUsers()
        loadSelectedUserId()
        
        // If no users exist, create a default user
        if users.isEmpty {
            let defaultUser = User(name: "Default User")
            users.append(defaultUser)
            selectedUserId = defaultUser.id
            saveUsers()
            saveSelectedUserId()
        }
        
        // If no user is selected, select the first one
        if selectedUserId == nil, let firstUser = users.first {
            selectedUserId = firstUser.id
            saveSelectedUserId()
        }
    }
    
    // MARK: - Torque Profiles
    func addProfile(_ profile: TorqueProfile) {
        profiles.append(profile)
        saveProfiles()
    }
    
    func updateProfile(_ profile: TorqueProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            saveProfiles()
        }
    }
    
    func deleteProfile(_ profile: TorqueProfile) {
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }
    
    // MARK: - Users
    func addUser(_ user: User) {
        users.append(user)
        saveUsers()
    }
    
    func updateUser(_ user: User) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
            saveUsers()
        }
    }
    
    func deleteUser(_ user: User) {
        users.removeAll { $0.id == user.id }
        saveUsers()
        
        // If deleted user was selected, select first available user
        if selectedUserId == user.id {
            selectedUserId = users.first?.id
            saveSelectedUserId()
        }
    }
    
    func selectUser(_ userId: UUID?) {
        selectedUserId = userId
        saveSelectedUserId()
    }
    
    var selectedUser: User? {
        guard let selectedUserId = selectedUserId else { return nil }
        return users.first { $0.id == selectedUserId }
    }
    
    // MARK: - Persistence
    private func saveProfiles() {
        if let encoded = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(encoded, forKey: profilesKey)
        }
    }
    
    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([TorqueProfile].self, from: data) {
            profiles = decoded
        }
    }
    
    private func saveUsers() {
        if let encoded = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(encoded, forKey: usersKey)
        }
    }
    
    private func loadUsers() {
        if let data = UserDefaults.standard.data(forKey: usersKey),
           let decoded = try? JSONDecoder().decode([User].self, from: data) {
            users = decoded
        }
    }
    
    private func saveSelectedUserId() {
        if let selectedUserId = selectedUserId {
            UserDefaults.standard.set(selectedUserId.uuidString, forKey: selectedUserIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedUserIdKey)
        }
    }
    
    private func loadSelectedUserId() {
        if let uuidString = UserDefaults.standard.string(forKey: selectedUserIdKey),
           let uuid = UUID(uuidString: uuidString) {
            selectedUserId = uuid
        }
    }
}
