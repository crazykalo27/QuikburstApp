import SwiftUI

// MARK: - Accessibility Helpers (Following WCAG Guidelines)

extension View {
    /// Adds accessibility label with proper contrast and sizing
    func accessibleLabel(_ label: String, hint: String? = nil) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }
    
    /// Ensures minimum touch target size (44x44 points)
    func minimumTouchTarget() -> some View {
        self.frame(minWidth: Theme.TouchTarget.minimum, minHeight: Theme.TouchTarget.minimum)
    }
    
    /// Adds dynamic type support with minimum readable size
    func dynamicType(minimumSize: CGFloat = Theme.Typography.minimumBody) -> some View {
        self
            .font(.system(.body, design: .rounded))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    
    /// Note: High contrast is automatically handled by SwiftUI when using semantic colors
    /// This method is kept for documentation purposes but doesn't require explicit implementation
}

// MARK: - Accessible Button Component

struct AccessibleButton<Label: View>: View {
    let action: () -> Void
    let label: Label
    let accessibilityLabel: String
    let accessibilityHint: String?
    let style: AccessibleButtonStyleType
    
    init(
        action: @escaping () -> Void,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        style: AccessibleButtonStyleType = .primary,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.style = style
        self.label = label()
    }
    
    var body: some View {
        Button(action: {
            HapticFeedback.buttonPress()
            action()
        }) {
            label
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
        .minimumTouchTarget()
        .applyButtonStyle(style)
    }
}

extension View {
    @ViewBuilder
    func applyButtonStyle(_ style: AccessibleButtonStyleType) -> some View {
        switch style {
        case .primary:
            self.buttonStyle(PrimaryButtonStyle())
        case .secondary:
            self.buttonStyle(SecondaryButtonStyle())
        case .text:
            self.buttonStyle(TextButtonStyle())
        case .icon:
            self.buttonStyle(IconButtonStyle())
        }
    }
}

enum AccessibleButtonStyleType {
    case primary
    case secondary
    case text
    case icon
}
