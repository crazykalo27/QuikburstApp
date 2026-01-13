import SwiftUI
import Charts

// MARK: - Drill Analysis View (Reusable)

struct DrillAnalysisView: View {
    let sessionResult: SessionResult
    let template: DrillTemplate?
    
    init(sessionResult: SessionResult, template: DrillTemplate? = nil) {
        self.sessionResult = sessionResult
        self.template = template
    }
    
    // Get effective phases from template
    private var phases: [DrillPhase] {
        template?.effectivePhases ?? []
    }
    
    // Encoder constants (matching Arduino code)
    private let COUNTS_PER_REV: Double = 2400.0
    private let SPOOL_RADIUS_M: Double = 0.1016
    
    // Normalize timestamps to start from 0 for display and convert counts to distance
    private var chartData: [SensorSample] {
        guard !sessionResult.rawESP32Data.isEmpty else {
            return []
        }
        
        // Normalize timestamps relative to the first sample
        // Convert encoder counts to distance for display
        let firstTimestamp = sessionResult.rawESP32Data.first?.timestamp ?? Date()
        return sessionResult.rawESP32Data.map { sample in
            let distance = EncoderConversions.countsToDistance(sample.value)
            return SensorSample(
                timestamp: Date(timeIntervalSince1970: sample.timestamp.timeIntervalSince(firstTimestamp)),
                value: distance
            )
        }
    }
    
    // Analyze each phase independently
    private var phaseAnalyses: [PhaseAnalysis] {
        guard !sessionResult.rawESP32Data.isEmpty, !phases.isEmpty else {
            return []
        }
        
        var analyses: [PhaseAnalysis] = []
        let firstTimestamp = sessionResult.rawESP32Data.first?.timestamp ?? Date()
        var currentTimeOffset: TimeInterval = 0
        
        for (index, phase) in phases.enumerated() {
            // Get samples starting from current time offset
            let remainingSamples = sessionResult.rawESP32Data.filter { sample in
                let timeOffset = sample.timestamp.timeIntervalSince(firstTimestamp)
                return timeOffset >= currentTimeOffset
            }
            
            guard !remainingSamples.isEmpty else { break }
            
            // Determine phase end based on target
            var phaseSamples: [SensorSample] = []
            
            if let targetTime = phase.targetTimeSeconds {
                // Time-based phase: use target time
                let phaseEndTime = currentTimeOffset + targetTime
                phaseSamples = remainingSamples.filter { sample in
                    let timeOffset = sample.timestamp.timeIntervalSince(firstTimestamp)
                    return timeOffset <= phaseEndTime
                }
            } else if let targetDistance = phase.distanceMeters {
                // Distance-based phase: find when target distance was reached
                let initialCount = remainingSamples.first?.value ?? 0
                let initialDistance = EncoderConversions.countsToDistance(initialCount)
                let targetDistanceInCounts = (targetDistance / (2 * .pi * SPOOL_RADIUS_M)) * COUNTS_PER_REV
                let targetCount = initialCount + targetDistanceInCounts
                
                // Find first sample that reaches or exceeds target
                var foundEnd = false
                for sample in remainingSamples {
                    phaseSamples.append(sample)
                    if sample.value >= targetCount {
                        foundEnd = true
                        break
                    }
                }
                
                // If target not reached, use all remaining samples
                if !foundEnd {
                    phaseSamples = remainingSamples
                }
            } else {
                // No target specified: use all remaining samples (last phase)
                phaseSamples = remainingSamples
            }
            
            if !phaseSamples.isEmpty {
                if let metrics = EncoderConversions.analyzePhase(
                    samples: phaseSamples,
                    phaseType: phase.drillType
                ) {
                    analyses.append(PhaseAnalysis(
                        phaseIndex: index,
                        phase: phase,
                        metrics: metrics
                    ))
                    
                    // Update currentTimeOffset for next phase
                    if let lastSample = phaseSamples.last {
                        currentTimeOffset = lastSample.timestamp.timeIntervalSince(firstTimestamp)
                    }
                }
            } else {
                // No samples for this phase, break to avoid infinite loop
                break
            }
        }
        
        // If no phases were found or analysis failed, analyze entire session as single phase
        if analyses.isEmpty, !sessionResult.rawESP32Data.isEmpty {
            let allSamples = sessionResult.rawESP32Data
            let drillType = phases.first?.drillType ?? (template?.type ?? .speedDrill)
            if let metrics = EncoderConversions.analyzePhase(
                samples: allSamples,
                phaseType: drillType
            ) {
                let phase = phases.first ?? DrillPhase()
                analyses.append(PhaseAnalysis(
                    phaseIndex: 0,
                    phase: phase,
                    metrics: metrics
                ))
            }
        }
        
        return analyses
    }
    
    private var drillName: String {
        template?.name ?? "Drill Analysis"
    }
    
