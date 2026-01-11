import SwiftUI
import Charts

// MARK: - Drill Analysis View (Reusable)

struct DrillAnalysisView: View {
    let sessionResult: SessionResult
    let drill: Drill?
    
    // Normalize timestamps to start from 0 for display
    private var chartData: [SensorSample] {
        guard !sessionResult.rawESP32Data.isEmpty else {
            return []
        }
        
        // Normalize timestamps relative to the first sample
        let firstTimestamp = sessionResult.rawESP32Data.first?.timestamp ?? Date()
        return sessionResult.rawESP32Data.map { sample in
            SensorSample(
                timestamp: Date(timeIntervalSince1970: sample.timestamp.timeIntervalSince(firstTimestamp)),
                value: sample.value
            )
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Header
                VStack(spacing: Theme.Spacing.sm) {
                    if let drill = drill {
                        Text(drill.name)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    } else {
                        Text("Drill Analysis")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    
                    Text(sessionResult.date, style: .date)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    Text(sessionResult.date, style: .time)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .padding(.top, Theme.Spacing.lg)
                
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
                                y: .value("Value", $0.value)
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
                            AxisMarks(values: .automatic(desiredCount: 5))
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
                
                // Metrics
                VStack(spacing: Theme.Spacing.md) {
                    if let peak = sessionResult.derivedMetrics.peakForce {
                        AnalysisMetricRow(
                            icon: "arrow.up.circle.fill",
                            label: "Peak Force",
                            value: String(format: "%.2f", peak),
                            color: Theme.orange
                        )
                    }
                    if let avg = sessionResult.derivedMetrics.averageForce {
                        AnalysisMetricRow(
                            icon: "chart.line.uptrend.xyaxis",
                            label: "Average Force",
                            value: String(format: "%.2f", avg),
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
                    
                    if let level = sessionResult.levelUsed {
                        AnalysisMetricRow(
                            icon: "gauge",
                            label: "Level",
                            value: "\(level)",
                            color: .purple
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
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Color(.systemGroupedBackground))
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
