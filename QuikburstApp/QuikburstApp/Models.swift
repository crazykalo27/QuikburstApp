import Foundation
import CryptoKit

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
    case run = "Run"
    case sprint = "Sprint"
    case resistedRun = "Resisted Run"
    case standard = "Standard"
    case custom = "Custom"
    case forceDrill = "Force Drill"
    case speedDrill = "Speed Drill"
}

enum ForceType: String, Codable {
    case constant = "constant"
    case percentile = "percentile"
}

struct TorquePoint: Codable {
    let timeNormalized: Double // 0.0 to 1.0
    let forceN: Double // Force in Newtons
}

// MARK: - New Drill System Models

enum TargetMode: String, Codable {
    case distanceOnly = "distanceOnly"
    case timeOnly = "timeOnly"
    case distanceAndTime = "distanceAndTime"
    case speedPercentOfBaseline = "speedPercentOfBaseline"
    case forcePercentOfBaseline = "forcePercentOfBaseline"
}

enum EnforcementIntent: String, Codable {
    case none = "none"
    case velocityCurve = "velocityCurve"
    case torqueEnvelope = "torqueEnvelope"
    case hybrid = "hybrid"
}

enum ProbationStatus: String, Codable {
    case probationary = "probationary"
    case baselineCaptured = "baselineCaptured"
}

enum RunMode: String, Codable {
    case baselineNoEnforcement = "baselineNoEnforcement"
    case enforced = "enforced"
}

enum PlanType: String, Codable {
    case velocityCurve = "velocityCurve"
    case torqueEnvelope = "torqueEnvelope"
}

struct VelocitySampleSummary: Codable {
    let tNormalized: Double // 0.0 to 1.0
    let vMps: Double // meters per second
}

struct VelocitySample: Codable {
    let timestamp: Date
    let velocityMps: Double
    let distanceMeters: Double?
}

struct DerivedComparisons: Codable {
    let percentVsBaselineSpeed: Double?
    let percentVsBaselineTime: Double?
    let percentVsBaselinePower: Double?
    let percentVsBaselineForce: Double?
}

struct RunResults: Codable {
    let distanceMeters: Double
    let durationSeconds: Double
    let avgSpeedMps: Double
    let peakSpeedMps: Double
    let powerEstimateW: Double?
    let forceEstimateN: Double?
    let velocityTimeSeries: [VelocitySample]
}

enum QuikburstMode: String, Codable {
    case resist = "Resist"
    case assist = "Assist"
    case measure = "Measure"
}

enum DurationUnit: String, Codable {
    case seconds = "seconds"
    case meters = "meters"
    case yards = "yards"
}

// Drill phase structure for multi-phase drills
struct DrillPhase: Identifiable, Codable {
    let id: UUID
    var drillType: DrillType // Force or Speed drill
    var quikburstMode: QuikburstMode // Machine behavior mode
    var distanceMeters: Double? // For speed drills
    var targetTimeSeconds: Double? // For force drills
    var durationValue: Double? // Drill duration value
    var durationUnit: DurationUnit? // Unit for duration (seconds, meters, yards)
    var forceType: ForceType // Constant or percentile
    var constantForceN: Double? // Force value for constant mode (Newtons) - single value or min for live variation
    var constantForceMaxN: Double? // Max force for live variation
    var forcePercentOfBaseline: Double? // For percentile mode - single value or min for live variation
    var forcePercentOfBaselineMax: Double? // Max percent for live variation
    var liveVariation: Bool // Whether to use live variation (bounds instead of fixed value)
    var wantsBaseline: Bool // Whether baseline is needed (for force drills)
    var rampupTimeSeconds: Double? // Rampup time 1-5 seconds for constant force
    var torqueCurve: [TorquePoint]? // Custom torque curve (deprecated, kept for backward compatibility)
    
    // Legacy support for isResist/isAssist
    var isResist: Bool {
        get { quikburstMode == .resist }
        set { if newValue { quikburstMode = .resist } }
    }
    
    var isAssist: Bool {
        get { quikburstMode == .assist }
        set { if newValue { quikburstMode = .assist } }
    }
    
