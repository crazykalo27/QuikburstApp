import UIKit

// MARK: - Haptic Feedback Utility (Micro-interactions)

enum HapticFeedback {
    case light
    case medium
    case heavy
    case success
    case warning
    case error
    case selection
    
    static func play(_ type: HapticFeedback) {
        switch type {
        case .light:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            
        case .medium:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            
        case .heavy:
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            
        case .success:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
        case .warning:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            
        case .error:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
            
        case .selection:
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
        }
    }
    
    // Convenience methods for common interactions
    static func buttonPress() {
        play(.light)
    }
    
    static func cardTap() {
        play(.selection)
    }
    
    static func longPress() {
        play(.medium)
    }
    
    static func workoutComplete() {
        play(.success)
    }
    
    static func achievementUnlocked() {
        play(.heavy)
    }
}
