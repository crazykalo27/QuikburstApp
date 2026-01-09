import SwiftUI
import Combine

struct StatisticsView: View {
    @EnvironmentObject private var runStore: RunStore
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var selectedUserId: UUID? // nil means "All Users"

    private var filteredRuns: [RunRecord] {
        if let selectedUserId = selectedUserId {
            return runStore.runs.filter { $0.userId == selectedUserId }
        }
        return runStore.runs
    }

    private var bestPeak: Double { filteredRuns.map(\.peakValue).max() ?? 0 }
    private var bestAverage: Double { filteredRuns.map(\.averageValue).max() ?? 0 }
    private var avgOfAverages: Double {
        guard !filteredRuns.isEmpty else { return 0 }
        return filteredRuns.map(\.averageValue).reduce(0, +) / Double(filteredRuns.count)
    }
    private var totalDuration: TimeInterval { filteredRuns.map(\.duration).reduce(0, +) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // User selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Filter by User")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Menu {
                        Button {
                            selectedUserId = nil
                        } label: {
                            HStack {
                                Text("All Users")
                                if selectedUserId == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        
                        Divider()
                        
                        ForEach(profileStore.users) { user in
                            Button {
                                selectedUserId = user.id
                            } label: {
                                HStack {
                                    Text(user.name)
                                    if selectedUserId == user.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(selectedUserName)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                
                // All-Time Bests section
                VStack(alignment: .leading, spacing: 12) {
                    Text("All-Time Bests")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 12) {
                        StatTile(title: "Peak", value: bestPeak, format: "%.2f")
                        StatTile(title: "Best Avg", value: bestAverage, format: "%.2f")
                    }
                    
                    StatTile(title: "Total Time", value: totalDuration/60, format: "%.0f min")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Averages section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Averages")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 12) {
                        StatTile(title: "Avg of Avgs", value: avgOfAverages, format: "%.2f")
                        StatTile(title: "Sessions", value: Double(filteredRuns.count), format: "%.0f")
                    }
                }
                .padding(.horizontal, 16)

                // History section
                VStack(alignment: .leading, spacing: 12) {
                    Text("History")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    
                    if filteredRuns.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text("No sessions yet")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text(selectedUserId == nil 
                                 ? "Start a live session to see statistics here"
                                 : "No sessions recorded for this user")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        List {
                            ForEach(filteredRuns) { run in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(run.date, style: .date)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Spacer()
                                        if let userId = run.userId,
                                           let userName = profileStore.users.first(where: { $0.id == userId })?.name {
                                            Text(userName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    HStack(spacing: 16) {
                                        Label(String(format: "Avg: %.2f", run.averageValue), systemImage: "chart.line.uptrend.xyaxis")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Label(String(format: "Peak: %.2f", run.peakValue), systemImage: "arrow.up.circle")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.insetGrouped)
                        .frame(height: min(400, CGFloat(filteredRuns.count) * 70))
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    // TODO: Export statistics
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            // Initialize selected user to "All Users" if not set
            if selectedUserId == nil && profileStore.selectedUserId != nil {
                // Optionally default to selected user, or keep as "All Users"
            }
        }
    }
    
    private var selectedUserName: String {
        if let selectedUserId = selectedUserId,
           let user = profileStore.users.first(where: { $0.id == selectedUserId }) {
            return user.name
        }
        return "All Users"
    }
}

private struct StatTile: View {
    let title: String
    let value: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: format, value))
                .font(.title3.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    StatisticsView()
        .environmentObject(RunStore())
}
