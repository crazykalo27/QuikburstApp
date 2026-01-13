import Foundation

struct EnforcementPlanGenerator {
    
    /// Generate an enforcement plan from template, baseline, and recent runs
    static func generatePlan(
        template: DrillTemplate,
        baseline: DrillBaseline?,
        recentRuns: [DrillRun] = []
    ) -> EnforcementPlan? {
        
        // If no baseline exists, cannot generate enforced plan
        guard let baseline = baseline else {
            return nil
        }
        
        // If template is probationary, only allow baseline runs (no enforcement)
        if template.probationStatus == .probationary {
            return nil
        }
        
        // Calculate capability estimate from recent runs (EWMA)
        let capabilityAvgSpeed = calculateCapabilityEstimate(
            baseline: baseline,
            recentRuns: recentRuns
        )
        
        // Generate plan based on target mode
        switch template.targetMode {
        case .speedPercentOfBaseline:
            return generateSpeedPercentPlan(
                template: template,
                baseline: baseline,
                capabilityAvgSpeed: capabilityAvgSpeed
            )
            
        case .distanceAndTime:
            return generateDistanceTimePlan(
                template: template,
                baseline: baseline,
                capabilityAvgSpeed: capabilityAvgSpeed
            )
            
        case .distanceOnly:
            return generateDistanceOnlyPlan(
                template: template,
                baseline: baseline,
                capabilityAvgSpeed: capabilityAvgSpeed
            )
            
        case .timeOnly:
            return generateTimeOnlyPlan(
                template: template,
                baseline: baseline,
                capabilityAvgSpeed: capabilityAvgSpeed
            )
            
        case .forcePercentOfBaseline:
            // Future implementation
            return nil
        }
    }
    
    private static func calculateCapabilityEstimate(
        baseline: DrillBaseline,
        recentRuns: [DrillRun],
        alpha: Double = 0.3,
        n: Int = 5
    ) -> Double {
        guard !recentRuns.isEmpty else {
            return baseline.baselineAvgSpeedMps
        }
        
        let recentSpeeds = recentRuns.prefix(n).map { $0.results.avgSpeedMps }
        guard !recentSpeeds.isEmpty else {
            return baseline.baselineAvgSpeedMps
        }
        
        // EWMA calculation
        var estimate = baseline.baselineAvgSpeedMps
        for speed in recentSpeeds.reversed() {
            estimate = alpha * speed + (1 - alpha) * estimate
        }
        
        return estimate
    }
    
    private static func generateSpeedPercentPlan(
        template: DrillTemplate,
        baseline: DrillBaseline,
        capabilityAvgSpeed: Double
    ) -> EnforcementPlan {
        guard let speedPercent = template.speedPercentOfBaseline else {
            // Default to 100% if not specified
            return createBaselineScaledPlan(
                template: template,
                baseline: baseline,
                scaleFactor: 1.0
            )
        }
        
        // Calculate scale factor using capability estimate
        let targetSpeed = baseline.baselineAvgSpeedMps * (speedPercent / 100.0)
        let scaleFactor = targetSpeed / baseline.baselineAvgSpeedMps
        
        // Clamp scale factor to safe bounds (0.6 to 1.2)
        let clampedScale = max(0.6, min(1.2, scaleFactor))
        
        // Ensure peak speed doesn't exceed 110% of baseline peak
        let maxPeakSpeed = baseline.baselinePeakSpeedMps * 1.10
        
        return createBaselineScaledPlan(
            template: template,
            baseline: baseline,
            scaleFactor: clampedScale,
            maxPeakSpeed: maxPeakSpeed
        )
    }
    
