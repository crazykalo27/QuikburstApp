import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: AppSession
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white, Color.blue.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Quikburst")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.blue)

                VStack(spacing: 12) {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }

                    Button {
                        if !session.login(username: username, password: password) {
                            withAnimation { errorMessage = "Invalid credentials" }
                        } else {
                            errorMessage = nil
                        }
                    } label: {
                        Text("Log In")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
                .frame(maxWidth: 420)
                .padding(.horizontal)
            }
            .padding()
        }
        .tint(.blue)
    }
}

#Preview {
    LoginView()
        .environmentObject(AppSession())
}
