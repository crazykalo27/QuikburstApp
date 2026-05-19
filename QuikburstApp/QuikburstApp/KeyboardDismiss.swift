import SwiftUI
import UIKit

enum KeyboardDismiss {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

// MARK: - UIKit Done bar (works for decimal pad and views without NavigationStack)

private final class KeyboardDoneAccessory: NSObject {
    static let shared = KeyboardDoneAccessory()

    private lazy var toolbar: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        bar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(doneTapped))
        bar.items = [flex, done]
        return bar
    }()

    private var keyboardObserver: NSObjectProtocol?
    private var textBeginObserver: NSObjectProtocol?

    private override init() {
        super.init()
        let center = NotificationCenter.default
        keyboardObserver = center.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachToFirstResponder()
        }
        textBeginObserver = center.addObserver(
            forName: UITextField.textDidBeginEditingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachToFirstResponder()
        }
    }

    func start() {
        attachToFirstResponder()
    }

    @objc private func doneTapped() {
        KeyboardDismiss.dismiss()
    }

    private func attachToFirstResponder() {
        guard let responder = UIApplication.shared.firstKeyWindow?.findFirstResponder() else { return }
        if let field = responder as? UITextField {
            if field.inputAccessoryView == nil {
                field.inputAccessoryView = toolbar
            }
        } else if let view = responder as? UITextView {
            if view.inputAccessoryView == nil {
                view.inputAccessoryView = toolbar
            }
        }
    }
}

private extension UIApplication {
    var firstKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

private extension UIView {
    func findFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let found = subview.findFirstResponder() { return found }
        }
        return nil
    }
}

private struct KeyboardDoneAccessoryInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        KeyboardDoneAccessory.shared.start()
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - SwiftUI modifier

private struct KeyboardDismissModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(KeyboardDoneAccessoryInstaller())
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done", action: KeyboardDismiss.dismiss)
                }
            }
    }
}

extension View {
    /// Scroll-to-dismiss and keyboard **Done** for screens with text fields.
    /// Does not add a global tap gesture (that blocked buttons app-wide).
    func supportsKeyboardDismiss() -> some View {
        modifier(KeyboardDismissModifier())
    }
}
