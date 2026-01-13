import Foundation
import Combine

@MainActor
final class DrillTemplateStore: ObservableObject {
    @Published private(set) var templates: [DrillTemplate] = [] {
        didSet { save() }
    }
    
    private let templatesKey = "drillTemplates"
    
    init() {
        load()
        // Always check if we need to seed the default drill
        seedInitialDataIfNeeded()
    }
    
    private func seedInitialDataIfNeeded() {
        // Check if "20 Yard Dash" already exists
        if templates.contains(where: { $0.name == "20 Yard Dash" }) {
            return
        }
        
        // Create the default template
        // 20 yards = 18.288 meters, rounded to 18.3m
        let defaultTemplate = DrillTemplate(
            name: "20 Yard Dash",
            description: "Classic 20 yard sprint drill",
            type: .speedDrill,
            isResist: false,
            isAssist: false,
            distanceMeters: 18.3,
            targetTimeSeconds: 8.0,
            targetMode: .distanceAndTime,
            enforcementIntent: .torqueEnvelope,
            probationStatus: .baselineCaptured, // Pre-seeded drills are ready to use
            forceType: .constant,
            constantForceN: 0, // No force for baseline
            rampupTimeSeconds: 1.0,
            torqueCurve: nil
        )
        
        // Add to templates array (this will trigger save via didSet)
        templates.append(defaultTemplate)
        // Explicitly save to ensure it's persisted
        save()
    }
    
    func createOrMergeDrillTemplate(_ template: DrillTemplate) -> DrillTemplate {
        // Check for existing template with same identityKey
        if let existing = templates.first(where: { $0.identityKey == template.identityKey }) {
            // Merge: update non-identity fields but keep existing ID and timestamps
            var merged = existing
            merged.name = template.name // Allow name updates
            merged.description = template.description
            merged.sportTag = template.sportTag
            merged.videoURL = template.videoURL
            merged.updatedAt = Date()
            // Update phases - this is critical for live variation bounds
            merged.phases = template.phases
            // Update legacy fields for backward compatibility
            merged.type = template.type
            merged.isResist = template.isResist
            merged.isAssist = template.isAssist
            merged.distanceMeters = template.distanceMeters
            merged.targetTimeSeconds = template.targetTimeSeconds
            merged.targetSpeedMps = template.targetSpeedMps
            merged.targetMode = template.targetMode
            merged.enforcementIntent = template.enforcementIntent
            merged.forceType = template.forceType
            merged.constantForceN = template.constantForceN
            merged.rampupTimeSeconds = template.rampupTimeSeconds
            merged.torqueCurve = template.torqueCurve
            merged.speedPercentOfBaseline = template.speedPercentOfBaseline
            merged.forcePercentOfBaseline = template.forcePercentOfBaseline
            // Keep existing probationStatus and ID
            if let index = templates.firstIndex(where: { $0.id == existing.id }) {
                templates[index] = merged
            }
            return merged
        } else {
            // New template
            var newTemplate = template
            newTemplate.probationStatus = .probationary // Always start as probationary
            templates.append(newTemplate)
            return newTemplate
        }
    }
    
    func updateTemplate(_ template: DrillTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            var updated = template
            updated.updatedAt = Date()
            templates[index] = updated
        }
    }
    
    func getTemplate(id: UUID) -> DrillTemplate? {
        templates.first { $0.id == id }
    }
    
    func getTemplate(identityKey: String) -> DrillTemplate? {
        templates.first { $0.identityKey == identityKey }
    }
    
    func fetchTemplates() -> [DrillTemplate] {
        templates
    }
    
    func deleteTemplate(_ template: DrillTemplate) {
        templates.removeAll { $0.id == template.id }
    }
    
    func markBaselineCaptured(for templateId: UUID) {
        if let index = templates.firstIndex(where: { $0.id == templateId }) {
            templates[index].probationStatus = .baselineCaptured
            templates[index].updatedAt = Date()
        }
    }
    
    func invalidateBaseline(for templateId: UUID) {
        if let index = templates.firstIndex(where: { $0.id == templateId }) {
            templates[index].probationStatus = .probationary
            templates[index].updatedAt = Date()
        }
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(encoded, forKey: templatesKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: templatesKey),
           let decoded = try? JSONDecoder().decode([DrillTemplate].self, from: data) {
            templates = decoded
        }
    }
}
