import Foundation
import Combine

@MainActor
final class SessionResultStore: ObservableObject {
    @Published private(set) var results: [SessionResult] = [] {
        didSet { save() }
    }
    
    private let resultsKey = "savedSessionResults"
    
    init() {
        load()
    }
    
    func addResult(_ result: SessionResult) {
        results.append(result)
    }
    
    func deleteResult(_ result: SessionResult) {
        results.removeAll { $0.id == result.id }
    }
    
    func deleteResults(forSessionId sessionId: UUID) {
        results.removeAll { $0.workoutSessionId == sessionId }
    }
    
    func deleteResults(_ resultsToDelete: [SessionResult]) {
        let idsToDelete = Set(resultsToDelete.map { $0.id })
        results.removeAll { idsToDelete.contains($0.id) }
    }
    
    func getResults(forDrillId drillId: UUID) -> [SessionResult] {
        results.filter { $0.drillId == drillId }
    }
    
    func getResults(forWorkoutId workoutId: UUID) -> [SessionResult] {
        results.filter { $0.workoutId == workoutId }
    }
    
    func getResults(forWorkoutSessionId sessionId: UUID) -> [SessionResult] {
        results.filter { $0.workoutSessionId == sessionId }
    }
    
    /// Returns all drill-mode results regardless of whether they were part of a workout
    func getDrillResults() -> [SessionResult] {
        results.filter { $0.mode == .drill }
    }
    
    func getAllResults() -> [SessionResult] {
        results.sorted { $0.date > $1.date }
    }
    
    func deleteAllResults() {
        results.removeAll()
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(results) {
            UserDefaults.standard.set(encoded, forKey: resultsKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: resultsKey),
           let decoded = try? JSONDecoder().decode([SessionResult].self, from: data) {
            results = decoded
        }
    }
}
