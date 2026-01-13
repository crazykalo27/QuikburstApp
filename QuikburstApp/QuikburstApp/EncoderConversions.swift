import Foundation

/// Utility functions for converting encoder counts to physical measurements
struct EncoderConversions {
    // Encoder constants (from Arduino code: bluetooth_encoder.ino)
    static let COUNTS_PER_REV: Double = 2400.0  // 600 PPR * 4 (quadrature)
    static let SPOOL_RADIUS_M: Double = 0.1016   // 4 inches in meters
    
    /// Convert encoder counts to distance in meters
    static func countsToDistance(_ counts: Double) -> Double {
        let revolutions = counts / COUNTS_PER_REV
        return revolutions * 2 * .pi * SPOOL_RADIUS_M
    }
    
    /// Calculate speed (m/s) from distance change over time
    static func calculateSpeed(distanceDelta: Double, timeDelta: TimeInterval) -> Double {
        guard timeDelta > 0 else { return 0 }
        return distanceDelta / timeDelta
    }
    
    /// Calculate force (N) from speed and acceleration
    /// For a simple model: F = m * a, but we need mass
    /// For now, we'll estimate force from power: P = F * v, so F = P / v
    /// Or we can use: F = m * (dv/dt) where m is estimated user mass
    /// For a more accurate model, we'd need to know the user's mass
    /// This is a simplified estimation assuming average user mass of 70kg
    static func estimateForceFromAcceleration(speed1: Double, speed2: Double, timeDelta: TimeInterval, userMassKg: Double = 70.0) -> Double {
        guard timeDelta > 0 else { return 0 }
        let acceleration = (speed2 - speed1) / timeDelta
        return userMassKg * acceleration
    }
    
    /// Calculate force from power and speed: F = P / v
    static func estimateForceFromPower(powerW: Double, speedMps: Double) -> Double {
        guard speedMps > 0 else { return 0 }
        return powerW / speedMps
    }
    
    /// Calculate power from force and speed: P = F * v
    static func calculatePower(forceN: Double, speedMps: Double) -> Double {
        return forceN * speedMps
    }
    
    /// Analyze encoder samples to extract metrics
    struct PhaseMetrics {
        let peakForce: Double
        let averageForce: Double
        let peakSpeed: Double
        let averageSpeed: Double
        let duration: TimeInterval
        let distance: Double
    }
    
    /// Analyze a phase of encoder data
    /// samples: encoder count samples for this phase
    /// phaseType: whether this is a force drill (time-based) or speed drill (distance-based)
    static func analyzePhase(samples: [SensorSample], phaseType: DrillType, userMassKg: Double = 70.0) -> PhaseMetrics? {
        guard samples.count >= 2 else { return nil }
        
        // Convert counts to distances
        let distances = samples.map { countsToDistance($0.value) }
        
        // Calculate speeds from distance changes (instantaneous speed)
        var speeds: [Double] = []
        for i in 1..<samples.count {
            let timeDelta = samples[i].timestamp.timeIntervalSince(samples[i-1].timestamp)
            let distanceDelta = distances[i] - distances[i-1]
            let speed = calculateSpeed(distanceDelta: distanceDelta, timeDelta: timeDelta)
            speeds.append(max(0, speed)) // Ensure non-negative
        }
        
        guard !speeds.isEmpty else { return nil }
        
        // Calculate forces from acceleration
        // For a resisted sprint system, force can be estimated from:
        // 1. Acceleration: F = m * a (where a = dv/dt)
        // 2. Power: F = P / v (where P is power output)
        // We'll use a combination approach with smoothing
        var forces: [Double] = []
        
        // Method 1: Calculate from acceleration (for dynamic force)
        for i in 1..<speeds.count {
            let timeDelta = samples[i+1].timestamp.timeIntervalSince(samples[i].timestamp)
            if timeDelta > 0 && i+1 < samples.count {
                let acceleration = (speeds[i] - speeds[i-1]) / timeDelta
                // Force = mass * acceleration (net force)
                // For resisted sprint, this represents the net force overcoming resistance
                let force = userMassKg * abs(acceleration)
                forces.append(force)
            }
        }
        
        // Method 2: If we have speed data, also estimate from power
        // Power = Force * Velocity, so Force = Power / Velocity
        // Power can be estimated from work done: P = Work / time = (F * d) / t = F * v
        // For a more stable estimate, use average speed over the interval
        if forces.count < speeds.count / 2 {
            // Supplement with power-based estimates
            for i in 1..<speeds.count {
                if i < samples.count - 1 {
                    let timeDelta = samples[i+1].timestamp.timeIntervalSince(samples[i].timestamp)
                    if timeDelta > 0 {
                        let avgSpeed = (speeds[i-1] + speeds[i]) / 2.0
                        if avgSpeed > 0.1 { // Avoid division by very small numbers
                            // Estimate power from kinetic energy change
                            let energy1 = 0.5 * userMassKg * speeds[i-1] * speeds[i-1]
                            let energy2 = 0.5 * userMassKg * speeds[i] * speeds[i]
                            let power = abs(energy2 - energy1) / timeDelta
                            let force = power / avgSpeed
                            forces.append(force)
                        }
                    }
                }
            }
        }
        
        // Calculate total distance and duration
        let totalDistance = max(0, distances.last! - distances.first!)
        let duration = max(0.1, samples.last!.timestamp.timeIntervalSince(samples.first!.timestamp))
        
        // Calculate average speed from total distance and duration (more accurate than mean of instantaneous speeds)
        let averageSpeedFromDistance = totalDistance / duration
        
        return PhaseMetrics(
            peakForce: forces.max() ?? 0,
            averageForce: forces.isEmpty ? 0 : forces.reduce(0, +) / Double(forces.count),
            peakSpeed: speeds.max() ?? 0,
            averageSpeed: averageSpeedFromDistance > 0 ? averageSpeedFromDistance : (speeds.reduce(0, +) / Double(speeds.count)),
            duration: duration,
            distance: totalDistance
        )
    }
}
