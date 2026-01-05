import Foundation

struct SensorSample: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}
struct RunRecord: Identifiable, Hashable, Codable {
    let id = UUID()
    let date: Date
    let duration: TimeInterval // seconds
    let averageValue: Double
    let peakValue: Double
}

