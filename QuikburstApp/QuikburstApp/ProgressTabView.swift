import SwiftUI
import Charts

struct ProgressTabView: View {
    @EnvironmentObject var sessionResultStore: SessionResultStore
    @EnvironmentObject var templateStore: DrillTemplateStore
    @EnvironmentObject var runStore: DrillRunStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var profileStore: ProfileStore
    
    @State private var selectedSection: ProgressSection = .history
    @State private var selectedTemplate: DrillTemplate?
    @State private var selectedWorkout: Workout?
    @State private var selectedResult: SessionResult?
    
    enum ProgressSection {
        case history
        case drills
        case workouts
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
                
                // Section buttons
                HStack(spacing: Theme.Spacing.sm) {
                    SectionButton(
                        title: "History",
                        isSelected: selectedSection == .history
                    ) {
                        selectedSection = .history
                    }
                    
                    SectionButton(
                        title: "Drills",
                        isSelected: selectedSection == .drills
                    ) {
                        selectedSection = .drills
                    }
                    
                    SectionButton(
                        title: "Workouts",
                        isSelected: selectedSection == .workouts
                    ) {
                        selectedSection = .workouts
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                
                // Content
                Group {
                    switch selectedSection {
                    case .history:
                        HistoryView(
                            sessionResultStore: sessionResultStore,
                            templateStore: templateStore,
                            workoutStore: workoutStore,
                            runStore: runStore,
                            onResultTap: { result in
                                selectedResult = result
                            }
                        )
                    case .drills:
                        DrillsProgressView(
                            templateStore: templateStore,
                            runStore: runStore,
                            onTemplateTap: { template in
                                selectedTemplate = template
                            }
                        )
                    case .workouts:
                        WorkoutsProgressView(
                            workoutStore: workoutStore,
                            sessionResultStore: sessionResultStore,
                            onWorkoutTap: { workout in
                                selectedWorkout = workout
                            }
                        )
                    }
                }
            }
            .drukNavigationTitle("Progress")
            .sheet(item: $selectedResult) { result in
                NavigationStack {
                    DrillAnalysisView(
                        sessionResult: result,
                        template: result.drillId.flatMap { templateStore.getTemplate(id: $0) }
                    )
                    .drukNavigationTitle("Session Analysis")
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
            .sheet(item: $selectedTemplate) { template in
                DrillProgressDetailView(
                    template: template,
                    templateStore: templateStore,
                    runStore: runStore
                )
            }
            .sheet(item: $selectedWorkout) { workout in
                WorkoutProgressDetailView(
                    workout: workout,
                    workoutStore: workoutStore,
                    sessionResultStore: sessionResultStore
                )
            }
        }
    }
}

struct SectionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.Typography.exo2Callout)
                .fontWeight(.semibold)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.sm)
                .background(isSelected ? Theme.orange : Color(.systemGray5))
                .cornerRadius(Theme.CornerRadius.medium)
        }
    }
}

struct HistoryEntry: Identifiable {
    enum Kind {
        case solo(SessionResult)
        case workout(sessionId: UUID, workoutName: String?, drills: [SessionResult])
    }
    
    let id: UUID
    let date: Date
    let kind: Kind
}

struct HistoryView: View {
    @ObservedObject var sessionResultStore: SessionResultStore
    @ObservedObject var templateStore: DrillTemplateStore
    @ObservedObject var workoutStore: WorkoutStore
    @ObservedObject var runStore: DrillRunStore
    let onResultTap: (SessionResult) -> Void
    
    @State private var entryToDelete: HistoryEntry?
    @State private var showingDeleteConfirmation = false
    
