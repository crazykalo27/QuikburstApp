import SwiftUI

// MARK: - Button Hierarchy System (Following Design Guide)

/// Primary button - high emphasis, main call-to-action
struct PrimaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.TouchTarget.minimum)
            .background(
                Group {
                    if isEnabled {
                        Theme.primaryGradient
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
            )
            .cornerRadius(Theme.CornerRadius.medium)
            .shadow(color: Theme.Shadow.medium.color, radius: Theme.Shadow.medium.radius, x: Theme.Shadow.medium.x, y: Theme.Shadow.medium.y)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(Theme.Animation.quick, value: configuration.isPressed)
    }
}

/// Secondary button - medium emphasis, outlined style
struct SecondaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .foregroundColor(isEnabled ? Theme.primaryAccent : Color.gray)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.TouchTarget.minimum)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                    .stroke(isEnabled ? Theme.primaryAccent : Color.gray, lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(Theme.Animation.quick, value: configuration.isPressed)
    }
}

/// Text button - low emphasis, borderless
struct TextButtonStyle: ButtonStyle {
    var isEnabled: Bool = true
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.body)
            .foregroundColor(isEnabled ? Theme.primaryAccent : Color.gray)
            .frame(height: Theme.TouchTarget.minimum)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(Theme.Animation.gentle, value: configuration.isPressed)
    }
}

/// Icon button - for quick actions
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = Theme.TouchTarget.minimum
    var color: Color = Theme.primaryAccent
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundColor(color)
            .background(
                Circle()
                    .fill(color.opacity(configuration.isPressed ? 0.2 : 0.1))
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(Theme.Animation.quick, value: configuration.isPressed)
    }
}

// MARK: - Convenience Extensions

extension Button {
    func primaryStyle(isEnabled: Bool = true) -> some View {
        self.buttonStyle(PrimaryButtonStyle(isEnabled: isEnabled))
    }
    
    func secondaryStyle(isEnabled: Bool = true) -> some View {
        self.buttonStyle(SecondaryButtonStyle(isEnabled: isEnabled))
    }
    
    func textStyle(isEnabled: Bool = true) -> some View {
        self.buttonStyle(TextButtonStyle(isEnabled: isEnabled))
    }
    
    func iconStyle(size: CGFloat = Theme.TouchTarget.minimum, color: Color = Theme.primaryAccent) -> some View {
        self.buttonStyle(IconButtonStyle(size: size, color: color))
    }
}
