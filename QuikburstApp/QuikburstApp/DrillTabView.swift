import SwiftUI

struct DrillTabView: View {
    @StateObject private var drillStore = DrillStore()
    @StateObject private var workoutStore = WorkoutStore()
    @EnvironmentObject var profileStore: ProfileStore
    @State private var selectedSegment: CatalogSegment = .drills
    @State private var searchText = ""
    @State private var showingFilters = false
    @State private var showingDrillEditor = false
    @State private var showingWorkoutBuilder = false
    @State private var selectedDrill: Drill?
    @State private var selectedWorkout: Workout?
    
    enum CatalogSegment {
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
                
                // Segmented Control
                HStack(spacing: 0) {
                    SegmentButton(
                        title: "Drills",
                        isSelected: selectedSegment == .drills
                    ) {
                        withAnimation {
                            selectedSegment = .drills
                        }
                    }
                    
                    SegmentButton(
                        title: "Workouts",
                        isSelected: selectedSegment == .workouts
                    ) {
                        withAnimation {
                            selectedSegment = .workouts
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                
                // Search Bar and Filter
                HStack(spacing: Theme.Spacing.sm) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Color(.systemGray6))
                    .cornerRadius(Theme.CornerRadius.small)
                    
                    Button {
                        showingFilters = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.title3)
                            .foregroundColor(Theme.orange)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.sm)
                
                // Content
                Group {
                    if selectedSegment == .drills {
                        DrillCatalogView(
                            drills: filteredDrills,
                            searchText: $searchText,
                            onDrillTap: { drill in
                                selectedDrill = drill
                            }
                        )
                    } else {
                        WorkoutCatalogView(
                            workouts: filteredWorkouts,
                            drillStore: drillStore,
                            onWorkoutTap: { workout in
                                selectedWorkout = workout
                            }
                        )
                    }
                }
            }
            .navigationTitle("Drill Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if selectedSegment == .drills {
                            showingDrillEditor = true
                        } else {
                            showingWorkoutBuilder = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(Theme.orange)
                    }
                }
            }
            .sheet(isPresented: $showingDrillEditor) {
                DrillEditorView(drillStore: drillStore)
            }
            .sheet(isPresented: $showingWorkoutBuilder) {
                WorkoutBuilderView(workoutStore: workoutStore, drillStore: drillStore)
            }
            .sheet(item: $selectedDrill) { drill in
                DrillDetailView(drill: drill, drillStore: drillStore)
            }
            .sheet(item: $selectedWorkout) { workout in
                WorkoutDetailView(workout: workout, workoutStore: workoutStore, drillStore: drillStore)
            }
            .sheet(isPresented: $showingFilters) {
                FilterSheetView(
                    selectedSegment: selectedSegment,
                    onApply: { _ in }
                )
            }
        }
        .environmentObject(drillStore)
        .environmentObject(workoutStore)
    }
    
    private var filteredDrills: [Drill] {
        var drills = drillStore.drills
        
        if !searchText.isEmpty {
            drills = drills.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        return drills.sorted { $0.name < $1.name }
    }
    
    private var filteredWorkouts: [Workout] {
        var workouts = workoutStore.workouts
        
        if !searchText.isEmpty {
            workouts = workouts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        return workouts.sorted { $0.name < $1.name }
    }
}

struct SegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundColor(isSelected ? Theme.orange : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                                .fill(Theme.orange.opacity(0.15))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

struct DrillCatalogView: View {
    let drills: [Drill]
    @Binding var searchText: String
    let onDrillTap: (Drill) -> Void
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(drills) { drill in
                    DrillRowView(drill: drill) {
                        onDrillTap(drill)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

struct DrillRowView: View {
    let drill: Drill
    let onTap: () -> Void
    
    var body: some View {
        Button(action: {
            HapticFeedback.cardTap()
            onTap()
        }) {
            HStack(spacing: Theme.Spacing.md) {
                // Category accent bar
                RoundedRectangle(cornerRadius: 3)
                    .fill(drill.category == .speed ? Color.blue.opacity(0.4) : Color.red.opacity(0.4))
                    .frame(width: 3)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                        Text(drill.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            if drill.isFavorite {
                                Image(systemName: "heart.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 12))
                            }
                            
                            if drill.isCustom {
                                Text("Custom")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Theme.orange.opacity(0.15))
                                    .foregroundColor(Theme.orange)
                                    .cornerRadius(5)
                            }
                        }
                    }
                    
                    HStack(spacing: Theme.Spacing.sm) {
                        CategoryBadge(category: drill.category)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text("\(drill.lengthSeconds)s")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                        }
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

struct CategoryBadge: View {
    let category: DrillCategory
    
    var body: some View {
        Text(category.rawValue)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(category == .speed ? Color.blue.opacity(0.2) : Color.red.opacity(0.2))
            .foregroundColor(category == .speed ? .blue : .red)
            .cornerRadius(4)
    }
}

struct WorkoutCatalogView: View {
    let workouts: [Workout]
    let drillStore: DrillStore
    let onWorkoutTap: (Workout) -> Void
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(workouts) { workout in
                    WorkoutRowView(workout: workout, drillStore: drillStore) {
                        onWorkoutTap(workout)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

struct WorkoutRowView: View {
    let workout: Workout
    let drillStore: DrillStore
    let onTap: () -> Void
    
    var body: some View {
        Button(action: {
            HapticFeedback.cardTap()
            onTap()
        }) {
            HStack(spacing: Theme.Spacing.md) {
                // Workout icon
                ZStack {
                    Circle()
                        .fill(Theme.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.orange)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                        Text(workout.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            if workout.isFavorite {
                                Image(systemName: "heart.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 12))
                            }
                            
                            if workout.isCustom {
                                Text("Custom")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Theme.orange.opacity(0.15))
                                    .foregroundColor(Theme.orange)
                                    .cornerRadius(5)
                            }
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        
                        Text("\(workout.items.count) drill\(workout.items.count == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
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

struct FilterSheetView: View {
    let selectedSegment: DrillTabView.CatalogSegment
    let onApply: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Filters") {
                    Text("Filter options will be implemented here")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply([:])
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    DrillTabView()
}
