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
    
    func getResults(forDrillId drillId: UUID) -> [SessionResult] {
        results.filter { $0.drillId == drillId }
    }
    
    func getResults(forWorkoutId workoutId: UUID) -> [SessionResult] {
        results.filter { $0.workoutId == workoutId }
    }
    
    func getAllResults() -> [SessionResult] {
        results.sorted { $0.date > $1.date }
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
