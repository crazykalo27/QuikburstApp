import SwiftUI

struct DrillTabView: View {
    @EnvironmentObject var templateStore: DrillTemplateStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var profileStore: ProfileStore
    @State private var selectedSegment: CatalogSegment = .drills
    @State private var searchText = ""
    @State private var showingFilters = false
    @State private var showingCreateDrillWizard = false
    @State private var showingWorkoutBuilder = false
    @State private var selectedTemplate: DrillTemplate?
    @State private var selectedWorkout: Workout?
    @State private var templateToDelete: DrillTemplate?
    @State private var workoutToDelete: Workout?
    @State private var showingDeleteConfirmation = false
    
    // Filter state
    @State private var filterCategory: DrillCategory? = nil
    @State private var filterMinLength: Int? = nil
    @State private var filterMaxLength: Int? = nil
    @State private var filterCustomOnly: Bool = false
    @State private var filterBuiltInOnly: Bool = false
    @State private var filterFavoritesOnly: Bool = false
    
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
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.title3)
                                .foregroundColor(Theme.orange)
                            
                            if activeFilterCount > 0 {
                                Text("\(activeFilterCount)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Theme.orange)
                                    .clipShape(Circle())
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .accessibilityLabel("Filters")
                    .accessibilityValue(activeFilterCount > 0 ? "\(activeFilterCount) active filters" : "No active filters")
                    .accessibilityHint("Opens filter options")
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.sm)
                
                // Content
                Group {
                    if selectedSegment == .drills {
                        DrillTemplateCatalogView(
                            templates: filteredTemplates,
                            searchText: $searchText,
                            templateStore: templateStore,
                            onTemplateTap: { template in
                                selectedTemplate = template
                            },
                            onDeleteTemplate: { template in
                                templateToDelete = template
                                showingDeleteConfirmation = true
                            }
                        )
                    } else {
                        WorkoutCatalogView(
                            workouts: filteredWorkouts,
                            templateStore: templateStore,
                            onWorkoutTap: { workout in
                                selectedWorkout = workout
                            },
                            onDeleteWorkout: { workout in
                                workoutToDelete = workout
                                showingDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
            .drukNavigationTitle("Drill Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if selectedSegment == .drills {
                            showingCreateDrillWizard = true
                        } else {
                            showingWorkoutBuilder = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .medium))
                            Text(selectedSegment == .drills ? "Add Drill" : "Add Workout")
                                .font(Theme.Typography.exo2Nav)
                        }
                        .foregroundColor(Theme.orange)
                    }
                    .accessibilityLabel(selectedSegment == .drills ? "Add new drill" : "Add new workout")
                    .accessibilityHint("Opens editor to create a new item")
                }
            }
            .alert("Delete \(selectedSegment == .drills ? "Drill" : "Workout")", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    templateToDelete = nil
                    workoutToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let template = templateToDelete {
                        templateStore.deleteTemplate(template)
                        templateToDelete = nil
                    } else if let workout = workoutToDelete {
                        workoutStore.deleteWorkout(workout)
                        workoutToDelete = nil
                    }
                }
            } message: {
                if let template = templateToDelete {
                    Text("Are you sure you want to delete \"\(template.name)\"? This action cannot be undone.")
                } else if let workout = workoutToDelete {
                    Text("Are you sure you want to delete \"\(workout.name)\"? This action cannot be undone.")
                }
            }
            .sheet(isPresented: $showingCreateDrillWizard) {
                CreateDrillWizardView(templateStore: templateStore)
            }
            .sheet(isPresented: $showingWorkoutBuilder) {
                WorkoutBuilderView(workoutStore: workoutStore, templateStore: templateStore)
            }
            .sheet(item: $selectedTemplate) { template in
                DrillTemplateDetailView(template: template, templateStore: templateStore)
            }
            .sheet(item: $selectedWorkout) { workout in
                WorkoutDetailView(workout: workout, workoutStore: workoutStore, templateStore: templateStore)
            }
            .sheet(isPresented: $showingFilters) {
                FilterSheetView(
                    selectedSegment: selectedSegment,
                    category: $filterCategory,
                    minLength: $filterMinLength,
                    maxLength: $filterMaxLength,
                    customOnly: $filterCustomOnly,
                    builtInOnly: $filterBuiltInOnly,
                    favoritesOnly: $filterFavoritesOnly,
                    onApply: {
                        // Filters are applied automatically via bindings
                    }
                )
            }
        }
    }
    
    private var activeFilterCount: Int {
        var count = 0
        if filterCategory != nil { count += 1 }
        if filterMinLength != nil || filterMaxLength != nil { count += 1 }
        return count
    }
    
    private var filteredTemplates: [DrillTemplate] {
        var templates = templateStore.fetchTemplates()
        
        // Search filter
        if !searchText.isEmpty {
            templates = templates.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        return templates.sorted { $0.name < $1.name }
    }
    
    private var filteredWorkouts: [Workout] {
        var workouts = workoutStore.workouts
        
        // Search filter
        if !searchText.isEmpty {
            workouts = workouts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        // Custom/Built-in filter
        if filterCustomOnly {
            workouts = workouts.filter { $0.isCustom }
        }
        if filterBuiltInOnly {
            workouts = workouts.filter { !$0.isCustom }
        }
        
        // Favorites filter
        if filterFavoritesOnly {
            workouts = workouts.filter { $0.isFavorite }
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

struct DrillTemplateCatalogView: View {
    let templates: [DrillTemplate]
    @Binding var searchText: String
    @ObservedObject var templateStore: DrillTemplateStore
    let onTemplateTap: (DrillTemplate) -> Void
    let onDeleteTemplate: (DrillTemplate) -> Void
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(templates) { template in
                    DrillTemplateRowView(
                        template: template,
                        templateStore: templateStore,
                        onTap: {
                            onTemplateTap(template)
                        },
                        onDelete: {
                            onDeleteTemplate(template)
                        }
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

struct DrillTemplateRowView: View {
    let template: DrillTemplate
    @ObservedObject var templateStore: DrillTemplateStore
    let onTap: () -> Void
    let onDelete: () -> Void
    
    private var isCustomDrill: Bool {
        // Built-in drills are seeded in DrillTemplateStore.seedInitialDataIfNeeded()
        // Currently only "20 Yard Dash" is built-in
        // All other drills created by users are custom
        return template.name != "20 Yard Dash"
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
                            
                            // Probation status pill
                            ProbationStatusPill(status: template.probationStatus)
                        }
                        
                        HStack(spacing: Theme.Spacing.sm) {
                            // Target summary
                            Text(targetSummary)
                                .font(Theme.Typography.exo2Label)
                                .foregroundColor(.secondary)
                            
                            if let distance = template.distanceMeters {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1fm", distance))
                                    .font(Theme.Typography.exo2Label)
                                    .foregroundColor(.secondary)
                            }
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
            
            // Delete button - always visible for custom drills, on the right
            if isCustomDrill {
                Button(action: {
                    HapticFeedback.buttonPress()
                    onDelete()
                }) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(Theme.CornerRadius.small)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var targetSummary: String {
        switch template.targetMode {
        case .distanceOnly:
            return "Distance"
        case .distanceAndTime:
            if let distance = template.distanceMeters, let time = template.targetTimeSeconds {
                return String(format: "%.1fm • %.1fs", distance, time)
            }
            return "Distance + Time"
        case .speedPercentOfBaseline:
            if let percent = template.speedPercentOfBaseline {
                return String(format: "%.0f%% baseline", percent)
            }
            return "Baseline speed"
        case .timeOnly:
            if let time = template.targetTimeSeconds {
                return String(format: "%.1fs", time)
            }
            return "Time"
        case .forcePercentOfBaseline:
            return "Force target"
        }
    }
}

struct ProbationStatusPill: View {
    let status: ProbationStatus
    
    var body: some View {
        Text(status == .probationary ? "Probation" : "Ready")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                status == .probationary
                    ? Color.orange.opacity(0.15)
                    : Color.green.opacity(0.15)
            )
            .foregroundColor(
                status == .probationary
                    ? .orange
                    : .green
            )
            .cornerRadius(5)
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
    @ObservedObject var templateStore: DrillTemplateStore
    let onWorkoutTap: (Workout) -> Void
    let onDeleteWorkout: (Workout) -> Void
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(workouts) { workout in
                    WorkoutRowView(
                        workout: workout,
                        templateStore: templateStore,
                        onTap: {
                            onWorkoutTap(workout)
                        },
                        onDelete: {
                            onDeleteWorkout(workout)
                        }
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

struct WorkoutRowView: View {
    let workout: Workout
    @ObservedObject var templateStore: DrillTemplateStore
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
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
                            Text(workout.name.uppercased())
                                .font(Theme.Typography.drukWorkoutTitle)
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
            
            // Delete button - always visible for custom workouts
            if workout.isCustom {
                Button(action: {
                    HapticFeedback.buttonPress()
                    onDelete()
                }) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(Theme.CornerRadius.small)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FilterSheetView: View {
    let selectedSegment: DrillTabView.CatalogSegment
    @Binding var category: DrillCategory?
    @Binding var minLength: Int?
    @Binding var maxLength: Int?
    @Binding var customOnly: Bool
    @Binding var builtInOnly: Bool
    @Binding var favoritesOnly: Bool
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var tempCategory: DrillCategory?
    @State private var tempMinLength: Int?
    @State private var tempMaxLength: Int?
    @State private var tempCustomOnly: Bool = false
    @State private var tempBuiltInOnly: Bool = false
    @State private var tempFavoritesOnly: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                if selectedSegment == .drills {
                    Section("Category") {
                        Picker("Category", selection: $tempCategory) {
                            Text("All").tag(nil as DrillCategory?)
                            ForEach(DrillCategory.allCases, id: \.self) { cat in
                                Text(cat.rawValue).tag(cat as DrillCategory?)
                            }
                        }
                        .accessibilityLabel("Category filter")
                    }
                    
                    Section("Length Range") {
                        HStack {
                            Text("Min")
                            Spacer()
                            Picker("Min Length", selection: $tempMinLength) {
                                Text("Any").tag(Int?.none)
                                ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { length in
                                    Text("\(length)s").tag(Int?.some(length))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        .accessibilityLabel("Minimum length")
                        
                        HStack {
                            Text("Max")
                            Spacer()
                            Picker("Max Length", selection: $tempMaxLength) {
                                Text("Any").tag(Int?.none)
                                ForEach([10, 15, 20, 30, 45, 60], id: \.self) { length in
                                    Text("\(length)s").tag(Int?.some(length))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        .accessibilityLabel("Maximum length")
                    }
                }
                
                Section("Type") {
                    Toggle("Custom Only", isOn: $tempCustomOnly)
                        .accessibilityLabel("Show only custom items")
                    
                    Toggle("Built-in Only", isOn: $tempBuiltInOnly)
                        .accessibilityLabel("Show only built-in items")
                }
                
                Section {
                    Toggle("Favorites Only", isOn: $tempFavoritesOnly)
                        .accessibilityLabel("Show only favorites")
                }
            }
            .drukNavigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        tempCategory = nil
                        tempMinLength = nil
                        tempMaxLength = nil
                        tempCustomOnly = false
                        tempBuiltInOnly = false
                        tempFavoritesOnly = false
                    }
                    .foregroundColor(Theme.orange)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        category = tempCategory
                        minLength = tempMinLength
                        maxLength = tempMaxLength
                        customOnly = tempCustomOnly
                        builtInOnly = tempBuiltInOnly
                        favoritesOnly = tempFavoritesOnly
                        onApply()
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Initialize temp values from bindings
                tempCategory = category
                tempMinLength = minLength
                tempMaxLength = maxLength
                tempCustomOnly = customOnly
                tempBuiltInOnly = builtInOnly
                tempFavoritesOnly = favoritesOnly
            }
        }
    }
}

#Preview {
    DrillTabView()
}
