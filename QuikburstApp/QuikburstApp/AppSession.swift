import Foundation
import Combine

final class AppSession: ObservableObject {
    @Published var isAuthenticated: Bool = false

    @discardableResult
    func login(username: String, password: String) -> Bool {
        if username == "test" && password == "123" {
            isAuthenticated = true
            return true
        }
        return false
    }

    func logout() {
        isAuthenticated = false
    }
}