    private static func generateDistanceTimePlan(
        template: DrillTemplate,
        baseline: DrillBaseline,
        capabilityAvgSpeed: Double
    ) -> EnforcementPlan {
        guard let distance = template.distanceMeters,
              let time = template.targetTimeSeconds else {
            return createBaselineScaledPlan(template: template, baseline: baseline, scaleFactor: 1.0)
        }
        
        let desiredAvgSpeed = distance / time
        
        // Use generic curve shape that matches distance/time
        let velocityCurve = generateGenericVelocityCurve(
            targetDistance: distance,
            targetTime: time,
            peakSpeed: min(desiredAvgSpeed * 1.5, baseline.baselinePeakSpeedMps * 1.1)
        )
        
        return EnforcementPlan(
            templateId: template.id,
            planType: .velocityCurve,
            targetDistanceMeters: distance,
            targetDurationSeconds: time,
            velocityCurve: velocityCurve,
            enforcementLevel: 1.0,
            notes: "\(distance)m in \(String(format: "%.1f", time))s"
        )
    }
    
    private static func generateDistanceOnlyPlan(
        template: DrillTemplate,
        baseline: DrillBaseline,
        capabilityAvgSpeed: Double
    ) -> EnforcementPlan {
        guard let distance = template.distanceMeters else {
            return createBaselineScaledPlan(template: template, baseline: baseline, scaleFactor: 1.0)
        }
        
        // Estimate time based on capability
        let estimatedTime = distance / capabilityAvgSpeed
        
        return generateDistanceTimePlan(
            template: template,
            baseline: baseline,
            capabilityAvgSpeed: capabilityAvgSpeed
        )
    }
    
    private static func generateTimeOnlyPlan(
        template: DrillTemplate,
        baseline: DrillBaseline,
        capabilityAvgSpeed: Double
    ) -> EnforcementPlan {
        guard let time = template.targetTimeSeconds else {
            return createBaselineScaledPlan(template: template, baseline: baseline, scaleFactor: 1.0)
        }
        
        // Estimate distance based on capability
        let estimatedDistance = capabilityAvgSpeed * time
        
        return generateDistanceTimePlan(
            template: template,
            baseline: baseline,
            capabilityAvgSpeed: capabilityAvgSpeed
        )
    }
    
    private static func createBaselineScaledPlan(
        template: DrillTemplate,
        baseline: DrillBaseline,
        scaleFactor: Double,
        maxPeakSpeed: Double? = nil
    ) -> EnforcementPlan {
        // Scale baseline velocity profile
        var scaledCurve = baseline.baselineVelocityProfileSummary.map { sample in
            var scaledSpeed = sample.vMps * scaleFactor
            if let maxPeak = maxPeakSpeed {
                scaledSpeed = min(scaledSpeed, maxPeak)
            }
            return VelocitySampleSummary(
                tNormalized: sample.tNormalized,
                vMps: max(0, scaledSpeed)
            )
        }
        
        // Downsample to 30-50 points if needed
        if scaledCurve.count > 50 {
            scaledCurve = downsampleVelocityProfile(scaledCurve, targetCount: 50)
        }
        
        let notes: String
        if let speedPercent = template.speedPercentOfBaseline {
            notes = "\(String(format: "%.1f", speedPercent))% baseline speed target"
        } else {
            notes = "Scaled baseline profile (factor: \(String(format: "%.2f", scaleFactor)))"
        }
        
        return EnforcementPlan(
            templateId: template.id,
            planType: .velocityCurve,
            targetDistanceMeters: template.distanceMeters,
            targetDurationSeconds: template.targetTimeSeconds,
            velocityCurve: scaledCurve,
            enforcementLevel: 1.0,
            notes: notes
        )
    }
    
