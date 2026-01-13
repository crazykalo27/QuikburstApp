import SwiftUI

struct DrillDetailView: View {
    let drill: Drill
    @ObservedObject var drillStore: DrillStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var navigationCoordinator: AppNavigationCoordinator
    @State private var showingEditor = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // Header
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(drill.name)
                            .font(Theme.Typography.title)
                        
                        HStack(spacing: Theme.Spacing.sm) {
                            CategoryBadge(category: drill.category)
                            Text("\(drill.lengthSeconds)s")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    // Properties
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Properties")
                            .font(.headline)
                        
                        PropertyRow(label: "Category", value: drill.category.rawValue)
                        PropertyRow(label: "Length", value: "\(drill.lengthSeconds) seconds")
                        PropertyRow(label: "Resistive", value: drill.isResistive ? "Yes" : "No")
                        PropertyRow(label: "Assistive", value: drill.isAssistive ? "Yes" : "No")
                        PropertyRow(label: "Type", value: drill.isCustom ? "Custom" : "Built-in")
                    }
                    
                    Divider()
                    
                    // Actions
                    VStack(spacing: Theme.Spacing.md) {
                        Button {
                            HapticFeedback.buttonPress()
                            // Deep-link: Navigate to Train tab and start with this drill
                            navigationCoordinator.startDrillInTrain(drill, level: nil)
                            dismiss()
                        } label: {
                            Label("Start in Train", systemImage: "play.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.orange)
                                .foregroundColor(.white)
                                .cornerRadius(Theme.CornerRadius.medium)
                        }
                        .accessibilityLabel("Start in Train")
                        .accessibilityHint("Opens the Train tab and starts this drill")
                        
                        Button {
                            showingEditor = true
                        } label: {
                            Label("Edit Drill", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.systemGray5))
                                .foregroundColor(.primary)
                                .cornerRadius(Theme.CornerRadius.medium)
                        }
                        .accessibilityLabel("Edit Drill")
                    }
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle("Drill Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                DrillEditorView(drillStore: drillStore, editingDrill: drill)
            }
        }
    }
}

struct PropertyRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct WorkoutDetailView: View {
    let workout: Workout
    @ObservedObject var workoutStore: WorkoutStore
    @ObservedObject var templateStore: DrillTemplateStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var navigationCoordinator: AppNavigationCoordinator
    @State private var showingEditor = false
    @State private var showingDeleteAlert = false
    
    private var restUUID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
    
    private func isRestPeriod(item: WorkoutItem) -> Bool {
        return item.drillId == restUUID || (item.reps == 0 && templateStore.getTemplate(id: item.drillId) == nil)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header - Fixed at top
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(workout.name)
                        .font(Theme.Typography.title)
                    
                    Text("\(workout.items.count) item\(workout.items.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
                
                Divider()
                
                // Scrollable drills section - Center of screen
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Drills & Breaks")
                            .font(.headline)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.top, Theme.Spacing.sm)
                        
                        ForEach(workout.items) { item in
                            if isRestPeriod(item: item) {
                                RestPeriodSummaryRow(item: item)
                                    .padding(.horizontal, Theme.Spacing.md)
                            } else if let template = templateStore.getTemplate(id: item.drillId) {
                                WorkoutItemRow(item: item, template: template)
                                    .padding(.horizontal, Theme.Spacing.md)
                            }
                        }
                    }
                    .padding(.bottom, Theme.Spacing.md)
                }
                
                Divider()
                
                // Actions - Fixed at bottom
                VStack(spacing: Theme.Spacing.md) {
                    Button {
                        HapticFeedback.buttonPress()
                        // Deep-link: Navigate to Train tab and start with this workout
                        navigationCoordinator.startWorkoutInTrain(workout)
                        dismiss()
                    } label: {
                        Label("Start in Train", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.orange)
                            .foregroundColor(.white)
                            .cornerRadius(Theme.CornerRadius.medium)
                    }
                    .accessibilityLabel("Start in Train")
                    .accessibilityHint("Opens the Train tab and starts this workout")
                    
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Edit Workout", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray5))
                            .foregroundColor(.primary)
                            .cornerRadius(Theme.CornerRadius.medium)
                    }
                    .accessibilityLabel("Edit Workout")
                    
                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete Workout", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(Theme.CornerRadius.medium)
                    }
                    .accessibilityLabel("Delete Workout")
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle("Workout Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                WorkoutBuilderView(workoutStore: workoutStore, templateStore: templateStore, editingWorkout: workout)
            }
            .alert("Delete Workout", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    workoutStore.deleteWorkout(workout)
                    dismiss()
                }
            } message: {
                Text("Are you sure you want to delete \"\(workout.name)\"? This action cannot be undone.")
            }
        }
    }
}

