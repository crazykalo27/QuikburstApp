import Foundation
import Combine

@MainActor
final class WorkoutStore: ObservableObject {
    @Published private(set) var workouts: [Workout] = [] {
        didSet { save() }
    }
    
    private let workoutsKey = "savedWorkouts"
    
    init() {
        load()
    }
    
    func addWorkout(_ workout: Workout) {
        workouts.append(workout)
    }
    
    func updateWorkout(_ workout: Workout) {
        if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
            var updated = workout
            updated.updatedAt = Date()
            workouts[index] = updated
        }
    }
    
    func deleteWorkout(_ workout: Workout) {
        workouts.removeAll { $0.id == workout.id }
    }
    
    func toggleFavorite(_ workout: Workout) {
        if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[index].isFavorite.toggle()
        }
    }
    
    func getWorkout(id: UUID) -> Workout? {
        workouts.first { $0.id == id }
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(workouts) {
            UserDefaults.standard.set(encoded, forKey: workoutsKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: workoutsKey),
           let decoded = try? JSONDecoder().decode([Workout].self, from: data) {
            workouts = decoded
        }
    }
}