    private var isMultiPhase: Bool {
        phases.count > 1
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Header with drill info
                VStack(spacing: Theme.Spacing.md) {
                    // Drill name
                    Text(drillName)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    // Drill details
                    if let template = template {
                        VStack(spacing: Theme.Spacing.xs) {
                            HStack(spacing: Theme.Spacing.md) {
                                Text(template.type.rawValue)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if let time = template.targetTimeSeconds {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text("\(Int(time))s")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                if template.isResist {
                                    Text("• Resist")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                if template.isAssist {
                                    Text("• Assist")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if let forceType = template.forceType, forceType == .constant, let force = template.constantForceN {
                                Text("\(Int(force)) N")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // Session date/time
                    VStack(spacing: Theme.Spacing.xs) {
                        Text(sessionResult.date, style: .date)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        Text(sessionResult.date, style: .time)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, Theme.Spacing.lg)
                .padding(.horizontal, Theme.Spacing.lg)
                
                // Performance Graph
                if !sessionResult.rawESP32Data.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Performance Graph")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .padding(.horizontal, Theme.Spacing.lg)
                        
                        Chart(chartData) {
                            LineMark(
                                x: .value("Time", $0.timestamp.timeIntervalSince1970),
                                y: .value("Distance", $0.value)
                            )
                            .foregroundStyle(Theme.orange)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
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
                                    if let distanceValue = value.as(Double.self) {
                                        Text(String(format: "%.1fm", distanceValue))
                                            .font(.system(size: 10))
                                    }
                                }
                            }
                        }
                        .frame(height: 300)
                        .padding(Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                .fill(Color(.systemGray6))
                                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                        )
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                } else {
                    VStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text("No data available")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                            .fill(Color(.systemGray6))
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                
                // Phase-by-phase metrics
                if isMultiPhase && !phaseAnalyses.isEmpty {
                    ForEach(phaseAnalyses) { analysis in
                        PhaseMetricsView(analysis: analysis)
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                } else if let analysis = phaseAnalyses.first {
                    // Single phase or overall metrics
                    PhaseMetricsView(analysis: analysis)
                        .padding(.horizontal, Theme.Spacing.lg)
                } else {
                    // Fallback to stored metrics if analysis failed
                    VStack(spacing: Theme.Spacing.md) {
                        if let peak = sessionResult.derivedMetrics.peakForce {
                            AnalysisMetricRow(
                                icon: "arrow.up.circle.fill",
                                label: "Peak Force",
                                value: String(format: "%.2f N", peak),
                                color: Theme.orange
                            )
                        }
                        if let avg = sessionResult.derivedMetrics.averageForce {
                            AnalysisMetricRow(
                                icon: "chart.line.uptrend.xyaxis",
                                label: "Average Force",
                                value: String(format: "%.2f N", avg),
                                color: .blue
                            )
                        }
                        if let duration = sessionResult.derivedMetrics.duration {
                            AnalysisMetricRow(
                                icon: "clock.fill",
                                label: "Duration",
                                value: String(format: "%.1fs", duration),
                                color: .green
                            )
                        }
                    }
                    .padding(Theme.Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                            .fill(Color(.systemGray6))
                            .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct PhaseAnalysis: Identifiable {
    let id = UUID()
    let phaseIndex: Int
    let phase: DrillPhase
    let metrics: EncoderConversions.PhaseMetrics
}

struct PhaseMetricsView: View {
    let analysis: PhaseAnalysis
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Phase header
            if analysis.phaseIndex > 0 || analysis.phase.drillType == .forceDrill || analysis.phase.drillType == .speedDrill {
                Text("Phase \(analysis.phaseIndex + 1): \(analysis.phase.drillType.rawValue)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            } else {
                Text("Overall Metrics")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
            
            // Metrics
            VStack(spacing: Theme.Spacing.md) {
                // Peak Force
                AnalysisMetricRow(
                    icon: "arrow.up.circle.fill",
                    label: "Peak Force",
                    value: String(format: "%.1f N", analysis.metrics.peakForce),
                    color: Theme.orange
                )
                
                // Average Force
                AnalysisMetricRow(
                    icon: "chart.line.uptrend.xyaxis",
                    label: "Average Force",
                    value: String(format: "%.1f N", analysis.metrics.averageForce),
                    color: .blue
                )
                
                // Peak Speed
                AnalysisMetricRow(
                    icon: "speedometer",
                    label: "Peak Speed",
                    value: String(format: "%.2f m/s", analysis.metrics.peakSpeed),
                    color: .green
                )
                
                // Average Speed
                AnalysisMetricRow(
                    icon: "gauge",
                    label: "Average Speed",
                    value: String(format: "%.2f m/s", analysis.metrics.averageSpeed),
                    color: .purple
                )
                
                // Duration
                AnalysisMetricRow(
                    icon: "clock.fill",
                    label: "Duration",
                    value: String(format: "%.1fs", analysis.metrics.duration),
                    color: .secondary
                )
                
                // Distance (if applicable)
                if analysis.metrics.distance > 0 {
                    AnalysisMetricRow(
                        icon: "ruler",
                        label: "Distance",
                        value: String(format: "%.2f m", analysis.metrics.distance),
                        color: .secondary
                    )
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .fill(Color(.systemGray6))
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
    }
}

struct AnalysisMetricRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 32)
            
            Text(label)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.primary)
            
            Spacer()
            
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }
}
