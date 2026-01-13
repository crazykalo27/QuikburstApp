import SwiftUI

struct DrillRunView: View {
    let template: DrillTemplate
    @ObservedObject var templateStore: DrillTemplateStore
    @ObservedObject var baselineStore: DrillBaselineStore
    @ObservedObject var runStore: DrillRunStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var runMode: RunMode = .baselineNoEnforcement
    @State private var isRunning = false
    @State private var isComplete = false
    @State private var runResults: RunResults?
    @State private var velocitySamples: [VelocitySample] = []
    @State private var startTime: Date?
    @State private var currentDistance: Double = 0
    @State private var currentTime: Double = 0
    @State private var currentSpeed: Double = 0
    
    private var plan: EnforcementPlan? {
        guard let baseline = baselineStore.getBaseline(for: template.id),
              template.probationStatus == .baselineCaptured else {
            return nil
        }
        
        let recentRuns = runStore.getRecentEnforcedRuns(for: template.id)
        return EnforcementPlanGenerator.generatePlan(
            template: template,
            baseline: baseline,
            recentRuns: recentRuns
        )
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                if isComplete, let results = runResults {
                    RunCompleteView(
                        template: template,
                        results: results,
                        baseline: baselineStore.getBaseline(for: template.id),
                        runMode: runMode,
                        onDismiss: {
                            dismiss()
                        }
                    )
                } else if isRunning {
                    RunningView(
                        currentDistance: currentDistance,
                        currentTime: currentTime,
                        currentSpeed: currentSpeed,
                        onStop: {
                            stopRun()
                        }
                    )
                } else {
                    PreRunView(
                        template: template,
                        runMode: runMode,
                        plan: plan,
                        baseline: baselineStore.getBaseline(for: template.id),
                        onStart: {
                            startRun()
                        }
                    )
                }
            }
            .padding()
            .navigationTitle(runMode == .baselineNoEnforcement ? "Baseline Run" : "Run Drill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func startRun() {
        runMode = template.probationStatus == .probationary ? .baselineNoEnforcement : .enforced
        isRunning = true
        startTime = Date()
        velocitySamples = []
        currentDistance = 0
        currentTime = 0
        currentSpeed = 0
        
        // TODO: Integrate with BluetoothManager to start recording
        // For now, simulate with timer
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            guard isRunning else {
                timer.invalidate()
                return
            }
            
            currentTime += 0.1
            // Simulate velocity (this would come from actual sensor data)
            let simulatedSpeed = 5.0 + Double.random(in: -0.5...0.5)
            currentSpeed = simulatedSpeed
            currentDistance += simulatedSpeed * 0.1
            
            velocitySamples.append(VelocitySample(
                timestamp: Date(),
                velocityMps: simulatedSpeed,
                distanceMeters: currentDistance
            ))
        }
    }
    
    private func stopRun() {
        isRunning = false
        
        guard let start = startTime, !velocitySamples.isEmpty else { return }
        
        let duration = Date().timeIntervalSince(start)
        let avgSpeed = velocitySamples.map { $0.velocityMps }.reduce(0, +) / Double(velocitySamples.count)
        let peakSpeed = velocitySamples.map { $0.velocityMps }.max() ?? 0
        
        let results = RunResults(
            distanceMeters: currentDistance,
            durationSeconds: duration,
            avgSpeedMps: avgSpeed,
            peakSpeedMps: peakSpeed,
            powerEstimateW: nil,
            forceEstimateN: nil,
            velocityTimeSeries: velocitySamples
        )
        
        runResults = results
        
        // Save the run
        let run = DrillRun(
            templateId: template.id,
            runMode: runMode,
            requestedPlan: plan,
            results: results
        )
        
        runStore.saveRun(run)
        
        // If baseline run, create baseline
        if runMode == .baselineNoEnforcement && template.probationStatus == .probationary {
            createBaseline(from: run)
        } else if runMode == .enforced, let baseline = baselineStore.getBaseline(for: template.id) {
            // Calculate comparisons
            let comparisons = EnforcementPlanGenerator.calculateComparisons(run: run, baseline: baseline)
            var updatedRun = run
            updatedRun.derivedComparisons = comparisons
            runStore.saveRun(updatedRun)
        }
        
        isComplete = true
    }
    
    private func createBaseline(from run: DrillRun) {
        let velocityProfile = EnforcementPlanGenerator.createBaselineVelocityProfile(
            from: run.results.velocityTimeSeries
        )
        
        let baseline = DrillBaseline(
            templateId: template.id,
            baselineRunId: run.id,
            baselineDistanceMeters: run.results.distanceMeters,
            baselineTimeSeconds: run.results.durationSeconds,
            baselineAvgSpeedMps: run.results.avgSpeedMps,
            baselinePeakSpeedMps: run.results.peakSpeedMps,
            baselinePowerEstimateW: run.results.powerEstimateW,
            baselineForceEstimateN: run.results.forceEstimateN,
            baselineVelocityProfileSummary: velocityProfile
        )
        
        baselineStore.saveBaseline(baseline)
        templateStore.markBaselineCaptured(for: template.id)
    }
}