    init(
        id: UUID = UUID(),
        drillType: DrillType = .speedDrill,
        quikburstMode: QuikburstMode = .resist,
        distanceMeters: Double? = nil,
        targetTimeSeconds: Double? = nil,
        durationValue: Double? = nil,
        durationUnit: DurationUnit? = nil,
        forceType: ForceType = .constant,
        constantForceN: Double? = nil,
        constantForceMaxN: Double? = nil,
        forcePercentOfBaseline: Double? = nil,
        forcePercentOfBaselineMax: Double? = nil,
        liveVariation: Bool = false,
        wantsBaseline: Bool = false,
        rampupTimeSeconds: Double? = nil,
        torqueCurve: [TorquePoint]? = nil
    ) {
        self.id = id
        self.drillType = drillType
        self.quikburstMode = quikburstMode
        self.distanceMeters = distanceMeters
        self.targetTimeSeconds = targetTimeSeconds
        self.durationValue = durationValue
        self.durationUnit = durationUnit
        self.forceType = forceType
        self.constantForceN = constantForceN
        self.constantForceMaxN = constantForceMaxN
        self.forcePercentOfBaseline = forcePercentOfBaseline
        self.forcePercentOfBaselineMax = forcePercentOfBaselineMax
        self.liveVariation = liveVariation
        self.wantsBaseline = wantsBaseline
        self.rampupTimeSeconds = rampupTimeSeconds
        self.torqueCurve = torqueCurve
    }
}

struct DrillTemplate: Identifiable, Codable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var description: String?
    var videoURL: String? // Optional video attachment URL
    var sportTag: String?
    var type: DrillType
    var isResist: Bool // Machine resists user movement (legacy - for single-phase drills)
    var isAssist: Bool // Machine assists user movement (legacy - for single-phase drills)
    var distanceMeters: Double? // Legacy - for single-phase speed drills
    var targetTimeSeconds: Double? // Legacy - Duration of drill in seconds for single-phase force drills
    var targetSpeedMps: Double?
    var targetMode: TargetMode
    var enforcementIntent: EnforcementIntent
    var probationStatus: ProbationStatus
    var identityKey: String
    
    // Multi-phase support
    var phases: [DrillPhase]? // If nil or empty, use legacy single-phase fields
    
    // Force/torque settings (legacy - for single-phase drills)
    var forceType: ForceType? // Constant or percentile
    var constantForceN: Double? // Force value for constant mode (Newtons)
    var rampupTimeSeconds: Double? // Rampup time 1-5 seconds for constant force
    var torqueCurve: [TorquePoint]? // Custom torque curve (for percentile or custom constant)
    
    // Percent targets for baseline-relative modes
    var speedPercentOfBaseline: Double? // e.g., 90.0 means 90% of baseline speed
    var forcePercentOfBaseline: Double?
    
    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        name: String,
        description: String? = nil,
        videoURL: String? = nil,
        sportTag: String? = nil,
        type: DrillType = .speedDrill,
        isResist: Bool = false,
        isAssist: Bool = false,
        distanceMeters: Double? = nil,
        targetTimeSeconds: Double? = nil,
        targetSpeedMps: Double? = nil,
        targetMode: TargetMode = .distanceOnly,
        enforcementIntent: EnforcementIntent = .none,
        probationStatus: ProbationStatus = .probationary,
        identityKey: String = "",
        phases: [DrillPhase]? = nil,
        forceType: ForceType? = nil,
        constantForceN: Double? = nil,
        rampupTimeSeconds: Double? = nil,
        torqueCurve: [TorquePoint]? = nil,
        speedPercentOfBaseline: Double? = nil,
        forcePercentOfBaseline: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.name = name
        self.description = description
        self.videoURL = videoURL
        self.sportTag = sportTag
        self.type = type
        self.isResist = isResist
        self.isAssist = isAssist
        self.distanceMeters = distanceMeters
        self.targetTimeSeconds = targetTimeSeconds
        self.targetSpeedMps = targetSpeedMps
        self.targetMode = targetMode
        self.enforcementIntent = enforcementIntent
        self.probationStatus = probationStatus
        self.phases = phases
        self.identityKey = identityKey.isEmpty ? DrillTemplate.generateIdentityKey(
            name: name,
            type: type,
            distanceMeters: distanceMeters,
            targetMode: targetMode,
            speedPercent: speedPercentOfBaseline,
            forcePercent: forcePercentOfBaseline
        ) : identityKey
        self.forceType = forceType
        self.constantForceN = constantForceN
        self.rampupTimeSeconds = rampupTimeSeconds
        self.torqueCurve = torqueCurve
        self.speedPercentOfBaseline = speedPercentOfBaseline
        self.forcePercentOfBaseline = forcePercentOfBaseline
    }
    
    // Helper to get effective phases (returns phases if available, otherwise creates single phase from legacy fields)
    var effectivePhases: [DrillPhase] {
        if let phases = phases, !phases.isEmpty {
            return phases
        }
        // Create single phase from legacy fields
        let quikburstMode: QuikburstMode = isResist ? .resist : (isAssist ? .assist : .resist)
        var phase = DrillPhase(
            drillType: type,
            quikburstMode: quikburstMode,
            distanceMeters: distanceMeters,
            targetTimeSeconds: targetTimeSeconds,
            forceType: forceType ?? .constant,
            constantForceN: constantForceN,
            constantForceMaxN: nil, // Legacy fields don't support live variation bounds
            forcePercentOfBaseline: forcePercentOfBaseline,
            forcePercentOfBaselineMax: nil, // Legacy fields don't support live variation bounds
            liveVariation: false, // Legacy fields don't support live variation
            rampupTimeSeconds: rampupTimeSeconds,
            torqueCurve: torqueCurve
        )
        // Set duration value and unit from legacy fields
        if let time = targetTimeSeconds {
            phase.durationValue = time
            phase.durationUnit = DurationUnit.seconds
        } else if let distance = distanceMeters {
            phase.durationValue = distance
            phase.durationUnit = DurationUnit.meters
        }
        return [phase]
    }
    
    static func generateIdentityKey(
        name: String,
        type: DrillType,
        distanceMeters: Double?,
        targetMode: TargetMode,
        speedPercent: Double?,
        forcePercent: Double?
    ) -> String {
        // Normalize name (lowercase, trim)
        let normalizedName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Round distance to nearest 0.5m
        let roundedDistance = distanceMeters.map { round($0 * 2) / 2 }
        
        // Round percents to nearest 0.5%
        let roundedSpeedPercent = speedPercent.map { round($0 * 2) / 2 }
        let roundedForcePercent = forcePercent.map { round($0 * 2) / 2 }
        
        // Build signature string
        var signature = "\(normalizedName)|\(type.rawValue)|"
        signature += "\(roundedDistance.map { String(format: "%.1f", $0) } ?? "nil")|"
        signature += "\(targetMode.rawValue)|"
        signature += "\(roundedSpeedPercent.map { String(format: "%.1f", $0) } ?? "nil")|"
        signature += "\(roundedForcePercent.map { String(format: "%.1f", $0) } ?? "nil")|"
        signature += "v1" // version
        
        // Hash to SHA256 and truncate to 16 chars
        let data = signature.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return String(hashString.prefix(16))
    }
}