    private var entries: [HistoryEntry] {
        let drillResults = sessionResultStore.getDrillResults()
        let grouped = Dictionary(grouping: drillResults, by: { $0.workoutSessionId })
        
        var output: [HistoryEntry] = []
        
        for (sessionId, results) in grouped {
            if let sessionId = sessionId {
                let sorted = results.sorted { $0.date > $1.date }
                let workoutName = sorted.compactMap { $0.workoutNameSnapshot }.first
                    ?? sorted.first?.workoutId.flatMap { workoutStore.getWorkout(id: $0)?.name }
                let date = sorted.first?.date ?? Date()
                output.append(
                    HistoryEntry(
                        id: sessionId,
                        date: date,
                        kind: .workout(
                            sessionId: sessionId,
                            workoutName: workoutName,
                            drills: sorted
                        )
                    )
                )
            } else {
                let solos = results.map { result in
                    HistoryEntry(id: result.id, date: result.date, kind: .solo(result))
                }
                output.append(contentsOf: solos)
            }
        }
        
        return output.sorted { $0.date > $1.date }
    }
    
    var body: some View {
        ScrollView {
            if entries.isEmpty {
                EmptyProgressView()
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(entries) { entry in
                        switch entry.kind {
                        case .solo(let result):
                            DrillHistoryRowView(
                                result: result,
                                template: result.drillId.flatMap { templateStore.getTemplate(id: $0) },
                                contextWorkoutName: nil,
                                onTap: { onResultTap(result) },
                                onDelete: {
                                    entryToDelete = entry
                                    showingDeleteConfirmation = true
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    entryToDelete = entry
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        case .workout(let sessionId, let workoutName, let drills):
                            WorkoutHistoryGroupView(
                                workoutName: workoutName ?? "Workout",
                                date: entry.date,
                                drills: drills,
                                templateStore: templateStore,
                                onResultTap: onResultTap,
                                onDelete: {
                                    entryToDelete = entry
                                    showingDeleteConfirmation = true
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    entryToDelete = entry
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.md)
            }
        }
        .alert("Delete Session", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    deleteEntry(entry)
                }
                entryToDelete = nil
            }
        } message: {
            if let entry = entryToDelete {
                switch entry.kind {
                case .solo(let result):
                    if let template = result.drillId.flatMap({ templateStore.getTemplate(id: $0) }) {
                        Text("Are you sure you want to delete this \(template.name) session? This action cannot be undone.")
                    } else {
                        Text("Are you sure you want to delete this session? This action cannot be undone.")
                    }
                case .workout(_, let workoutName, let drills):
                    Text("Are you sure you want to delete this \(workoutName ?? "workout") session with \(drills.count) drill\(drills.count == 1 ? "" : "s")? This action cannot be undone.")
                }
            }
        }
    }
    
    private func deleteEntry(_ entry: HistoryEntry) {
        switch entry.kind {
        case .solo(let result):
            sessionResultStore.deleteResult(result)
            // Also delete the corresponding DrillRun
            runStore.deleteRuns(matching: result)
        case .workout(let sessionId, _, let drills):
            // Delete all SessionResults for this workout session
            sessionResultStore.deleteResults(forSessionId: sessionId)
            // Also delete all corresponding DrillRuns
            runStore.deleteRuns(matching: drills)
        }
    }
}

struct DrillHistoryRowView: View {
    let result: SessionResult
    let template: DrillTemplate?
    let contextWorkoutName: String?
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(action: {
                HapticFeedback.cardTap()
                onTap()
            }) {
                HStack(spacing: Theme.Spacing.md) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(Theme.orange.opacity(0.15))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "figure.run")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.orange)
                    }
                    
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(template?.name.uppercased() ?? "DRILL")
                            .font(Theme.Typography.drukDrillName)
                            .foregroundColor(.primary)
                        
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(result.date, style: .date)
                                .font(Theme.Typography.exo2Label)
                                .foregroundColor(.secondary)
                            
                            Text(result.date, style: .time)
                                .font(Theme.Typography.exo2Label)
                                .foregroundColor(.secondary)
                        }
                        
