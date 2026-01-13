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
    
    // MARK: - Typography
    // Druk: Energy amplifier for impactful moments (drill names, workout titles, hero headlines, section breaks)
    // Exo 2: Control layer for clarity and precision (metrics, numbers, labels, navigation, body text)
    
    struct Typography {
        // MARK: - Druk (Impact & Motivation)
        // Use for: Drill names, workout titles, hero headlines, major section breaks
        // Rules: ALL CAPS, short phrases, large sizes
        
        static func druk(size: CGFloat, weight: Font.Weight = .bold) -> Font {
            // Use Druk font, fallback to system bold rounded if font not available
            Font.custom("Druk-Bold", size: size)
        }
        
        static let drukHero = druk(size: 42, weight: .bold) // Hero headlines
        static let drukTitle = druk(size: 32, weight: .bold) // Major titles
        static let drukSection = druk(size: 24, weight: .bold) // Section breaks
        static let drukDrillName = druk(size: 22, weight: .bold) // Drill names
        static let drukWorkoutTitle = druk(size: 20, weight: .bold) // Workout titles
        
        // MARK: - Exo 2 (Clarity & Precision)
        // Use for: Metrics, numbers, labels, navigation, body text, readable content
        
        static func exo2(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            // Use Exo 2 font with appropriate weight variant
            let fontName: String
            switch weight {
            case .bold:
                fontName = "Exo2-Bold"
            case .semibold:
                fontName = "Exo2-SemiBold"
            case .medium:
                fontName = "Exo2-Medium"
            default:
                fontName = "Exo2-Regular"
            }
            return Font.custom(fontName, size: size)
        }
        
        static func exo2Bold(size: CGFloat) -> Font {
            exo2(size: size, weight: .bold)
        }
        
        static func exo2SemiBold(size: CGFloat) -> Font {
            exo2(size: size, weight: .semibold)
        }
        
        static func exo2Medium(size: CGFloat) -> Font {
            exo2(size: size, weight: .medium)
        }
        
        // Exo 2 sizes for different contexts
        static let exo2LargeTitle = exo2(size: 34, weight: .bold)
        static let exo2Title = exo2(size: 28, weight: .bold)
        static let exo2Title2 = exo2SemiBold(size: 22)
        static let exo2Title3 = exo2SemiBold(size: 20)
        static let exo2Headline = exo2SemiBold(size: 17)
        static let exo2Body = exo2(size: 17)
        static let exo2Callout = exo2(size: 16)
        static let exo2Subheadline = exo2(size: 15)
        static let exo2Footnote = exo2(size: 13)
        static let exo2Caption = exo2(size: 12)
        static let exo2Caption2 = exo2(size: 11)
        
        // Exo 2 for metrics and numbers
        static let exo2Metric = exo2Bold(size: 32) // Large numbers/metrics
        static let exo2MetricMedium = exo2Bold(size: 24) // Medium numbers
        static let exo2MetricSmall = exo2Bold(size: 18) // Small numbers
        static let exo2Label = exo2Medium(size: 13) // Labels
        static let exo2Nav = exo2Medium(size: 15) // Navigation
        
        // Legacy support (mapped to Exo 2)
        static let largeTitle = exo2LargeTitle
        static let title = exo2Title
        static let title2 = exo2Title2
        static let title3 = exo2Title3
        static let headline = exo2Headline
        static let body = exo2Body
        static let callout = exo2Callout
        static let subheadline = exo2Subheadline
        static let footnote = exo2Footnote
        static let caption = exo2Caption
        static let caption2 = exo2Caption2
        
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

// MARK: - View Extensions for Navigation Titles
extension View {
    func drukNavigationTitle(_ title: String) -> some View {
        self.navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title.uppercased())
                        .font(Theme.Typography.drukSection)
                        .foregroundColor(.primary)
                }
            }
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
