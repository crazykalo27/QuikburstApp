import SwiftUI
import Foundation
import Combine

// MARK: - Gamification Models

struct Achievement: Identifiable, Codable {
    let id: UUID
    let title: String
    let description: String
    let icon: String
    let unlockedAt: Date?
    let requirement: AchievementRequirement
    
    init(id: UUID = UUID(), title: String, description: String, icon: String, requirement: AchievementRequirement, unlockedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.icon = icon
        self.requirement = requirement
        self.unlockedAt = unlockedAt
    }
}

enum AchievementRequirement: Codable {
    case workoutsCompleted(count: Int)
    case drillsCompleted(count: Int)
    case streakDays(days: Int)
    case personalBest(drillId: UUID)
    case totalDuration(minutes: Int)
}

struct UserStats: Codable {
    var totalWorkouts: Int = 0
    var totalDrills: Int = 0
    var currentStreak: Int = 0 // Days
    var longestStreak: Int = 0
    var lastWorkoutDate: Date?
    var achievements: [UUID] = [] // Achievement IDs
    
    mutating func updateStreak() {
        guard let lastDate = lastWorkoutDate else {
            currentStreak = 1
            lastWorkoutDate = Date()
            return
        }
        
        let calendar = Calendar.current
        let daysSince = calendar.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
        
        if daysSince == 0 {
            // Same day, no change
            return
        } else if daysSince == 1 {
            // Consecutive day
            currentStreak += 1
            longestStreak = max(longestStreak, currentStreak)
        } else {
            // Streak broken
            currentStreak = 1
        }
        
        lastWorkoutDate = Date()
    }
}

// MARK: - Achievement Store

class AchievementStore: ObservableObject {
    @Published var stats = UserStats()
    @Published var allAchievements: [Achievement] = []
    
    private let statsKey = "userStats"
    private let achievementsKey = "allAchievements"
    
    init() {
        loadStats()
        loadAchievements()
        initializeDefaultAchievements()
    }
    
    private func initializeDefaultAchievements() {
        if allAchievements.isEmpty {
            allAchievements = [
                Achievement(
                    title: "First Steps",
                    description: "Complete your first workout",
                    icon: "star.fill",
                    requirement: .workoutsCompleted(count: 1)
                ),
                Achievement(
                    title: "Getting Started",
                    description: "Complete 5 workouts",
                    icon: "flame.fill",
                    requirement: .workoutsCompleted(count: 5)
                ),
                Achievement(
                    title: "Dedicated",
                    description: "Complete 10 workouts",
                    icon: "trophy.fill",
                    requirement: .workoutsCompleted(count: 10)
                ),
                Achievement(
                    title: "Week Warrior",
                    description: "Maintain a 7-day streak",
                    icon: "calendar",
                    requirement: .streakDays(days: 7)
                ),
                Achievement(
                    title: "On Fire",
                    description: "Maintain a 30-day streak",
                    icon: "flame.fill",
                    requirement: .streakDays(days: 30)
                )
            ]
            saveAchievements()
        }
    }
    
    func checkAchievements() -> [Achievement] {
        var newlyUnlocked: [Achievement] = []
        
        for achievement in allAchievements {
            if stats.achievements.contains(achievement.id) {
                continue // Already unlocked
            }
            
            if checkRequirement(achievement.requirement) {
                unlockAchievement(achievement)
                newlyUnlocked.append(achievement)
            }
        }
        
        return newlyUnlocked
    }
    
    private func checkRequirement(_ requirement: AchievementRequirement) -> Bool {
        switch requirement {
        case .workoutsCompleted(let count):
            return stats.totalWorkouts >= count
        case .drillsCompleted(let count):
            return stats.totalDrills >= count
        case .streakDays(let days):
            return stats.currentStreak >= days
        case .personalBest:
            // Would need drill-specific tracking
            return false
        case .totalDuration(let minutes):
            // Would need duration tracking
            return false
        }
    }
    
    private func unlockAchievement(_ achievement: Achievement) {
        stats.achievements.append(achievement.id)
        saveStats()
    }
    
    func recordWorkout() {
        stats.totalWorkouts += 1
        stats.updateStreak()
        saveStats()
    }
    
    func recordDrill() {
        stats.totalDrills += 1
        saveStats()
    }
    
    private func loadStats() {
        if let data = UserDefaults.standard.data(forKey: statsKey),
           let decoded = try? JSONDecoder().decode(UserStats.self, from: data) {
            stats = decoded
        }
    }
    
    private func saveStats() {
        if let encoded = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(encoded, forKey: statsKey)
        }
    }
    
    private func loadAchievements() {
        if let data = UserDefaults.standard.data(forKey: achievementsKey),
           let decoded = try? JSONDecoder().decode([Achievement].self, from: data) {
            allAchievements = decoded
        }
    }
    
    private func saveAchievements() {
        if let encoded = try? JSONEncoder().encode(allAchievements) {
            UserDefaults.standard.set(encoded, forKey: achievementsKey)
        }
    }
}

// MARK: - Celebration View (Micro-interaction)

struct CelebrationView: View {
    let achievement: Achievement?
    let message: String
    @Binding var isPresented: Bool
    @State private var scale: CGFloat = 0.5
    @State private var rotation: Double = 0
    @State private var opacity: Double = 0
    
    var body: some View {
        ZStack {
            // Background overlay
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .opacity(opacity)
            
            // Celebration content
            VStack(spacing: Theme.Spacing.lg) {
                if let achievement = achievement {
                    // Achievement icon
                    Image(systemName: achievement.icon)
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.primaryGradient)
                        .scaleEffect(scale)
                        .rotationEffect(.degrees(rotation))
                    
                    Text(achievement.title)
                        .font(Theme.Typography.title)
                        .foregroundColor(Theme.textPrimary)
                    
                    Text(achievement.description)
                        .font(Theme.Typography.body)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    // Generic celebration
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(Theme.primaryAccent)
                        .scaleEffect(scale)
                    
                    Text(message)
                        .font(Theme.Typography.title)
                        .foregroundColor(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(Theme.Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .fill(Theme.surfaceElevated)
                    .background(.ultraThinMaterial)
            )
            .padding(Theme.Spacing.lg)
            .opacity(opacity)
        }
        .onAppear {
            HapticFeedback.achievementUnlocked()
            withAnimation(Theme.Animation.bouncy) {
                scale = 1.0
                opacity = 1.0
            }
            withAnimation(Theme.Animation.smooth.repeatCount(2, autoreverses: true)) {
                rotation = 360
            }
            
            // Auto-dismiss after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(Theme.Animation.gentle) {
                    opacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isPresented = false
                }
            }
        }
    }
}

// MARK: - Streak Indicator Component

struct StreakIndicator: View {
    let currentStreak: Int
    let longestStreak: Int
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "flame.fill")
                .foregroundColor(Theme.primaryAccent)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("\(currentStreak) day streak")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.textPrimary)
                
                if longestStreak > currentStreak {
                    Text("Best: \(longestStreak) days")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .fill(Theme.surfaceElevated)
        )
        .accessibleLabel("Current streak: \(currentStreak) days")
    }
}
