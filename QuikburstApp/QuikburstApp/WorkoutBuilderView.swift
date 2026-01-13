import SwiftUI

struct WorkoutBuilderView: View {
    @ObservedObject var workoutStore: WorkoutStore
    @ObservedObject var templateStore: DrillTemplateStore
    @Environment(\.dismiss) private var dismiss
    
    var editingWorkout: Workout?
    
    @State private var name: String = ""
    @State private var items: [WorkoutItem] = []
    @State private var showingDrillPicker = false
    
    private var isNewWorkout: Bool {
        editingWorkout == nil
    }
    
    init(workoutStore: WorkoutStore, templateStore: DrillTemplateStore, editingWorkout: Workout? = nil) {
        self.workoutStore = workoutStore
        self.templateStore = templateStore
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
                        } else if let template = templateStore.getTemplate(id: item.drillId) {
                            WorkoutItemEditorRow(
                                item: item,
                                template: template,
                                templateStore: templateStore,
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
                    
                    HStack(spacing: Theme.Spacing.sm) {
                        Button {
                            showingDrillPicker = true
                        } label: {
                            Label("Add Drill", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.sm)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
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
                                .padding(.vertical, Theme.Spacing.sm)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
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
                DrillTemplatePickerView(templateStore: templateStore) { template in
                    let newItem = WorkoutItem(
                        drillId: template.id,
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
        return item.drillId == restUUID || (item.reps == 0 && templateStore.getTemplate(id: item.drillId) == nil)
    }
}

struct WorkoutItemEditorRow: View {
    let item: WorkoutItem
    let template: DrillTemplate
    @ObservedObject var templateStore: DrillTemplateStore
    let onUpdate: (WorkoutItem) -> Void
    let onDelete: () -> Void
    
    @State private var reps: Int
    @State private var restSeconds: Int
    @State private var level: Int?
    @State private var showingEditor = false
    
    init(item: WorkoutItem, template: DrillTemplate, templateStore: DrillTemplateStore, onUpdate: @escaping (WorkoutItem) -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self.template = template
        self.templateStore = templateStore
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _reps = State(initialValue: item.reps)
        _restSeconds = State(initialValue: item.restSeconds)
        _level = State(initialValue: item.level)
    }
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Text(template.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if template.probationStatus == .probationary {
                        ProbationStatusPill(status: .probationary)
                    }
                }
                
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

struct DrillTemplatePickerView: View {
    @ObservedObject var templateStore: DrillTemplateStore
    let onSelect: (DrillTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedTemplate: DrillTemplate?
    
    private var filteredTemplates: [DrillTemplate] {
        let templates = templateStore.fetchTemplates()
        if searchText.isEmpty {
            return templates.sorted { $0.name < $1.name }
        } else {
            return templates
                .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                .sorted { $0.name < $1.name }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredTemplates) { template in
                    Button {
                        if template.probationStatus == .baselineCaptured {
                            onSelect(template)
                            dismiss()
                        } else {
                            selectedTemplate = template
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(template.name)
                                    .foregroundColor(template.probationStatus == .baselineCaptured ? .primary : .secondary)
                                
                                HStack {
                                    ProbationStatusPill(status: template.probationStatus)
                                    
                                    if let distance = template.distanceMeters {
                                        Text(String(format: "%.1fm", distance))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            
                            if template.probationStatus == .probationary {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .disabled(template.probationStatus == .probationary)
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
            .alert("Drill Needs Baseline", isPresented: Binding(
                get: { selectedTemplate != nil },
                set: { if !$0 { selectedTemplate = nil } }
            )) {
                Button("Run Baseline") {
                    // TODO: Navigate to drill detail to run baseline
                    selectedTemplate = nil
                }
                Button("Cancel", role: .cancel) {
                    selectedTemplate = nil
                }
            } message: {
                if let template = selectedTemplate {
                    Text("\(template.name) needs a baseline run before it can be added to workouts. Run it once without motor enforcement first.")
                }
            }
        }
    }
}
