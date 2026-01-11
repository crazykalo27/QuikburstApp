import SwiftUI

// MARK: - Profile Indicator Component

struct ProfileIndicator: View {
    @ObservedObject var profileStore: ProfileStore
    
    var body: some View {
        Menu {
            if profileStore.users.isEmpty {
                Text("No users available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profileStore.users) { user in
                    Button {
                        HapticFeedback.cardTap()
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
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.orange)
                
                Text(profileStore.selectedUser?.name ?? "No Profile")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                    .fill(Color(.systemGray6))
            )
        }
    }
}
