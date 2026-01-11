import SwiftUI

struct Theme {
    // MARK: - Colors
    static let orange = Color(hex: "#FEA705")
    static let deepBlue = Color(hex: "#041E34")
    
    // MARK: - Adaptive Colors (2024 Design)
    static var primaryAccent: Color {
        Color(hex: "#FEA705") // Vibrant orange for high contrast
    }
    
    static var secondaryAccent: Color {
        Color(hex: "#FFB84D") // Lighter orange for gradients
    }
    
    static var backgroundPrimary: Color {
        Color(hex: "#041E34") // Deep blue
    }
    
    static var backgroundSecondary: Color {
        Color(hex: "#0A2A45") // Slightly lighter blue
    }
    
    static var surfaceElevated: Color {
        Color.white.opacity(0.1) // Glass morphism effect
    }
    
    static var textPrimary: Color {
        .white
    }
    
    static var textSecondary: Color {
        Color.white.opacity(0.7)
    }
    
    static var textTertiary: Color {
        Color.white.opacity(0.5)
    }
    
    // MARK: - Gradients (Modern 2024 Style)
    static var primaryGradient: LinearGradient {
        LinearGradient(
            colors: [primaryAccent, secondaryAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundPrimary, backgroundSecondary],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    // MARK: - Typography (Supporting Dynamic Type)
    struct Typography {
        // Use system fonts with dynamic type support
        static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title, design: .rounded).weight(.bold)
        static let title2 = Font.system(.title2, design: .rounded).weight(.semibold)
        static let title3 = Font.system(.title3, design: .rounded).weight(.semibold)
        static let headline = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body, design: .rounded)
        static let callout = Font.system(.callout, design: .rounded)
        static let subheadline = Font.system(.subheadline, design: .rounded)
        static let footnote = Font.system(.footnote, design: .rounded)
        static let caption = Font.system(.caption, design: .rounded)
        static let caption2 = Font.system(.caption2, design: .rounded)
        
        // Minimum readable sizes (accessibility)
        static let minimumBody: CGFloat = 14
        static let minimumCaption: CGFloat = 12
    }
    
    // MARK: - Spacing
    struct Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }
    
    // MARK: - Corner Radius
    struct CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xlarge: CGFloat = 24
    }
    
    // MARK: - Animation (Micro-interactions)
    struct Animation {
        static let quick = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.7)
        static let smooth = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.8)
        static let bouncy = SwiftUI.Animation.spring(response: 0.5, dampingFraction: 0.6)
        static let gentle = SwiftUI.Animation.easeInOut(duration: 0.2)
    }
    
    // MARK: - Shadow (Depth & Layering)
    struct Shadow {
        static let small = ShadowStyle(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        static let medium = ShadowStyle(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        static let large = ShadowStyle(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
    }
    
    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
    
    // MARK: - Touch Targets (Accessibility)
    struct TouchTarget {
        static let minimum: CGFloat = 44 // iOS HIG minimum
        static let recommended: CGFloat = 48 // Android Material Design
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
