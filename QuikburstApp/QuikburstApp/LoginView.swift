import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: AppSession
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            // Deep blue background matching app theme
            Theme.deepBlue.ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                // Logo and Title Section
                VStack(spacing: Theme.Spacing.lg) {
                    // QuikLogo Image
                    Image("QuikLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .shadow(color: Theme.orange.opacity(0.3), radius: 20, x: 0, y: 10)
                    
                    Text("QUIKBURST")
                        .font(Theme.Typography.drukHero)
                        .foregroundColor(.white)
                        .padding(.top, Theme.Spacing.sm)
                }
                .padding(.bottom, Theme.Spacing.xxl)
                
                // Login Form
                VStack(spacing: Theme.Spacing.md) {
                    // Username Field
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("USERNAME")
                            .font(Theme.Typography.exo2Label)
                            .foregroundColor(Theme.textSecondary)
                        
                        TextField("", text: $username, prompt: Text("Enter username").foregroundColor(Theme.textTertiary))
                            .font(Theme.Typography.exo2Body)
                            .foregroundColor(.white)
                            .padding(Theme.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(Theme.surfaceElevated)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                            .stroke(Theme.textTertiary, lineWidth: 1)
                                    )
                            )
#if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
#endif
                    }
                    
                    // Password Field
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("PASSWORD")
                            .font(Theme.Typography.exo2Label)
                            .foregroundColor(Theme.textSecondary)
                        
                        SecureField("", text: $password, prompt: Text("Enter password").foregroundColor(Theme.textTertiary))
                            .font(Theme.Typography.exo2Body)
                            .foregroundColor(.white)
                            .padding(Theme.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(Theme.surfaceElevated)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                            .stroke(Theme.textTertiary, lineWidth: 1)
                                    )
                            )
                    }
                    
                    // Error Message
                    if let errorMessage {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .font(Theme.Typography.exo2Caption)
                                .foregroundColor(.red)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Spacing.xs)
                        .transition(.opacity)
                    }
                    
                    // Login Button
                    Button {
                        HapticFeedback.buttonPress()
                        if !session.login(username: username, password: password) {
                            withAnimation { errorMessage = "Invalid credentials" }
                        } else {
                            errorMessage = nil
                        }
                    } label: {
                        Text("LOG IN")
                            .font(Theme.Typography.drukSection)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                LinearGradient(
                                    colors: [Theme.orange, Theme.secondaryAccent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(Theme.CornerRadius.medium)
                            .shadow(color: Theme.orange.opacity(0.4), radius: 12, x: 0, y: 6)
                    }
                    .padding(.top, Theme.Spacing.sm)
                }
                .padding(Theme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                                .stroke(.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
                .frame(maxWidth: 420)
                .padding(.horizontal, Theme.Spacing.lg)
                
                Spacer()
            }
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(AppSession())
}
