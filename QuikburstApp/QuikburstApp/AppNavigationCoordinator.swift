import SwiftUI
import Combine

/// App-level navigation coordinator for deep-linking and cross-tab navigation
/// Handles navigation intents like "Start in Train" from Drill/Workout detail views
///
/// Implementation notes:
/// - DrillDetailView calls startDrillInTrain() which sets trainStartIntent and switches to Train tab
/// - WorkoutDetailView calls startWorkoutInTrain() which sets trainStartIntent and switches to Train tab
/// - TrainTabView processes the intent in processStartIntent() and transitions to appropriate state
/// - This enables deep-linking: user can start a drill/workout in ≤2 taps from library detail screen
class AppNavigationCoordinator: ObservableObject {
    @Published var selectedTab: Tab = .train
    @Published var trainStartIntent: TrainStartIntent?
    @Published var isSessionActive: Bool = false // Track if drill/workout session is active
    
    /// Intent to start a training session from an external source (Drill/Workout detail)
    enum TrainStartIntent: Equatable {
        case drillTemplate(DrillTemplate, isBaseline: Bool = false)
        case workout(Workout)
        
        static func == (lhs: TrainStartIntent, rhs: TrainStartIntent) -> Bool {
            switch (lhs, rhs) {
            case (.drillTemplate(let t1, let b1), .drillTemplate(let t2, let b2)):
                return t1.id == t2.id && b1 == b2
            case (.workout(let w1), .workout(let w2)):
                return w1.id == w2.id
            default:
                return false
            }
        }
    }
    
    /// Navigate to Train tab and start with a drill template
    func startDrillTemplateInTrain(_ template: DrillTemplate, isBaseline: Bool = false) {
        trainStartIntent = .drillTemplate(template, isBaseline: isBaseline)
        selectedTab = .train
    }
    
    /// Navigate to Train tab and start with a workout
    func startWorkoutInTrain(_ workout: Workout) {
        trainStartIntent = .workout(workout)
        selectedTab = .train
    }
    
    /// Navigate to Train tab and start with a legacy Drill (converts to DrillTemplate)
    func startDrillInTrain(_ drill: Drill, level: Int?) {
        // Convert Drill to DrillTemplate
        let template = DrillTemplate(
            name: drill.name,
            description: nil,
            type: drill.type ?? .speedDrill,
            isResist: drill.isResistive,
            isAssist: drill.isAssistive,
            distanceMeters: nil,
            targetTimeSeconds: Double(drill.lengthSeconds),
            targetMode: .timeOnly,
            enforcementIntent: .none,
            probationStatus: .probationary,
            forceType: nil,
            constantForceN: nil,
            rampupTimeSeconds: nil,
            torqueCurve: nil
        )
        trainStartIntent = .drillTemplate(template, isBaseline: false)
        selectedTab = .train
    }
    
    /// Clear the start intent (called after TrainTabView processes it)
    func clearStartIntent() {
        trainStartIntent = nil
    }
}
