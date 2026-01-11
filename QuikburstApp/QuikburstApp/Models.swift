import Foundation

struct SensorSample: Identifiable, Hashable, Codable {
    let id: UUID
    let timestamp: Date
    let value: Double
    
    init(id: UUID = UUID(), timestamp: Date, value: Double) {
        self.id = id
        self.timestamp = timestamp
        self.value = value
    }
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

// MARK: - Drill Models

enum DrillCategory: String, CaseIterable, Codable {
    case speed = "Speed"
    case force = "Force"
}

enum DrillType: String, CaseIterable, Codable {
    case standard = "Standard"
    case custom = "Custom"
}

struct Drill: Identifiable, Codable {
    let id: UUID
    var name: String
    var category: DrillCategory
    var isResistive: Bool
    var isAssistive: Bool
    var type: DrillType?
    var lengthSeconds: Int
    var isCustom: Bool
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var torqueProfileId: UUID? // Reference to TorqueProfile if applicable
    
    init(
        id: UUID = UUID(),
        name: String,
        category: DrillCategory,
        isResistive: Bool = false,
        isAssistive: Bool = false,
        type: DrillType? = nil,
        lengthSeconds: Int,
        isCustom: Bool = false,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        torqueProfileId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.isResistive = isResistive
        self.isAssistive = isAssistive
        self.type = type
        self.lengthSeconds = lengthSeconds
        self.isCustom = isCustom
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.torqueProfileId = torqueProfileId
    }
}

// MARK: - Workout Models

struct WorkoutItem: Identifiable, Codable {
    let id: UUID
    var drillId: UUID
    var reps: Int
    var restSeconds: Int
    var level: Int?
    
    init(
        id: UUID = UUID(),
        drillId: UUID,
        reps: Int = 1,
        restSeconds: Int = 0,
        level: Int? = nil
    ) {
        self.id = id
        self.drillId = drillId
        self.reps = reps
        self.restSeconds = restSeconds
        self.level = level
    }
}

struct Workout: Identifiable, Codable {
    let id: UUID
    var name: String
    var items: [WorkoutItem]
    var isCustom: Bool
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        items: [WorkoutItem] = [],
        isCustom: Bool = true,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.isCustom = isCustom
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Session Result Models

enum SessionMode: String, Codable {
    case drill = "Drill"
    case workout = "Workout"
}

struct SessionResult: Identifiable, Codable {
    let id: UUID
    var date: Date
    var mode: SessionMode
    var drillId: UUID?
    var workoutId: UUID?
    var levelUsed: Int?
    var rawESP32Data: [SensorSample] // Store as array of samples
    var derivedMetrics: SessionMetrics
    
    init(
        id: UUID = UUID(),
        date: Date = Date(),
        mode: SessionMode,
        drillId: UUID? = nil,
        workoutId: UUID? = nil,
        levelUsed: Int? = nil,
        rawESP32Data: [SensorSample] = [],
        derivedMetrics: SessionMetrics = SessionMetrics()
    ) {
        self.id = id
        self.date = date
        self.mode = mode
        self.drillId = drillId
        self.workoutId = workoutId
        self.levelUsed = levelUsed
        self.rawESP32Data = rawESP32Data
        self.derivedMetrics = derivedMetrics
    }
}

struct SessionMetrics: Codable {
    var peakForce: Double?
    var averageForce: Double?
    var duration: TimeInterval?
    var totalWork: Double?
    
    init(
        peakForce: Double? = nil,
        averageForce: Double? = nil,
        duration: TimeInterval? = nil,
        totalWork: Double? = nil
    ) {
        self.peakForce = peakForce
        self.averageForce = averageForce
        self.duration = duration
        self.totalWork = totalWork
    }
}

