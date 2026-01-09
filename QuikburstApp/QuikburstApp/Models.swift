import Foundation

struct SensorSample: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}
struct RunRecord: Identifiable, Hashable, Codable {
    let id: UUID
    let date: Date
    let duration: TimeInterval // seconds
    let averageValue: Double
    let peakValue: Double
    let userId: UUID? // User who recorded this run
}

extension RunRecord {
    init(date: Date, duration: TimeInterval, averageValue: Double, peakValue: Double, userId: UUID? = nil) {
        self.id = UUID()
        self.date = date
        self.duration = duration
        self.averageValue = averageValue
        self.peakValue = peakValue
        self.userId = userId
    }
}

// Profile model for torque profiles
struct TorqueProfile: Identifiable, Codable {
    let id: UUID
    var name: String
    var torquePoints: [Double] // 11 points (0-10 seconds, one per second)
    
    init(id: UUID = UUID(), name: String, torquePoints: [Double] = Array(repeating: 0.0, count: 11)) {
        self.id = id
        self.name = name
        self.torquePoints = torquePoints.count == 11 ? torquePoints : Array(repeating: 0.0, count: 11)
    }
}

// Primary sport enum
enum PrimarySport: String, CaseIterable, Codable {
    case footballUS = "Football (US)"
    case footballWorld = "Football (World)"
    case soccer = "Soccer"
    case track = "Track"
    case basketball = "Basketball"
    case baseball = "Baseball"
    case tennis = "Tennis"
    case other = "Other"
    
    // Default unit system for each sport
    var defaultUnits: UnitSystem {
        switch self {
        case .footballUS, .baseball, .basketball:
            return .imperial
        case .footballWorld, .soccer, .track, .tennis, .other:
            return .metric
        }
    }
}

// Unit system enum
enum UnitSystem: String, CaseIterable, Codable {
    case metric = "Metric"
    case imperial = "Imperial"
}

// User profile model with sports and personal settings
struct User: Identifiable, Codable {
    let id: UUID
    var name: String
    
    // Sports Settings
    var language: String
    var primarySport: PrimarySport
    var unitSystem: UnitSystem
    var useCustomUnits: Bool // If true, use unitSystem; if false, use primarySport.defaultUnits
    
    // Personal Settings
    var height: Double // in cm (metric) or inches (imperial)
    var weight: Double // in kg (metric) or lbs (imperial)
    var age: Int
    
    init(
        id: UUID = UUID(),
        name: String = "",
        language: String = "English",
        primarySport: PrimarySport = .track,
        unitSystem: UnitSystem = .metric,
        useCustomUnits: Bool = false,
        height: Double = 0,
        weight: Double = 0,
        age: Int = 0
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.primarySport = primarySport
        self.unitSystem = unitSystem
        self.useCustomUnits = useCustomUnits
        self.height = height
        self.weight = weight
        self.age = age
    }
    
    // Computed property to get the effective unit system
    var effectiveUnitSystem: UnitSystem {
        useCustomUnits ? unitSystem : primarySport.defaultUnits
    }
}

// Legacy UserProfile for backward compatibility (can be removed later)
struct UserProfile: Codable {
    var name: String
    var weight: Double // in kg
    var height: Double // in cm
    var age: Int
    
    init(name: String = "", weight: Double = 0, height: Double = 0, age: Int = 0) {
        self.name = name
        self.weight = weight
        self.height = height
        self.age = age
    }
}