struct DrillBaseline: Identifiable, Codable {
    let id: UUID
    let templateId: UUID
    let createdAt: Date
    let baselineRunId: UUID
    let baselineDistanceMeters: Double
    let baselineTimeSeconds: Double
    let baselineAvgSpeedMps: Double
    let baselinePeakSpeedMps: Double
    let baselinePowerEstimateW: Double?
    let baselineForceEstimateN: Double?
    let baselineVelocityProfileSummary: [VelocitySampleSummary]
    
    init(
        id: UUID = UUID(),
        templateId: UUID,
        createdAt: Date = Date(),
        baselineRunId: UUID,
        baselineDistanceMeters: Double,
        baselineTimeSeconds: Double,
        baselineAvgSpeedMps: Double,
        baselinePeakSpeedMps: Double,
        baselinePowerEstimateW: Double? = nil,
        baselineForceEstimateN: Double? = nil,
        baselineVelocityProfileSummary: [VelocitySampleSummary] = []
    ) {
        self.id = id
        self.templateId = templateId
        self.createdAt = createdAt
        self.baselineRunId = baselineRunId
        self.baselineDistanceMeters = baselineDistanceMeters
        self.baselineTimeSeconds = baselineTimeSeconds
        self.baselineAvgSpeedMps = baselineAvgSpeedMps
        self.baselinePeakSpeedMps = baselinePeakSpeedMps
        self.baselinePowerEstimateW = baselinePowerEstimateW
        self.baselineForceEstimateN = baselineForceEstimateN
        self.baselineVelocityProfileSummary = baselineVelocityProfileSummary
    }
}

