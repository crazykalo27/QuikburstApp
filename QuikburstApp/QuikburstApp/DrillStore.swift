import Foundation
import Combine

@MainActor
final class DrillStore: ObservableObject {
    @Published private(set) var drills: [Drill] = [] {
        didSet { save() }
    }
    
    private let drillsKey = "savedDrills"
    
    init() {
        load()
        seedInitialDataIfNeeded()
    }
    
    private func seedInitialDataIfNeeded() {
        // Check if "20 Yard Dash" already exists
        if drills.contains(where: { $0.name == "20 Yard Dash" }) {
            return
        }
        
        // Create the default drill
        let defaultDrill = Drill(
            name: "20 Yard Dash",
            category: .speed,
            isResistive: false,
            isAssistive: false,
            type: .speedDrill,
            lengthSeconds: 8,
            isCustom: false,
            isFavorite: false
        )
        
        drills.append(defaultDrill)
    }
    
    func addDrill(_ drill: Drill) {
        drills.append(drill)
    }
    
    func updateDrill(_ drill: Drill) {
        if let index = drills.firstIndex(where: { $0.id == drill.id }) {
            var updated = drill
            updated.updatedAt = Date()
            drills[index] = updated
        }
    }
    
    func deleteDrill(_ drill: Drill) {
        drills.removeAll { $0.id == drill.id }
    }
    
    func toggleFavorite(_ drill: Drill) {
        if let index = drills.firstIndex(where: { $0.id == drill.id }) {
            drills[index].isFavorite.toggle()
        }
    }
    
    func getDrill(id: UUID) -> Drill? {
        drills.first { $0.id == id }
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(drills) {
            UserDefaults.standard.set(encoded, forKey: drillsKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: drillsKey),
           let decoded = try? JSONDecoder().decode([Drill].self, from: data) {
            drills = decoded
        }
    }
}
