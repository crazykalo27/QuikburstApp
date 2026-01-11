import SwiftUI

struct WorkoutBuilderView: View {
    @ObservedObject var workoutStore: WorkoutStore
    @ObservedObject var drillStore: DrillStore
    @Environment(\.dismiss) private var dismiss
    
    var editingWorkout: Workout?
    
    @State private var name: String = ""
    @State private var items: [WorkoutItem] = []
    @State private var showingDrillPicker = false
    
    private var isNewWorkout: Bool {
        editingWorkout == nil
    }
    
    init(workoutStore: WorkoutStore, drillStore: DrillStore, editingWorkout: Workout? = nil) {
        self.workoutStore = workoutStore
        self.drillStore = drillStore
        self.editingWorkout = editingWorkout
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Workout Information") {
                    TextField("Workout Name", text: $name)
                }
                
                Section {
                    ForEach(items) { item in
                        if isRestPeriod(item: item) {
                            RestPeriodRow(
                                item: item,
                                onUpdate: { updatedItem in
                                    if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                                        items[index] = updatedItem
                                    }
                                },
                                onDelete: {
                                    items.removeAll { $0.id == item.id }
                                }
                            )
                        } else if drillStore.getDrill(id: item.drillId) != nil {
                            WorkoutItemEditorRow(
                                item: item,
                                drillStore: drillStore,
                                onUpdate: { updatedItem in
                                    if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                                        items[index] = updatedItem
                                    }
                                },
                                onDelete: {
                                    items.removeAll { $0.id == item.id }
                                }
                            )
                        } else {
                            // Show placeholder for missing drill
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Drill not found")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.red)
                                    Text("Drill ID: \(item.drillId.uuidString)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    items.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .onMove { from, to in
                        items.move(fromOffsets: from, toOffset: to)
                    }
                    
                    VStack(spacing: Theme.Spacing.sm) {
                        Button {
                            showingDrillPicker = true
                        } label: {
                            Label("Add Drill", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        
                        Button {
                            // Insert a rest period item using a special UUID
                            let restUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                            let restItem = WorkoutItem(
                                drillId: restUUID, // Special UUID to indicate rest period
                                reps: 0,
                                restSeconds: 30, // Default 30 seconds
                                level: nil
                            )
                            items.append(restItem)
                        } label: {
                            Label("Add Rest", systemImage: "timer")
                                .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text("Drills")
                } footer: {
                    if items.isEmpty {
                        Text("Add at least one drill to create a workout")
                    }
                }
            }
            .navigationTitle(isNewWorkout ? "New Workout" : "Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveWorkout()
                    }
                    .disabled(name.isEmpty || items.isEmpty)
                }
            }
            .sheet(isPresented: $showingDrillPicker) {
                DrillPickerView(drillStore: drillStore) { drill in
                    let newItem = WorkoutItem(
                        drillId: drill.id,
                        reps: 1,
                        restSeconds: 0
                    )
                    items.append(newItem)
                }
            }
            .onAppear {
                if let workout = editingWorkout {
                    loadWorkout(workout)
                }
            }
        }
    }
    
    private func loadWorkout(_ workout: Workout) {
        name = workout.name
        items = workout.items
    }
    
    private func saveWorkout() {
        if let workout = editingWorkout {
            var updated = workout
            updated.name = name
            updated.items = items
            updated.updatedAt = Date()
            workoutStore.updateWorkout(updated)
        } else {
            let newWorkout = Workout(
                name: name,
                items: items,
                isCustom: true
            )
            workoutStore.addWorkout(newWorkout)
        }
        dismiss()
    }
    
    private func isRestPeriod(item: WorkoutItem) -> Bool {
        // Check if this is a rest period (special UUID or reps == 0 with no drill)
        let restUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return item.drillId == restUUID || (item.reps == 0 && drillStore.getDrill(id: item.drillId) == nil)
    }
}

struct WorkoutItemEditorRow: View {
    let item: WorkoutItem
    @ObservedObject var drillStore: DrillStore
    let onUpdate: (WorkoutItem) -> Void
    let onDelete: () -> Void
    
