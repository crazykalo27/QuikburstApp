import SwiftUI

struct DrillDetailView: View {
    let drill: Drill
    @ObservedObject var drillStore: DrillStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var showingTrain = false
    
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
                            showingTrain = true
                        } label: {
                            Label("Start in Train", systemImage: "play.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.orange)
                                .foregroundColor(.white)
                                .cornerRadius(Theme.CornerRadius.medium)
                        }
                        
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
            .fullScreenCover(isPresented: $showingTrain) {
                // Will navigate to Train tab with this drill selected
                Text("Train view will be implemented")
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
    @ObservedObject var drillStore: DrillStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var showingTrain = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // Header
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(workout.name)
                            .font(Theme.Typography.title)
                        
                        Text("\(workout.items.count) drill\(workout.items.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Workout Items
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Drills")
                            .font(.headline)
                        
                        ForEach(workout.items) { item in
                            if let drill = drillStore.getDrill(id: item.drillId) {
                                WorkoutItemRow(item: item, drill: drill)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Actions
                    VStack(spacing: Theme.Spacing.md) {
                        Button {
                            showingTrain = true
                        } label: {
                            Label("Start in Train", systemImage: "play.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.orange)
                                .foregroundColor(.white)
                                .cornerRadius(Theme.CornerRadius.medium)
                        }
                        
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
                    }
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
                WorkoutBuilderView(workoutStore: workoutStore, drillStore: drillStore, editingWorkout: workout)
            }
            .fullScreenCover(isPresented: $showingTrain) {
                // Will navigate to Train tab with this workout selected
                Text("Train view will be implemented")
            }
        }
    }
}

struct WorkoutItemRow: View {
    let item: WorkoutItem
    let drill: Drill
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(drill.name)
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