struct PreRunView: View {
    let template: DrillTemplate
    let runMode: RunMode
    let plan: EnforcementPlan?
    let baseline: DrillBaseline?
    
    let onStart: () -> Void
    
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            VStack(spacing: Theme.Spacing.md) {
                if runMode == .baselineNoEnforcement {
                    Label("No Motor Enforcement", systemImage: "hand.raised.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text("Run naturally to capture your baseline")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Label("Motor Enforcement Active", systemImage: "bolt.fill")
                        .font(.headline)
                        .foregroundColor(.blue)
                    
                    if let plan = plan {
                        Text(plan.notes)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            
            if let baseline = baseline, runMode == .enforced {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Baseline Reference")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    HStack(spacing: Theme.Spacing.md) {
                        Text(String(format: "%.1fm", baseline.baselineDistanceMeters))
                        Text(String(format: "%.1fs", baseline.baselineTimeSeconds))
                        Text(String(format: "%.1f m/s", baseline.baselineAvgSpeedMps))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(Theme.CornerRadius.small)
            }
            
            Button {
                onStart()
            } label: {
                Label("Start Run", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Theme.orange)
                    .foregroundColor(.white)
                    .cornerRadius(Theme.CornerRadius.medium)
            }
        }
    }
}

struct RunningView: View {
    let currentDistance: Double
    let currentTime: Double
    let currentSpeed: Double
    let onStop: () -> Void
    
    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            // Live metrics
            VStack(spacing: Theme.Spacing.lg) {
                MetricCard(
                    label: "Distance",
                    value: String(format: "%.1f m", currentDistance),
                    icon: "ruler"
                )
                
                MetricCard(
                    label: "Time",
                    value: String(format: "%.1f s", currentTime),
                    icon: "clock"
                )
                
                MetricCard(
                    label: "Speed",
                    value: String(format: "%.1f m/s", currentSpeed),
                    icon: "speedometer"
                )
            }
            
            Button {
                onStop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(Theme.CornerRadius.medium)
            }
        }
    }
}

struct MetricCard: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(Theme.orange)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(Theme.CornerRadius.medium)
    }
}

struct RunCompleteView: View {
    let template: DrillTemplate
    let results: RunResults
    let baseline: DrillBaseline?
    let runMode: RunMode
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if runMode == .baselineNoEnforcement && template.probationStatus == .probationary {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    
                    Text("Baseline Captured")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Drill is now ready for workouts")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            
            VStack(spacing: Theme.Spacing.md) {
                Text("Results")
                    .font(.headline)
                
                DrillResultRow(label: "Distance", value: String(format: "%.1f m", results.distanceMeters))
                DrillResultRow(label: "Time", value: String(format: "%.1f s", results.durationSeconds))
                DrillResultRow(label: "Avg Speed", value: String(format: "%.1f m/s", results.avgSpeedMps))
                DrillResultRow(label: "Peak Speed", value: String(format: "%.1f m/s", results.peakSpeedMps))
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(Theme.CornerRadius.medium)
            
            if let baseline = baseline, runMode == .enforced {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("vs Baseline")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    let comparisons = EnforcementPlanGenerator.calculateComparisons(
                        run: DrillRun(templateId: template.id, runMode: .enforced, results: results),
                        baseline: baseline
                    )
                    if let speedPercent = comparisons.percentVsBaselineSpeed {
                    DrillResultRow(
                        label: "Speed",
                        value: String(format: "%.0f%%", speedPercent),
                        color: speedPercent >= 100 ? .green : .orange
                    )
                    if let timePercent = comparisons.percentVsBaselineTime {
                        DrillResultRow(
                            label: "Time",
                            value: String(format: "%.0f%%", timePercent),
                            color: timePercent >= 100 ? .green : .orange
                        )
                    }
                }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(Theme.CornerRadius.medium)
            }
            
            Button {
                onDismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Theme.orange)
                    .foregroundColor(.white)
                    .cornerRadius(Theme.CornerRadius.medium)
            }
        }
    }
}

struct DrillResultRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
    }
}