    private static func generateGenericVelocityCurve(
        targetDistance: Double,
        targetTime: Double,
        peakSpeed: Double
    ) -> [VelocitySampleSummary] {
        // Generate a generic ease-in → plateau → ease-out curve
        let pointCount = 40
        var curve: [VelocitySampleSummary] = []
        
        for i in 0..<pointCount {
            let tNormalized = Double(i) / Double(pointCount - 1)
            
            // Ease-in (0-0.2), plateau (0.2-0.8), ease-out (0.8-1.0)
            let speed: Double
            if tNormalized < 0.2 {
                // Ease-in: quadratic
                let t = tNormalized / 0.2
                speed = peakSpeed * t * t
            } else if tNormalized < 0.8 {
                // Plateau
                speed = peakSpeed
            } else {
                // Ease-out: quadratic
                let t = (tNormalized - 0.8) / 0.2
                speed = peakSpeed * (1 - t * t)
            }
            
            curve.append(VelocitySampleSummary(tNormalized: tNormalized, vMps: speed))
        }
        
        // Scale to match target distance
        let totalDistance = integrateVelocityCurve(curve, totalTime: targetTime)
        if totalDistance > 0 {
            let scaleFactor = targetDistance / totalDistance
            curve = curve.map { sample in
                VelocitySampleSummary(tNormalized: sample.tNormalized, vMps: sample.vMps * scaleFactor)
            }
        }
        
        return curve
    }
    
    private static func integrateVelocityCurve(_ curve: [VelocitySampleSummary], totalTime: Double) -> Double {
        guard curve.count >= 2 else { return 0 }
        
        var distance = 0.0
        for i in 1..<curve.count {
            let dt = (curve[i].tNormalized - curve[i-1].tNormalized) * totalTime
            let avgSpeed = (curve[i].vMps + curve[i-1].vMps) / 2.0
            distance += avgSpeed * dt
        }
        return distance
    }
    
    private static func downsampleVelocityProfile(
        _ profile: [VelocitySampleSummary],
        targetCount: Int
    ) -> [VelocitySampleSummary] {
        guard profile.count > targetCount else { return profile }
        
        let step = Double(profile.count) / Double(targetCount)
        var downsampled: [VelocitySampleSummary] = []
        
        for i in 0..<targetCount {
            let index = Int(Double(i) * step)
            if index < profile.count {
                downsampled.append(profile[index])
            }
        }
        
        return downsampled
    }
    
    /// Create baseline velocity profile summary from velocity samples
    static func createBaselineVelocityProfile(from samples: [VelocitySample]) -> [VelocitySampleSummary] {
        guard !samples.isEmpty else { return [] }
        
        let totalDuration = samples.last!.timestamp.timeIntervalSince(samples.first!.timestamp)
        guard totalDuration > 0 else { return [] }
        
        // Normalize timestamps and downsample to 30-50 points
        let targetCount = min(50, max(30, samples.count / 10))
        let step = Double(samples.count) / Double(targetCount)
        
        var profile: [VelocitySampleSummary] = []
        
        for i in 0..<targetCount {
            let index = Int(Double(i) * step)
            if index < samples.count {
                let sample = samples[index]
                let tNormalized = sample.timestamp.timeIntervalSince(samples.first!.timestamp) / totalDuration
                profile.append(VelocitySampleSummary(
                    tNormalized: min(1.0, max(0.0, tNormalized)),
                    vMps: sample.velocityMps
                ))
            }
        }
        
        return profile
    }
    
    /// Calculate derived comparisons for a run vs baseline
    static func calculateComparisons(
        run: DrillRun,
        baseline: DrillBaseline
    ) -> DerivedComparisons {
        let speedPercent = (run.results.avgSpeedMps / baseline.baselineAvgSpeedMps) * 100.0
        let timePercent = (baseline.baselineTimeSeconds / run.results.durationSeconds) * 100.0
        
        let powerPercent: Double?
        if let runPower = run.results.powerEstimateW,
           let baselinePower = baseline.baselinePowerEstimateW,
           baselinePower > 0 {
            powerPercent = (runPower / baselinePower) * 100.0
        } else {
            powerPercent = nil
        }
        
        let forcePercent: Double?
        if let runForce = run.results.forceEstimateN,
           let baselineForce = baseline.baselineForceEstimateN,
           baselineForce > 0 {
            forcePercent = (runForce / baselineForce) * 100.0
        } else {
            forcePercent = nil
        }
        
        return DerivedComparisons(
            percentVsBaselineSpeed: speedPercent,
            percentVsBaselineTime: timePercent,
            percentVsBaselinePower: powerPercent,
            percentVsBaselineForce: forcePercent
        )
    }
}
