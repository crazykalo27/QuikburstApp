import Foundation
import Combine

@MainActor
final class DrillBaselineStore: ObservableObject {
    @Published private(set) var baselines: [DrillBaseline] = [] {
        didSet { save() }
    }
    
    private let baselinesKey = "drillBaselines"
    
    init() {
        load()
    }
    
    func saveBaseline(_ baseline: DrillBaseline) {
        // Remove any existing baseline for this template
        baselines.removeAll { $0.templateId == baseline.templateId }
        baselines.append(baseline)
    }
    
    func getBaseline(for templateId: UUID) -> DrillBaseline? {
        baselines.first { $0.templateId == templateId }
    }
    
    func deleteBaseline(for templateId: UUID) {
        baselines.removeAll { $0.templateId == templateId }
    }
    
    func deleteAllBaselines() {
        baselines.removeAll()
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(baselines) {
            UserDefaults.standard.set(encoded, forKey: baselinesKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: baselinesKey),
           let decoded = try? JSONDecoder().decode([DrillBaseline].self, from: data) {
            baselines = decoded
        }
    }
}