                        if let workoutName = contextWorkoutName {
                            Text("Workout: \(workoutName)")
                                .font(Theme.Typography.exo2Caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if let peak = result.derivedMetrics.peakForce {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f", peak))
                                .font(Theme.Typography.exo2MetricSmall)
                                .foregroundColor(.primary)
                            Text("Peak")
                                .font(Theme.Typography.exo2Caption2)
                                .fontWeight(.medium)
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
            
            Button(action: {
                HapticFeedback.cardTap()
                onDelete()
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 44, height: 44)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(Theme.CornerRadius.medium)
            }
            .buttonStyle(.plain)
        }
    }
}

struct WorkoutHistoryGroupView: View {
    let workoutName: String
    let date: Date
    let drills: [SessionResult]
    let templateStore: DrillTemplateStore
    let onResultTap: (SessionResult) -> Void
    let onDelete: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(workoutName.uppercased())
                        .font(Theme.Typography.drukWorkoutTitle)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(date, style: .date)
                            .font(Theme.Typography.exo2Label)
                            .foregroundColor(.secondary)
                        Text(date, style: .time)
                            .font(Theme.Typography.exo2Label)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Text("\(drills.count) drill\(drills.count == 1 ? "" : "s")")
                    .font(Theme.Typography.exo2Label)
                    .foregroundColor(.secondary)
                
                Button(action: {
                    HapticFeedback.cardTap()
                    onDelete()
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(Theme.CornerRadius.medium)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, Theme.Spacing.xs)
            
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(drills.sorted { $0.date > $1.date }) { result in
                    DrillHistoryRowView(
                        result: result,
                        template: result.drillId.flatMap { templateStore.getTemplate(id: $0) },
                        contextWorkoutName: workoutName,
                        onTap: { onResultTap(result) },
                        onDelete: { }
                    )
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Color(.systemGray6))
        .cornerRadius(Theme.CornerRadius.medium)
    }
}

struct DrillsProgressView: View {
    @ObservedObject var templateStore: DrillTemplateStore
    @ObservedObject var runStore: DrillRunStore
    let onTemplateTap: (DrillTemplate) -> Void
    
    private var completedTemplates: [DrillTemplate] {
        let allTemplates = templateStore.fetchTemplates()
        let templatesWithRuns = allTemplates.filter { template in
            !runStore.fetchRuns(for: template.id).isEmpty
        }
        return templatesWithRuns.sorted { $0.name < $1.name }
    }
    
    var body: some View {
        ScrollView {
            if completedTemplates.isEmpty {
                EmptyProgressView(message: "No drills completed yet")
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(completedTemplates) { template in
                        DrillProgressRowView(
                            template: template,
                            runStore: runStore,
                            onTap: {
                                onTemplateTap(template)
                            }
                        )
                    }
                }
                .padding(Theme.Spacing.md)
            }
        }
    }
}

struct DrillProgressRowView: View {
    let template: DrillTemplate
    @ObservedObject var runStore: DrillRunStore
    let onTap: () -> Void
    
    private var allRuns: [DrillRun] {
        runStore.fetchRuns(for: template.id)
    }
    
    private var mostRecentRun: DrillRun? {
        allRuns.first
    }
    
    private var allTimeStats: (avgSpeed: Double, peakSpeed: Double, avgTime: Double) {
        let enforcedRuns = allRuns.filter { $0.runMode == .enforced }
        guard !enforcedRuns.isEmpty else {
            return (0, 0, 0)
        }
        
        let avgSpeed = enforcedRuns.map { $0.results.avgSpeedMps }.reduce(0, +) / Double(enforcedRuns.count)
        let peakSpeed = enforcedRuns.map { $0.results.peakSpeedMps }.max() ?? 0
        let avgTime = enforcedRuns.map { $0.results.durationSeconds }.reduce(0, +) / Double(enforcedRuns.count)
        
        return (avgSpeed, peakSpeed, avgTime)
    }
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(action: {
                HapticFeedback.cardTap()
                onTap()
            }) {
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                            Text(template.name.uppercased())
                                .font(Theme.Typography.drukDrillName)
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            
                            Spacer()
                        }
                        
