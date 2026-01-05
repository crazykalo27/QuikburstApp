import SwiftUI
import Combine

struct StatisticsView: View {
    @EnvironmentObject private var runStore: RunStore

    private var bestPeak: Double { runStore.runs.map(\.peakValue).max() ?? 0 }
    private var bestAverage: Double { runStore.runs.map(\.averageValue).max() ?? 0 }
    private var avgOfAverages: Double {
        guard !runStore.runs.isEmpty else { return 0 }
        return runStore.runs.map(\.averageValue).reduce(0, +) / Double(runStore.runs.count)
    }
    private var totalDuration: TimeInterval { runStore.runs.map(\.duration).reduce(0, +) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("All-Time Bests") {
                        HStack {
                            StatTile(title: "Peak", value: bestPeak, format: "%.2f")
                            StatTile(title: "Best Avg", value: bestAverage, format: "%.2f")
                            StatTile(title: "Total Time", value: totalDuration/60, format: "%.0f min")
                        }
                    }

                    GroupBox("Averages") {
                        HStack {
                            StatTile(title: "Avg of Avgs", value: avgOfAverages, format: "%.2f")
                            StatTile(title: "Sessions", value: Double(runStore.runs.count), format: "%.0f")
                        }
                    }

                    GroupBox("History") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(runStore.runs) { run in
                                HStack {
                                    Text(run.date, style: .date)
                                    Spacer()
                                    Text(String(format: "avg %.2f", run.averageValue))
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "peak %.2f", run.peakValue))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Statistics")
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: format, value))
                .font(.title2.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    StatisticsView()
        .environmentObject(RunStore())
}
