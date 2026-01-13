import SwiftUI
import Charts

struct DrillProgressDetailView: View {
    let template: DrillTemplate
    @ObservedObject var templateStore: DrillTemplateStore
    @ObservedObject var runStore: DrillRunStore
    @Environment(\.dismiss) private var dismiss
    
    private var allRuns: [DrillRun] {
        runStore.fetchRuns(for: template.id)
            .sorted { $0.timestamp > $1.timestamp }
    }
    
    private var enforcedRuns: [DrillRun] {
        allRuns.filter { $0.runMode == .enforced }
    }
    
    private var mostRecentRun: DrillRun? {
        enforcedRuns.first
    }
    
    private var baselineRun: DrillRun? {
        allRuns.first { $0.runMode == .baselineNoEnforcement }
    }
    
    private var allTimeStats: DrillAllTimeStats {
        guard !enforcedRuns.isEmpty else {
            return DrillAllTimeStats()
        }
        
        let speeds = enforcedRuns.map { $0.results.avgSpeedMps }
        let peakSpeeds = enforcedRuns.map { $0.results.peakSpeedMps }
        let times = enforcedRuns.map { $0.results.durationSeconds }
        let distances = enforcedRuns.map { $0.results.distanceMeters }
        
        return DrillAllTimeStats(
            totalRuns: enforcedRuns.count,
            avgSpeed: speeds.reduce(0, +) / Double(speeds.count),
            peakSpeed: peakSpeeds.max() ?? 0,
            bestTime: times.min() ?? 0,
            avgTime: times.reduce(0, +) / Double(times.count),
            avgDistance: distances.reduce(0, +) / Double(distances.count),
            bestDistance: distances.max() ?? 0
        )
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    // Header
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(template.name.uppercased())
                            .font(Theme.Typography.drukTitle)
                        
                        HStack(spacing: Theme.Spacing.md) {
                            Text(template.type.rawValue)
                                .font(Theme.Typography.exo2Subheadline)
                                .foregroundColor(.secondary)
                            
                            if let time = template.targetTimeSeconds {
                                Text("• \(Int(time))s")
                                    .font(Theme.Typography.exo2Subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("• \(allRuns.count) run\(allRuns.count == 1 ? "" : "s")")
                                .font(Theme.Typography.exo2Subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    
                    Divider()
                    
                    // Most Recent Torque Curve
                    if let torqueCurve = template.torqueCurve, !torqueCurve.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("Torque Curve")
                                .font(.headline)
                                .padding(.horizontal, Theme.Spacing.md)
                            
                            Chart {
                                ForEach(Array(torqueCurve.enumerated()), id: \.offset) { index, point in
                                    LineMark(
                                        x: .value("Time", point.timeNormalized * (template.targetTimeSeconds ?? 10.0)),
                                        y: .value("Force", point.forceN)
                                    )
                                    .foregroundStyle(Theme.orange)
                                }
                            }
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                    AxisGridLine()
                                    AxisValueLabel {
                                        if let timeValue = value.as(Double.self) {
                                            Text(String(format: "%.1fs", timeValue))
                                                .font(.system(size: 10))
                                        }
                                    }
                                }
                            }
                            .chartYAxis {
                                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                                    AxisGridLine()
                                    AxisValueLabel {
                                        if let forceValue = value.as(Double.self) {
                                            Text(String(format: "%.0fN", forceValue))
                                                .font(.system(size: 10))
                                        }
                                    }
                                }
                            }
                            .frame(height: 250)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(Theme.CornerRadius.medium)
                            .padding(.horizontal, Theme.Spacing.md)
                        }
                    }
                    