    @State private var reps: Int
    @State private var restSeconds: Int
    @State private var level: Int?
    @State private var showingEditor = false
    
    private var drill: Drill? {
        drillStore.getDrill(id: item.drillId)
    }
    
    init(item: WorkoutItem, drillStore: DrillStore, onUpdate: @escaping (WorkoutItem) -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self.drillStore = drillStore
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _reps = State(initialValue: item.reps)
        _restSeconds = State(initialValue: item.restSeconds)
        _level = State(initialValue: item.level)
    }
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(drill?.name ?? "Drill not found")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack(spacing: Theme.Spacing.md) {
                    Text("\(reps) rep\(reps == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if restSeconds > 0 {
                        Text("\(restSeconds)s rest after")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: Theme.Spacing.xs) {
                Button {
                    showingEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(Theme.orange)
                }
                .buttonStyle(.plain)
                
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingEditor) {
            WorkoutItemEditorSheet(
                item: item,
                reps: $reps,
                restSeconds: $restSeconds,
                level: $level,
                onSave: {
                    var updated = item
                    updated.reps = reps
                    updated.restSeconds = restSeconds
                    updated.level = level
                    onUpdate(updated)
                }
            )
        }
    }
}

struct WorkoutItemEditorSheet: View {
    let item: WorkoutItem
    @Binding var reps: Int
    @Binding var restSeconds: Int
    @Binding var level: Int?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Repetitions") {
                    Stepper("Reps: \(reps)", value: $reps, in: 1...100)
                }
                
                Section("Rest Between Drills") {
                    Stepper("Rest: \(restSeconds) seconds", value: $restSeconds, in: 0...300)
                    Text("Rest period after completing this drill, before moving to the next drill in the workout.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Level (Optional)") {
                    Stepper(value: Binding(
                        get: { level ?? 1 },
                        set: { level = $0 }
                    ), in: 1...5) {
                        Text("Level: \(level ?? 1)")
                    }
                    
                    Button(role: .destructive) {
                        level = nil
                    } label: {
                        Text("Remove Level")
                    }
                    .disabled(level == nil)
                }
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct RestPeriodRow: View {
    let item: WorkoutItem
    let onUpdate: (WorkoutItem) -> Void
    let onDelete: () -> Void
    
    @State private var restSeconds: Int
    @State private var showingEditor = false
    
    init(item: WorkoutItem, onUpdate: @escaping (WorkoutItem) -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _restSeconds = State(initialValue: item.restSeconds)
    }
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "timer")
                    .foregroundColor(Theme.orange)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Rest Period")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("\(restSeconds) seconds")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: Theme.Spacing.xs) {
                Button {
                    showingEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(Theme.orange)
                }
                .buttonStyle(.plain)
                
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingEditor) {
            RestPeriodEditorSheet(
                restSeconds: $restSeconds,
                onSave: {
                    var updated = item
                    updated.restSeconds = restSeconds
                    onUpdate(updated)
                }
            )
        }
    }
}

struct RestPeriodEditorSheet: View {
    @Binding var restSeconds: Int
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Rest Duration") {
                    Stepper("Rest: \(restSeconds) seconds", value: $restSeconds, in: 0...600)
                    Text("Rest period between drills in the workout.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Edit Rest Period")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DrillPickerView: View {
    @ObservedObject var drillStore: DrillStore
    let onSelect: (Drill) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    
    private var filteredDrills: [Drill] {
        if searchText.isEmpty {
            return drillStore.drills.sorted { $0.name < $1.name }
        } else {
            return drillStore.drills
                .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                .sorted { $0.name < $1.name }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredDrills) { drill in
                    Button {
                        onSelect(drill)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(drill.name)
                                    .foregroundColor(.primary)
                                HStack {
                                    CategoryBadge(category: drill.category)
                                    Text("\(drill.lengthSeconds)s")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
            .searchable(text: $searchText)
            .navigationTitle("Select Drill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