struct WorkoutItemRow: View {
    let item: WorkoutItem
    let template: DrillTemplate
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(template.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack(spacing: Theme.Spacing.md) {
                    Text("\(item.reps) rep\(item.reps == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if item.restSeconds > 0 {
                        Text("\(item.restSeconds)s rest")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let level = item.level {
                        Text("Level \(level)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .background(Color(.systemGray6))
        .cornerRadius(Theme.CornerRadius.small)
    }
}

struct RestPeriodSummaryRow: View {
    let item: WorkoutItem
    
    var body: some View {
        HStack {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "timer")
                    .foregroundColor(Theme.orange)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Rest Period")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("\(item.restSeconds) seconds")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .background(Color(.systemGray6))
        .cornerRadius(Theme.CornerRadius.small)
    }
}

// Specialized WorkoutDetailView for use in TrainTabView
struct WorkoutDetailViewForTrain: View {
    let workout: Workout
    @ObservedObject var workoutStore: WorkoutStore
    @ObservedObject var templateStore: DrillTemplateStore
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var showingDeleteAlert = false
    
    private var restUUID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
    
    private func isRestPeriod(item: WorkoutItem) -> Bool {
        return item.drillId == restUUID || (item.reps == 0 && templateStore.getTemplate(id: item.drillId) == nil)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header - Fixed at top
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(workout.name)
                        .font(Theme.Typography.title)
                    
                    Text("\(workout.items.count) item\(workout.items.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
                
                Divider()
                
                // Scrollable drills section - Center of screen
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Drills & Breaks")
                            .font(.headline)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.top, Theme.Spacing.sm)
                        
                        ForEach(workout.items) { item in
                            if isRestPeriod(item: item) {
                                RestPeriodSummaryRow(item: item)
                                    .padding(.horizontal, Theme.Spacing.md)
                            } else if let template = templateStore.getTemplate(id: item.drillId) {
                                WorkoutItemRow(item: item, template: template)
                                    .padding(.horizontal, Theme.Spacing.md)
                            }
                        }
                    }
                    .padding(.bottom, Theme.Spacing.md)
                }
                
                Divider()
                
                // Actions - Fixed at bottom
                VStack(spacing: Theme.Spacing.md) {
                    Button {
                        HapticFeedback.buttonPress()
                        onStart()
                        dismiss()
                    } label: {
                        Label("Start Workout", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.orange)
                            .foregroundColor(.white)
                            .cornerRadius(Theme.CornerRadius.medium)
                    }
                    .accessibilityLabel("Start Workout")
                    .accessibilityHint("Starts this workout")
                    
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Edit Workout", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray5))
                            .foregroundColor(.primary)
                            .cornerRadius(Theme.CornerRadius.medium)
                    }
                    .accessibilityLabel("Edit Workout")
                    
                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete Workout", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(Theme.CornerRadius.medium)
                    }
                    .accessibilityLabel("Delete Workout")
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle("Workout Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                WorkoutBuilderView(workoutStore: workoutStore, templateStore: templateStore, editingWorkout: workout)
            }
            .alert("Delete Workout", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    workoutStore.deleteWorkout(workout)
                    dismiss()
                }
            } message: {
                Text("Are you sure you want to delete \"\(workout.name)\"? This action cannot be undone.")
            }
        }
    }
}