                    // Most Recent Stats
                    if let recent = mostRecentRun {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("Most Recent Run")
                                .font(.headline)
                                .padding(.horizontal, Theme.Spacing.md)
                            
                            VStack(spacing: Theme.Spacing.sm) {
                                StatRow(label: "Time", value: String(format: "%.1f s", recent.results.durationSeconds))
                                StatRow(label: "Avg Speed", value: String(format: "%.1f m/s", recent.results.avgSpeedMps))
                                StatRow(label: "Peak Speed", value: String(format: "%.1f m/s", recent.results.peakSpeedMps))
                                StatRow(label: "Distance", value: String(format: "%.1f m", recent.results.distanceMeters))
                                
                                if let comparisons = recent.derivedComparisons,
                                   let speedPercent = comparisons.percentVsBaselineSpeed,
                                   let baseline = baselineRun {
                                    Divider()
                                    
                                    Text("vs Baseline")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    
                                    StatRow(
                                        label: "Speed",
                                        value: String(format: "%.0f%%", speedPercent),
                                        color: speedPercent >= 100 ? .green : .orange
                                    )
                                    
                                    if let timePercent = comparisons.percentVsBaselineTime {
                                        StatRow(
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
                            .padding(.horizontal, Theme.Spacing.md)
                        }
                    }
                    
                    // All-Time Stats
                    if allTimeStats.totalRuns > 0 {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("All-Time Stats")
                                .font(.headline)
                                .padding(.horizontal, Theme.Spacing.md)
                            
                            VStack(spacing: Theme.Spacing.sm) {
                                StatRow(label: "Total Runs", value: "\(allTimeStats.totalRuns)")
                                StatRow(label: "Best Time", value: String(format: "%.1f s", allTimeStats.bestTime), color: .green)
                                StatRow(label: "Avg Time", value: String(format: "%.1f s", allTimeStats.avgTime))
                                StatRow(label: "Best Speed", value: String(format: "%.1f m/s", allTimeStats.peakSpeed), color: .green)
                                StatRow(label: "Avg Speed", value: String(format: "%.1f m/s", allTimeStats.avgSpeed))
                                StatRow(label: "Best Distance", value: String(format: "%.1f m", allTimeStats.bestDistance), color: .green)
                                StatRow(label: "Avg Distance", value: String(format: "%.1f m", allTimeStats.avgDistance))
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(Theme.CornerRadius.medium)
                            .padding(.horizontal, Theme.Spacing.md)
                        }
                    }
                    
                    // History
                    if !allRuns.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("History")
                                .font(.headline)
                                .padding(.horizontal, Theme.Spacing.md)
                            
                            VStack(spacing: Theme.Spacing.sm) {
                                ForEach(allRuns) { run in
                                    RunHistoryRow(run: run, baseline: baselineRun)
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.md)
            }
            .drukNavigationTitle("Drill Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DrillAllTimeStats {
    var totalRuns: Int = 0
    var avgSpeed: Double = 0
    var peakSpeed: Double = 0
    var bestTime: Double = 0
    var avgTime: Double = 0
    var avgDistance: Double = 0
    var bestDistance: Double = 0
}

struct StatRow: View {
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

struct RunHistoryRow: View {
    let run: DrillRun
    let baseline: DrillRun?
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    if run.runMode == .baselineNoEnforcement {
                        Label("Baseline", systemImage: "flag.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                    } else {
                        Text(run.timestamp, style: .date)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    Spacer()
                    
                    if let comparisons = run.derivedComparisons,
                       let speedPercent = comparisons.percentVsBaselineSpeed,
                       run.runMode == .enforced {
                        Text(String(format: "%.0f%%", speedPercent))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(speedPercent >= 100 ? .green : .orange)
                    }
                }
                
                HStack(spacing: Theme.Spacing.md) {
                    Text(String(format: "%.1fs", run.results.durationSeconds))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(String(format: "%.1f m/s", run.results.avgSpeedMps))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(Theme.Spacing.sm)
        .background(run.runMode == .baselineNoEnforcement ? Color.orange.opacity(0.1) : Color(.systemGray6))
        .cornerRadius(Theme.CornerRadius.small)
    }
}

struct WorkoutProgressDetailView: View {
    let workout: Workout
    @ObservedObject var workoutStore: WorkoutStore
    @ObservedObject var sessionResultStore: SessionResultStore
    @Environment(\.dismiss) private var dismiss
    
    private var sessionCompletions: [(id: UUID, result: SessionResult)] {
        let grouped = Dictionary(grouping: sessionResultStore.getResults(forWorkoutId: workout.id)) { $0.workoutSessionId ?? $0.id }
        let mapped = grouped.compactMap { (_, results) -> (id: UUID, result: SessionResult)? in
            guard let latest = results.sorted(by: { $0.date > $1.date }).first else { return nil }
            let sessionId = latest.workoutSessionId ?? latest.id
            return (id: sessionId, result: latest)
        }
        return mapped.sorted(by: { $0.result.date > $1.result.date })
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    // Header
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(workout.name)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        
                        Text("\(sessionCompletions.count) completion\(sessionCompletions.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    
                    Divider()
                    
                    // History
                    if !sessionCompletions.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("History")
                                .font(.headline)
                                .padding(.horizontal, Theme.Spacing.md)
                            
                            VStack(spacing: Theme.Spacing.sm) {
                                ForEach(sessionCompletions, id: \.id) { completion in
                                    WorkoutHistoryRow(result: completion.result)
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.md)
            }
            .drukNavigationTitle("Workout Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct WorkoutHistoryRow: View {
    let result: SessionResult
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(result.date, style: .date)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(result.date, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let peak = result.derivedMetrics.peakForce {
                Text(String(format: "%.1f", peak))
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Color(.systemGray6))
        .cornerRadius(Theme.CornerRadius.small)
    }
}
