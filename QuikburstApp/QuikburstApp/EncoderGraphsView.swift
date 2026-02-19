import SwiftUI
import Charts

// Live graphs view for during drill execution
struct LiveEncoderGraphsView: View {
    let encoderData: [EncoderData]
    
    // Convert encoder data to chart data with elapsed time in seconds - ALWAYS return data (flat line if empty)
    private var chartData: [(time: Double, position: Double, velocity: Double, rpm: Double, acceleration: Double)] {
        if encoderData.isEmpty {
            // Return flat line data
            let startTime = Date().addingTimeInterval(-10)
            return (0..<20).map { index in
                (time: Double(index) * 0.5, position: 0.0, velocity: 0.0, rpm: 0.0, acceleration: 0.0)
            }
        }
        guard let firstTimestamp = encoderData.first?.timestamp else {
            // Fallback flat line
            let startTime = Date().addingTimeInterval(-10)
            return (0..<20).map { index in
                (time: Double(index) * 0.5, position: 0.0, velocity: 0.0, rpm: 0.0, acceleration: 0.0)
            }
        }
        return encoderData.map { data in
            let elapsedSeconds = data.timestamp.timeIntervalSince(firstTimestamp)
            return (time: elapsedSeconds, position: abs(data.position), velocity: abs(data.velocity), rpm: abs(data.rpm), acceleration: data.acceleration)
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Live Data")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            ScrollView {
                VStack(spacing: 12) {
                // Position Graph
                VStack(alignment: .leading, spacing: 8) {
                    Text("Position")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Chart(chartData, id: \.time) {
                        LineMark(
                            x: .value("Time (s)", $0.time),
                            y: .value("Position (m)", $0.position)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(.green)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .chartYScale(domain: .automatic)
                    .frame(height: 150)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                // Velocity Graph
                VStack(alignment: .leading, spacing: 8) {
                    Text("Velocity")
                        .font(.headline)
                        .foregroundStyle(.blue)
                    Chart(chartData, id: \.time) {
                        LineMark(
                            x: .value("Time (s)", $0.time),
                            y: .value("Velocity (m/s)", $0.velocity)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(.blue)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .chartYScale(domain: .automatic)
                    .frame(height: 150)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                // RPM Graph
                VStack(alignment: .leading, spacing: 8) {
                    Text("RPM")
                        .font(.headline)
                        .foregroundStyle(.purple)
                    Chart(chartData, id: \.time) {
                        LineMark(
                            x: .value("Time (s)", $0.time),
                            y: .value("RPM", $0.rpm)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(.purple)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .chartYScale(domain: .automatic)
                    .frame(height: 150)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                // Acceleration Graph
                VStack(alignment: .leading, spacing: 8) {
                    Text("Acceleration")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Chart(chartData, id: \.time) {
                        LineMark(
                            x: .value("Time (s)", $0.time),
                            y: .value("Acceleration (m/s²)", $0.acceleration)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(.red)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .chartYScale(domain: .automatic)
                    .frame(height: 120)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal)
        }
        }
    }
}
