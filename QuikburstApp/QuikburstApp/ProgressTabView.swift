import SwiftUI
import Charts

struct ProgressTabView: View {
    @StateObject private var sessionResultStore = SessionResultStore()
    @StateObject private var drillStore = DrillStore()
    @StateObject private var workoutStore = WorkoutStore()
    @EnvironmentObject var profileStore: ProfileStore
    
    @State private var selectedFilter: FilterType = .all
    @State private var selectedDrillId: UUID?
    @State private var selectedWorkoutId: UUID?
    @State private var dateRange: DateRange = .all
    @State private var selectedResult: SessionResult?
    
    enum FilterType {
        case all
        case drill
        case workout
    }
    
    enum DateRange {
        case all
        case week
        case month
        case year
    }
    
    private var filteredResults: [SessionResult] {
        var results = sessionResultStore.getAllResults()
        
        switch selectedFilter {
        case .all:
            break
        case .drill:
            results = results.filter { $0.mode == .drill }
            if let drillId = selectedDrillId {
                results = results.filter { $0.drillId == drillId }
            }
        case .workout:
            results = results.filter { $0.mode == .workout }
            if let workoutId = selectedWorkoutId {
                results = results.filter { $0.workoutId == workoutId }
            }
        }
        
        switch dateRange {
        case .all:
            break
        case .week:
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            results = results.filter { $0.date >= weekAgo }
        case .month:
            let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
            results = results.filter { $0.date >= monthAgo }
        case .year:
            let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
            results = results.filter { $0.date >= yearAgo }
        }
        
        return results
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Profile Indicator
                HStack {
                    ProfileIndicator(profileStore: profileStore)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xs)
                
                // Filters
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        FilterChip(
                            title: "All",
                            isSelected: selectedFilter == .all
                        ) {
                            selectedFilter = .all
                        }
                        
                        FilterChip(
                            title: "Drills",
                            isSelected: selectedFilter == .drill
                        ) {
                            selectedFilter = .drill
                        }
                        
                        FilterChip(
                            title: "Workouts",
                            isSelected: selectedFilter == .workout
                        ) {
                            selectedFilter = .workout
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .background(Color(.systemGray6))
                
                if filteredResults.isEmpty {
                    EmptyProgressView()
                } else {
                    ScrollView {
                        VStack(spacing: Theme.Spacing.lg) {
                            // Chart section
                            if selectedFilter == .drill, let drillId = selectedDrillId {
                                DrillProgressChart(
                                    results: filteredResults,
                                    drill: drillStore.getDrill(id: drillId)
                                )
                            } else if !filteredResults.isEmpty {
                                OverallProgressChart(results: filteredResults)
                            }
                            
                            // History list
                            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                Text("History")
                                    .font(.headline)
                                    .padding(.horizontal, Theme.Spacing.md)
                                
                                ForEach(groupedResults.keys.sorted(by: >), id: \.self) { date in
                                    Section {
                                        ForEach(groupedResults[date] ?? []) { result in
                                            ProgressRowView(
                                                result: result,
                                                drill: result.drillId.flatMap { drillStore.getDrill(id: $0) },
                                                workout: result.workoutId.flatMap { workoutStore.getWorkout(id: $0) },
                                                sessionResultStore: sessionResultStore,
                                                onTap: {
                                                    selectedResult = result
                                                }
                                            )
                                        }
                                    } header: {
                                        Text(date, style: .date)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, Theme.Spacing.md)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, Theme.Spacing.md)
                    }
                }
            }
            .navigationTitle("Progress")
            .sheet(item: $selectedResult) { result in
                NavigationStack {
                    DrillAnalysisView(
                        sessionResult: result,
                        drill: result.drillId.flatMap { drillStore.getDrill(id: $0) }
                    )
                    .navigationTitle("Drill Analysis")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                selectedResult = nil
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Date Range", selection: $dateRange) {
                            Text("All Time").tag(DateRange.all)
                            Text("Last Week").tag(DateRange.week)
                            Text("Last Month").tag(DateRange.month)
                            Text("Last Year").tag(DateRange.year)
                        }
                        
                        if selectedFilter == .drill {
                            Picker("Drill", selection: $selectedDrillId) {
                                Text("All Drills").tag(nil as UUID?)
                                ForEach(drillStore.drills) { drill in
                                    Text(drill.name).tag(drill.id as UUID?)
                                }
                            }
                        }
                        
                        if selectedFilter == .workout {
                            Picker("Workout", selection: $selectedWorkoutId) {
                                Text("All Workouts").tag(nil as UUID?)
                                ForEach(workoutStore.workouts) { workout in
                                    Text(workout.name).tag(workout.id as UUID?)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }
    
    private var groupedResults: [Date: [SessionResult]] {
        Dictionary(grouping: filteredResults) { result in
            Calendar.current.startOfDay(for: result.date)
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(isSelected ? Theme.orange : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(Theme.CornerRadius.medium)
        }
    }
}

struct EmptyProgressView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Theme.orange.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(Theme.orange.opacity(0.6))
            }
            .padding(.top, Theme.Spacing.xxl)
            
            VStack(spacing: 8) {
                Text("No progress yet")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text("Complete your first workout to start tracking progress")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DrillProgressChart: View {
    let results: [SessionResult]
    let drill: Drill?
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(drill?.name ?? "Drill Progress")
                .font(.headline)
                .padding(.horizontal, Theme.Spacing.md)
            
            Chart {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    if let peak = result.derivedMetrics.peakForce {
                        LineMark(
                            x: .value("Session", index),
                            y: .value("Peak Force", peak)
                        )
                        .foregroundStyle(Theme.orange)
                    }
                }
            }
            .frame(height: 200)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(Theme.CornerRadius.medium)
            .padding(.horizontal, Theme.Spacing.md)
        }
    }
}

struct OverallProgressChart: View {
    let results: [SessionResult]
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Overall Progress")
                .font(.headline)
                .padding(.horizontal, Theme.Spacing.md)
            
            Chart {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    if let peak = result.derivedMetrics.peakForce {
                        LineMark(
                            x: .value("Session", index),
                            y: .value("Peak Force", peak)
                        )
                        .foregroundStyle(Theme.orange)
                    }
                }
            }
            .frame(height: 200)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(Theme.CornerRadius.medium)
            .padding(.horizontal, Theme.Spacing.md)
        }
    }
}

struct ProgressRowView: View {
    let result: SessionResult
    let drill: Drill?
    let workout: Workout?
    @ObservedObject var sessionResultStore: SessionResultStore
    let onTap: () -> Void
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(action: {
                HapticFeedback.cardTap()
                onTap()
            }) {
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(result.mode == .drill ? (drill?.name ?? "Drill") : (workout?.name ?? "Workout"))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                        
                        HStack(spacing: Theme.Spacing.md) {
                            Text(result.date, style: .time)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                            
                            if let level = result.levelUsed {
                                Text("Level \(level)")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.orange.opacity(0.15))
                                    .foregroundColor(Theme.orange)
                                    .cornerRadius(4)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if let peak = result.derivedMetrics.peakForce {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f", peak))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            Text("Peak")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(Theme.Spacing.md)
                .background(Color(.systemGray6))
                .cornerRadius(Theme.CornerRadius.medium)
            }
            .buttonStyle(.plain)
            
            Button(role: .destructive) {
                HapticFeedback.buttonPress()
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.red)
                    .frame(width: 36, height: 36)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .confirmationDialog(
            "Delete this session?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                sessionResultStore.deleteResult(result)
                HapticFeedback.buttonPress()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

#Preview {
    ProgressTabView()
}
