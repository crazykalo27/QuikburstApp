import Foundation
import Combine

@MainActor
final class DrillRunStore: ObservableObject {
    @Published private(set) var runs: [DrillRun] = [] {
        didSet { save() }
    }
    
    private let runsKey = "drillRuns"
    
    init() {
        load()
    }
    
    func saveRun(_ run: DrillRun) {
        runs.append(run)
    }
    
    func fetchRuns(for templateId: UUID) -> [DrillRun] {
        runs.filter { $0.templateId == templateId }
            .sorted { $0.timestamp > $1.timestamp }
    }
    
    func getBaselineRun(for templateId: UUID) -> DrillRun? {
        runs.first { $0.templateId == templateId && $0.runMode == .baselineNoEnforcement }
    }
    
    func getRecentEnforcedRuns(for templateId: UUID, limit: Int = 5) -> [DrillRun] {
        runs.filter { $0.templateId == templateId && $0.runMode == .enforced }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }
    
    func deleteRun(_ run: DrillRun) {
        runs.removeAll { $0.id == run.id }
    }
    
    /// Deletes DrillRuns that match the given SessionResult
    /// Matches by templateId and timestamp (within 5 seconds)
    func deleteRuns(matching result: SessionResult) {
        guard let templateId = result.drillId else { return }
        
        // Match by templateId and timestamp within 5 seconds
        let timeWindow: TimeInterval = 5.0
        runs.removeAll { run in
            run.templateId == templateId &&
            abs(run.timestamp.timeIntervalSince(result.date)) <= timeWindow
        }
    }
    
    /// Deletes DrillRuns that match any of the given SessionResults
    func deleteRuns(matching results: [SessionResult]) {
        for result in results {
            deleteRuns(matching: result)
        }
    }
    
    func deleteAllRuns() {
        runs.removeAll()
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(runs) {
            UserDefaults.standard.set(encoded, forKey: runsKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: runsKey),
           let decoded = try? JSONDecoder().decode([DrillRun].self, from: data) {
            runs = decoded
        }
    }
}