                        HStack(spacing: Theme.Spacing.sm) {
                            // Target summary
                            Text(template.type.rawValue)
                                .font(Theme.Typography.exo2Label)
                                .foregroundColor(.secondary)
                            
                            if let time = template.targetTimeSeconds {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text("\(Int(time))s")
                                    .font(Theme.Typography.exo2Label)
                                    .foregroundColor(.secondary)
                            }
                            
                            if let distance = template.distanceMeters {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1fm", distance))
                                    .font(Theme.Typography.exo2Label)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("• \(allRuns.count) run\(allRuns.count == 1 ? "" : "s")")
                                .font(Theme.Typography.exo2Label)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary.opacity(0.6))
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                        .fill(Color(.systemGray6))
                        .shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

struct WorkoutsProgressView: View {
    @ObservedObject var workoutStore: WorkoutStore
    @ObservedObject var sessionResultStore: SessionResultStore
    let onWorkoutTap: (Workout) -> Void
    
    private var completedWorkouts: [Workout] {
        let allWorkouts = workoutStore.workouts
        let workoutsWithResults = allWorkouts.filter { workout in
            !sessionResultStore.getResults(forWorkoutId: workout.id).isEmpty
        }
        return workoutsWithResults.sorted { $0.name < $1.name }
    }
    
    var body: some View {
        ScrollView {
            if completedWorkouts.isEmpty {
                EmptyProgressView(message: "No workouts completed yet")
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(completedWorkouts) { workout in
                        WorkoutProgressRowView(
                            workout: workout,
                            sessionResultStore: sessionResultStore,
                            onTap: {
                                onWorkoutTap(workout)
                            }
                        )
                    }
                }
                .padding(Theme.Spacing.md)
            }
        }
    }
}

struct WorkoutProgressRowView: View {
    let workout: Workout
    @ObservedObject var sessionResultStore: SessionResultStore
    let onTap: () -> Void
    
    private var sessionCompletions: [(id: UUID, result: SessionResult)] {
        let grouped = Dictionary(grouping: sessionResultStore.getResults(forWorkoutId: workout.id)) { $0.workoutSessionId ?? $0.id }
        let mapped = grouped.compactMap { (_, results) -> (id: UUID, result: SessionResult)? in
            guard let latest = results.sorted(by: { $0.date > $1.date }).first else { return nil }
            let sessionId = latest.workoutSessionId ?? latest.id
            return (id: sessionId, result: latest)
        }
        return mapped.sorted(by: { $0.result.date > $1.result.date })
    }
    
    private var mostRecentResult: SessionResult? {
        sessionCompletions.first?.result
    }
    
    var body: some View {
        Button(action: {
            HapticFeedback.cardTap()
            onTap()
        }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(workout.name.uppercased())
                        .font(Theme.Typography.drukWorkoutTitle)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                
                HStack(spacing: Theme.Spacing.md) {
                    Text("\(workout.items.count) drill\(workout.items.count == 1 ? "" : "s")")
                        .font(Theme.Typography.exo2Label)
                        .foregroundColor(.secondary)
                    
                    Text("• \(sessionCompletions.count) completion\(sessionCompletions.count == 1 ? "" : "s")")
                        .font(Theme.Typography.exo2Label)
                        .foregroundColor(.secondary)
                }
                
                if let recent = mostRecentResult {
                    Text("Last completed: \(recent.date, style: .date)")
                        .font(Theme.Typography.exo2Label)
                        .foregroundColor(.secondary)
                }
            }
            .padding(Theme.Spacing.md)
            .background(Color(.systemGray6))
            .cornerRadius(Theme.CornerRadius.medium)
        }
        .buttonStyle(.plain)
    }
}

struct EmptyProgressView: View {
    var message: String = "No progress yet"
    
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
                Text(message.uppercased())
                    .font(Theme.Typography.drukDrillName)
                    .foregroundColor(.primary)
                
                Text("Complete your first session to start tracking progress")
                    .font(Theme.Typography.exo2Subheadline)
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