struct DrillRun: Identifiable, Codable {
    let id: UUID
    let templateId: UUID
    let timestamp: Date
    let runMode: RunMode
    var requestedPlan: EnforcementPlan?
    let results: RunResults
    var notes: String?
    var derivedComparisons: DerivedComparisons?
    
    init(
        id: UUID = UUID(),
        templateId: UUID,
        timestamp: Date = Date(),
        runMode: RunMode,
        requestedPlan: EnforcementPlan? = nil,
        results: RunResults,
        notes: String? = nil,
        derivedComparisons: DerivedComparisons? = nil
    ) {
        self.id = id
        self.templateId = templateId
        self.timestamp = timestamp
        self.runMode = runMode
        self.requestedPlan = requestedPlan
        self.results = results
        self.notes = notes
        self.derivedComparisons = derivedComparisons
    }
}

struct EnforcementPlan: Identifiable, Codable {
    let id: UUID
    let templateId: UUID
    let createdAt: Date
    let planType: PlanType
    let targetDistanceMeters: Double?
    let targetDurationSeconds: Double?
    let velocityCurve: [VelocitySampleSummary]
    let enforcementLevel: Double // 0.0 to 1.0
    let notes: String
    
    init(
        id: UUID = UUID(),
        templateId: UUID,
        createdAt: Date = Date(),
        planType: PlanType,
        targetDistanceMeters: Double? = nil,
        targetDurationSeconds: Double? = nil,
        velocityCurve: [VelocitySampleSummary] = [],
        enforcementLevel: Double = 0.0,
        notes: String = ""
    ) {
        self.id = id
        self.templateId = templateId
        self.createdAt = createdAt
        self.planType = planType
        self.targetDistanceMeters = targetDistanceMeters
        self.targetDurationSeconds = targetDurationSeconds
        self.velocityCurve = velocityCurve
        self.enforcementLevel = enforcementLevel
        self.notes = notes
    }
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
    var workoutSessionId: UUID?
    /// Snapshot of workout name at completion time for display even if workout changes later
    var workoutNameSnapshot: String?
    var levelUsed: Int?
    var rawESP32Data: [SensorSample] // Store as array of samples
    var derivedMetrics: SessionMetrics
    
    init(
        id: UUID = UUID(),
        date: Date = Date(),
        mode: SessionMode,
        drillId: UUID? = nil,
        workoutId: UUID? = nil,
        workoutSessionId: UUID? = nil,
        workoutNameSnapshot: String? = nil,
        levelUsed: Int? = nil,
        rawESP32Data: [SensorSample] = [],
        derivedMetrics: SessionMetrics = SessionMetrics()
    ) {
        self.id = id
        self.date = date
        self.mode = mode
        self.drillId = drillId
        self.workoutId = workoutId
        self.workoutSessionId = workoutSessionId
        self.workoutNameSnapshot = workoutNameSnapshot
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

// MARK: - ESP32 Drill Command Models (JSON Protocol)

struct DrillStartCommand: Codable {
    let type: String
    let id: UInt32
    let targetSpeed: Double // m/s
    let durationMs: UInt32? // 0 if unused
    let targetDistance: Double? // meters, 0 if unused
    let forcePercent: Double // 0-100, maps to max PWM duty
    let rampMs: UInt32 // ramp time in ms
    let direction: Int // +1 forward, -1 reverse
    
    init(id: UInt32, targetSpeed: Double, durationMs: UInt32? = nil, targetDistance: Double? = nil, forcePercent: Double, rampMs: UInt32, direction: Int) {
        self.type = "drillStart"
        self.id = id
        self.targetSpeed = targetSpeed
        self.durationMs = durationMs
        self.targetDistance = targetDistance
        self.forcePercent = max(0, min(100, forcePercent)) // Clamp to 0-100
        self.rampMs = rampMs
        self.direction = direction > 0 ? 1 : -1
    }
}

struct DrillAbortCommand: Codable {
    let type: String
    
    init() {
        self.type = "drillAbort"
    }
}

struct DrillTelemetry: Codable {
    let type: String
    let id: UInt32
    let t: UInt32 // elapsed time in ms
    let speed: Double // m/s
    let position: Int32 // encoder position
    let distance: Double // meters from start
    let duty: Double // PWM duty (0-1)
    let state: String // "RAMP", "HOLD", "DONE", "IDLE", "ABORT"
}

struct DrillAck: Codable {
    let type: String
    let id: UInt32?
    let status: String
}

