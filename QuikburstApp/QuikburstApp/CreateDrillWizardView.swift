import SwiftUI
import PhotosUI


struct CreateDrillWizardView: View {
    @ObservedObject var templateStore: DrillTemplateStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    
    var editingTemplate: DrillTemplate?
    
    @State private var currentStep = 1
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoURL: String?
    
    // Phase management
    @State private var phases: [DrillPhase] = {
        var phase = DrillPhase()
        phase.quikburstMode = .resist
        // Initialize with default values - default to speed drill with 10 meters/yards
        phase.durationValue = 10.0
        // Will be set based on user settings in onAppear
        return [phase]
    }()
    
    private var isEditing: Bool {
        editingTemplate != nil
    }
    
    init(templateStore: DrillTemplateStore, editingTemplate: DrillTemplate? = nil) {
        self.templateStore = templateStore
        self.editingTemplate = editingTemplate
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Progress indicator
                ProgressIndicator(currentStep: currentStep, totalSteps: 2)
                    .padding()
                
                // Content
                Group {
                    if currentStep == 1 {
                        Step1BasicsView(
                            name: $name,
                            description: $description,
                            selectedVideo: $selectedVideo
                        )
                    } else {
                        Step2PhasesView(
                            phases: $phases
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Navigation buttons
                HStack(spacing: Theme.Spacing.md) {
                    if currentStep > 1 {
                        Button("Back") {
                            withAnimation {
                                currentStep -= 1
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Spacer()
                    
                    if currentStep < 2 {
                        Button("Next") {
                            withAnimation {
                                currentStep += 1
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.orange)
                        .disabled(!isStep1Valid)
                    } else {
                        Button(isEditing ? "Save" : "Create") {
                            createDrill()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.orange)
                        .disabled(!isStep2Valid)
                    }
                }
                .padding()
            }
            .navigationTitle(isEditing ? "Edit Drill" : "New Drill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onChange(of: selectedVideo) { _, newValue in
                Task {
                    if (try? await newValue?.loadTransferable(type: Data.self)) != nil {
                        // In a real app, you'd upload this to storage and get a URL
                        // For now, we'll just store a placeholder
                        videoURL = "video_\(UUID().uuidString)"
                    }
                }
            }
            .onAppear {
                // Initialize default duration unit for new phases based on user settings
                if editingTemplate == nil {
                    let unitSystem = profileStore.selectedUser?.effectiveUnitSystem ?? .metric
                    for index in phases.indices {
                        if phases[index].durationUnit == nil {
                            if phases[index].drillType == .speedDrill {
                                phases[index].durationUnit = unitSystem == .imperial ? DurationUnit.yards : DurationUnit.meters
                            } else {
                                phases[index].durationUnit = DurationUnit.seconds
                            }
                        }
                    }
                }
                
                if let template = editingTemplate {
                    loadTemplate(template)
                }
            }
        }
    }
    
    private func loadTemplate(_ template: DrillTemplate) {
        name = template.name
        description = template.description ?? ""
        videoURL = template.videoURL
        
            // Load phases if available, otherwise create from legacy fields
        if let templatePhases = template.phases, !templatePhases.isEmpty {
            phases = templatePhases
        } else {
            // Create single phase from legacy fields
            let quikburstMode: QuikburstMode = template.isResist ? .resist : (template.isAssist ? .assist : .resist)
            var phase = DrillPhase(
                drillType: template.type,
                quikburstMode: quikburstMode,
                distanceMeters: template.distanceMeters,
                targetTimeSeconds: template.targetTimeSeconds,
                forceType: template.forceType ?? .constant,
                constantForceN: template.constantForceN,
                forcePercentOfBaseline: template.forcePercentOfBaseline,
                rampupTimeSeconds: template.rampupTimeSeconds,
                torqueCurve: template.torqueCurve
            )
            // Set duration value and unit from legacy fields
            if phase.drillType == .speedDrill {
                // Speed drills use distance units
                if let distance = template.distanceMeters {
                    let unitSystem = profileStore.selectedUser?.effectiveUnitSystem ?? .metric
                    if unitSystem == .imperial {
                        phase.durationValue = distance * 1.09361 // Convert meters to yards
                        phase.durationUnit = DurationUnit.yards
                    } else {
                        phase.durationValue = distance
                        phase.durationUnit = DurationUnit.meters
                    }
                }
            } else {
                // Force drills can use time or distance
                if let time = template.targetTimeSeconds {
                    phase.durationValue = time
                    phase.durationUnit = DurationUnit.seconds
                } else if let distance = template.distanceMeters {
                    let unitSystem = profileStore.selectedUser?.effectiveUnitSystem ?? .metric
                    if unitSystem == .imperial {
                        phase.durationValue = distance * 1.09361 // Convert meters to yards
                        phase.durationUnit = DurationUnit.yards
                    } else {
                        phase.durationValue = distance
                        phase.durationUnit = DurationUnit.meters
                    }
                }
            }
            phases = [phase]
        }
    }
    
    private var isStep1Valid: Bool {
        !name.isEmpty
    }
    
    private var isStep2Valid: Bool {
        phases.allSatisfy { phase in
            guard let durationValue = phase.durationValue, durationValue > 0 else { return false }
            if phase.drillType == .speedDrill {
                // Speed drill must use distance units (meters or yards)
                return phase.durationUnit == DurationUnit.meters || phase.durationUnit == DurationUnit.yards
            } else {
                // Force drill can use seconds or distance units
                return phase.durationUnit == DurationUnit.seconds || phase.durationUnit == DurationUnit.meters || phase.durationUnit == DurationUnit.yards
            }
        }
    }
    
    private func createDrill() {
        // Process phases - convert duration values to appropriate fields
        var processedPhases: [DrillPhase] = []
        
        for phase in phases {
            var updatedPhase = phase
            
            // Convert duration value and unit to appropriate fields
            if let durationValue = phase.durationValue, let durationUnit = phase.durationUnit {
                if phase.drillType == .speedDrill {
                    // Speed drill uses distance units (meters or yards)
                    // Convert distance to meters
                    let distanceMeters = durationUnit == .yards ? durationValue * 0.9144 : durationValue
                    updatedPhase.distanceMeters = distanceMeters
                    updatedPhase.targetTimeSeconds = nil
                } else {
                    // Force drill can use seconds or distance
                    if durationUnit == .seconds {
                        updatedPhase.targetTimeSeconds = durationValue
                        updatedPhase.distanceMeters = nil
                    } else {
                        // Convert distance to meters
                        let distanceMeters = durationUnit == .yards ? durationValue * 0.9144 : durationValue
                        updatedPhase.distanceMeters = distanceMeters
                        updatedPhase.targetTimeSeconds = nil
                    }
                }
            }
            
            // Ensure force values are set for force drills with constant force
            if updatedPhase.drillType == .forceDrill && updatedPhase.forceType == .constant {
                if !updatedPhase.liveVariation {
                    // Single value force - ensure it's set
                    if updatedPhase.constantForceN == nil {
                        updatedPhase.constantForceN = 50.0
                    }
                } else {
                    // Live variation - ensure both min and max are set
                    if updatedPhase.constantForceN == nil {
                        updatedPhase.constantForceN = 20.0
                    }
                    if updatedPhase.constantForceMaxN == nil {
                        updatedPhase.constantForceMaxN = 30.0
                    }
                }
            }
            
            // For constant force drills, ensure wantsBaseline is explicitly false if not enabled
            // (default is false, but we want to be explicit)
            if updatedPhase.drillType == .forceDrill && updatedPhase.forceType == .constant && !updatedPhase.liveVariation {
                // Only set to false if it's not already true (respect user's choice)
                // The toggle should have already set this, but ensure it's explicit
            }
            
            processedPhases.append(updatedPhase)
        }
        
        // Determine overall drill type (use first phase's type for legacy compatibility)
        let overallType = processedPhases.first?.drillType ?? .speedDrill
        
        // Determine probation status:
        // - If any phase uses percentile, drill is probationary
        // - If any phase requires baseline (wantsBaseline is true), drill is probationary
        // - If wantsBaseline is explicitly false or not set, drill is NOT probationary
        let hasPercentilePhase = processedPhases.contains { $0.forceType == .percentile }
        let requiresBaseline = processedPhases.contains { $0.wantsBaseline == true }
        let probationStatus: ProbationStatus = (hasPercentilePhase || requiresBaseline) ? .probationary : .baselineCaptured
        
        if let existing = editingTemplate {
            // Update existing template
            var updated = existing
            updated.name = name
            updated.description = description.isEmpty ? nil : description
            updated.videoURL = videoURL
            updated.type = overallType
            updated.phases = processedPhases
            updated.updatedAt = Date()
            
            // Update legacy fields for backward compatibility (use first phase)
            if let firstPhase = processedPhases.first {
                updated.isResist = firstPhase.quikburstMode == .resist
                updated.isAssist = firstPhase.quikburstMode == .assist
                updated.distanceMeters = firstPhase.distanceMeters
                updated.targetTimeSeconds = firstPhase.targetTimeSeconds
                updated.forceType = firstPhase.forceType
                updated.constantForceN = firstPhase.constantForceN
                updated.rampupTimeSeconds = firstPhase.rampupTimeSeconds
                updated.torqueCurve = firstPhase.torqueCurve
                updated.forcePercentOfBaseline = firstPhase.forcePercentOfBaseline
                updated.targetMode = firstPhase.drillType == .speedDrill ? .distanceOnly : (firstPhase.forceType == .percentile ? .forcePercentOfBaseline : .timeOnly)
            }
            
            // If switching to percentile, mark as probationary
            if hasPercentilePhase && existing.probationStatus == .baselineCaptured {
                updated.probationStatus = .probationary
            } else {
                updated.probationStatus = probationStatus
            }
            
            templateStore.updateTemplate(updated)
        } else {
            // Create new template
            let firstPhase = processedPhases.first ?? DrillPhase()
            let template = DrillTemplate(
                name: name,
                description: description.isEmpty ? nil : description,
                videoURL: videoURL,
                type: overallType,
                isResist: firstPhase.quikburstMode == .resist,
                isAssist: firstPhase.quikburstMode == .assist,
                distanceMeters: firstPhase.distanceMeters,
                targetTimeSeconds: firstPhase.targetTimeSeconds,
                targetMode: firstPhase.drillType == .speedDrill ? .distanceOnly : (firstPhase.forceType == .percentile ? .forcePercentOfBaseline : .timeOnly),
                enforcementIntent: .torqueEnvelope,
                probationStatus: probationStatus,
                phases: processedPhases,
                forceType: firstPhase.forceType,
                constantForceN: firstPhase.constantForceN,
                rampupTimeSeconds: firstPhase.rampupTimeSeconds,
                torqueCurve: firstPhase.torqueCurve,
                forcePercentOfBaseline: firstPhase.forcePercentOfBaseline
            )
            
            templateStore.createOrMergeDrillTemplate(template)
        }
        
        dismiss()
    }
}

struct ProgressIndicator: View {
    let currentStep: Int
    let totalSteps: Int
    
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(1...totalSteps, id: \.self) { step in
                Circle()
                    .fill(step <= currentStep ? Theme.orange : Color(.systemGray4))
                    .frame(width: 12, height: 12)
            }
        }
    }
}

struct Step1BasicsView: View {
    @Binding var name: String
    @Binding var description: String
    @Binding var selectedVideo: PhotosPickerItem?
    
    var body: some View {
        Form {
            Section("Basics") {
                TextField("Drill Name", text: $name)
                
                TextField("Description (Optional)", text: $description, axis: .vertical)
                    .lineLimit(3...6)
                
                PhotosPicker(selection: $selectedVideo, matching: .videos) {
                    HStack {
                        Text("Attach Video (Optional)")
                        Spacer()
                        if selectedVideo != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
    }
}

struct Step2PhasesView: View {
    @Binding var phases: [DrillPhase]
    @EnvironmentObject var profileStore: ProfileStore
    
    var body: some View {
        Form {
            ForEach(phases.indices, id: \.self) { index in
                Section {
                    PhaseConfigurationView(
                        phase: Binding(
                            get: { phases[index] },
                            set: { phases[index] = $0 }
                        ),
                        phaseNumber: index + 1,
                        canDelete: phases.count > 1
                    ) {
                        phases.remove(at: index)
                    }
                }
            }
            
            Section {
                Button(action: {
                    var newPhase = DrillPhase()
                    newPhase.quikburstMode = .resist
                    // Initialize with default values
                    newPhase.durationValue = 10.0
                    // Set unit based on drill type and user settings
                    let unitSystem = profileStore.selectedUser?.effectiveUnitSystem ?? .metric
                    if newPhase.drillType == .speedDrill {
                        newPhase.durationUnit = unitSystem == .imperial ? DurationUnit.yards : DurationUnit.meters
                    } else {
                        newPhase.durationUnit = DurationUnit.seconds
                    }
                    phases.append(newPhase)
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Another Phase")
                    }
                    .foregroundColor(Theme.orange)
                }
            }
        }
    }
}

struct PhaseConfigurationView: View {
    @Binding var phase: DrillPhase
    let phaseNumber: Int
    let canDelete: Bool
    let onDelete: () -> Void
    
    @State private var durationText: String = "10"
    @State private var showDeleteConfirmation = false
    
    @EnvironmentObject var profileStore: ProfileStore
    
    private var unitSystem: UnitSystem {
        profileStore.selectedUser?.effectiveUnitSystem ?? .metric
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Text("Phase \(phaseNumber)")
                    .font(.headline)
                Spacer()
                if canDelete {
                    Button(action: {
                        showDeleteConfirmation = true
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.red)
                            .frame(width: 44, height: 44)
                            .background(Color.red.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, Theme.Spacing.xs)
            
            // Drill Type Selection (Speed/Force switch at top)
            Picker("Drill Type", selection: Binding(
                get: { phase.drillType },
                set: { 
                    phase.drillType = $0
                    // Reset duration unit based on drill type
                    if $0 == .speedDrill {
                        // Speed drill uses distance units based on user settings
                        if phase.durationUnit == nil || phase.durationUnit == .seconds {
                            phase.durationUnit = unitSystem == .imperial ? DurationUnit.yards : DurationUnit.meters
                        }
                        if phase.durationValue == nil {
                            phase.durationValue = 10.0
                            durationText = "10"
                        }
                        // Update baseline requirement for speed drills
                        if phase.forceType == .constant && !phase.liveVariation {
                            phase.wantsBaseline = false
                        } else {
                            phase.wantsBaseline = true
                        }
                    } else {
                        // Force drill can use seconds or distance
                        if phase.durationUnit == nil {
                            phase.durationUnit = DurationUnit.seconds
                        }
                        if phase.durationValue == nil {
                            phase.durationValue = 10.0
                            durationText = "10"
                        }
                        // Force drills keep their baseline setting (don't auto-set)
                    }
                }
            )) {
                Text("Speed Drill").tag(DrillType.speedDrill)
                Text("Force Drill").tag(DrillType.forceDrill)
            }
            .pickerStyle(.segmented)
            
            // Drill Duration
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Drill Duration")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack {
                    TextField("Duration", text: $durationText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: durationText) { _, newValue in
                            if let value = Double(newValue), value > 0 {
                                phase.durationValue = value
                            }
                        }
                    
                    if phase.drillType == .forceDrill {
                        // Force drill: dropdown with seconds or distance units based on user's unit system
                        Picker("", selection: Binding(
                            get: { phase.durationUnit ?? DurationUnit.seconds },
                            set: { phase.durationUnit = $0 }
                        )) {
                            Text("seconds").tag(DurationUnit.seconds)
                            if unitSystem == .imperial {
                                Text("yards").tag(DurationUnit.yards)
                            } else {
                                Text("meters").tag(DurationUnit.meters)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        // Speed drill: dropdown with distance units based on user's unit system
                        Picker("", selection: Binding(
                            get: { phase.durationUnit ?? (unitSystem == .imperial ? DurationUnit.yards : DurationUnit.meters) },
                            set: { phase.durationUnit = $0 }
                        )) {
                            if unitSystem == .imperial {
                                Text("yards").tag(DurationUnit.yards)
                            } else {
                                Text("meters").tag(DurationUnit.meters)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            
            // Quikburst Mode (renamed from Motor Behavior)
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Quikburst Mode")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Picker("Quikburst Mode", selection: Binding(
                    get: { phase.quikburstMode },
                    set: { phase.quikburstMode = $0 }
                )) {
                    Text("Resist").tag(QuikburstMode.resist)
                    Text("Assist").tag(QuikburstMode.assist)
                    Text("Measure").tag(QuikburstMode.measure)
                }
                .pickerStyle(.segmented)
                
                // Description based on selected mode
                switch phase.quikburstMode {
                case .resist:
                    Text("Machine brakes you as you run away")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .assist:
                    Text("Machine drags you towards the target")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .measure:
                    Text("Machine measures your performance without applying force")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Baseline checkbox
            // Speed drills need baseline unless constant force is selected (without live variation)
            // Force drills have optional baseline
            if phase.drillType == .speedDrill {
                // Speed drills always need baseline unless constant force without variation
                if phase.forceType == .constant && !phase.liveVariation {
                    // Constant force without variation - no baseline needed
                    Text("No baseline required for constant force drills")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // Speed drills with percentage or variable need baseline
                    Toggle("Baseline required", isOn: Binding(
                        get: { phase.wantsBaseline },
                        set: { phase.wantsBaseline = $0 }
                    ))
                    .font(.subheadline)
                    .disabled(true) // Always true for speed drills that need it
                    .onAppear {
                        phase.wantsBaseline = true
                    }
                }
            } else if phase.drillType == .forceDrill {
                // Force drills have optional baseline
                Toggle("Do you want a baseline?", isOn: Binding(
                    get: { phase.wantsBaseline },
                    set: { phase.wantsBaseline = $0 }
                ))
                .font(.subheadline)
            }
            
            // Force Type Selection
            Picker("Force Type", selection: Binding(
                get: { phase.forceType },
                set: { 
                    phase.forceType = $0
                    // Update baseline requirement for speed drills
                    if phase.drillType == .speedDrill {
                        // Speed drills need baseline unless constant force without variation
                        if $0 == .constant && !phase.liveVariation {
                            phase.wantsBaseline = false
                        } else {
                            phase.wantsBaseline = true
                        }
                    }
                }
            )) {
                Text("Custom Force").tag(ForceType.constant)
                Text("Percentage").tag(ForceType.percentile)
            }
            .pickerStyle(.segmented)
            
            // Live Variation Switch
            Toggle("Live Variation", isOn: Binding(
                get: { phase.liveVariation },
                set: { 
                    phase.liveVariation = $0
                    // If enabling live variation and it's a speed drill, require baseline
                    if $0 && phase.drillType == .speedDrill {
                        phase.wantsBaseline = true
                    }
                }
            ))
            .font(.subheadline)
            
            Text("Live variation cannot be used in workouts")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Force/Percentage Input (with bounds if live variation)
            if phase.forceType == .constant {
                if phase.liveVariation {
                    // Bounds input for constant force
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Force Range (N)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        HStack {
                            TextField("Min", value: Binding(
                                get: { phase.constantForceN ?? 20.0 },
                                set: { 
                                    phase.constantForceN = $0
                                    // Ensure value is set even if 0
                                    if phase.constantForceN == nil {
                                        phase.constantForceN = 20.0
                                    }
                                }
                            ), format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            
                            Text("to")
                                .foregroundColor(.secondary)
                            
                            TextField("Max", value: Binding(
                                get: { phase.constantForceMaxN ?? 30.0 },
                                set: { 
                                    phase.constantForceMaxN = $0
                                    // Ensure value is set even if 0
                                    if phase.constantForceMaxN == nil {
                                        phase.constantForceMaxN = 30.0
                                    }
                                }
                            ), format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                } else {
                    // Single value input
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Force (N)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        TextField("Force", value: Binding(
                            get: { phase.constantForceN ?? 50.0 },
                            set: { 
                                phase.constantForceN = $0
                                // Ensure value is set even if user clears field - use 0 instead of nil
                                // This prevents "force not specified" when value is cleared
                            }
                        ), format: .number)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .onAppear {
                            // Initialize to 50.0 if nil (force drill with constant force should have a value)
                            if phase.drillType == .forceDrill && phase.constantForceN == nil {
                                phase.constantForceN = 50.0
                            }
                        }
                    }
                }
            } else {
                // Percentile mode
                if phase.liveVariation {
                    // Bounds input for percentile
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Percentage Range (%)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        HStack {
                            TextField("Min", value: Binding(
                                get: { phase.forcePercentOfBaseline ?? 85.0 },
                                set: { phase.forcePercentOfBaseline = $0 }
                            ), format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            
                            Text("to")
                                .foregroundColor(.secondary)
                            
                            TextField("Max", value: Binding(
                                get: { phase.forcePercentOfBaselineMax ?? 95.0 },
                                set: { phase.forcePercentOfBaselineMax = $0 }
                            ), format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                } else {
                    // Single value input
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Percentage (%)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        TextField("Percentage", value: Binding(
                            get: { phase.forcePercentOfBaseline ?? 10.0 },
                            set: { phase.forcePercentOfBaseline = $0 }
                        ), format: .number)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .alert("Delete Phase \(phaseNumber)?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("This will permanently delete Phase \(phaseNumber). This action cannot be undone.")
        }
        .onAppear {
            // Initialize duration text from phase
            if let durationValue = phase.durationValue {
                durationText = String(format: "%.0f", durationValue)
            } else {
                phase.durationValue = 10.0
                durationText = "10"
            }
            
            // Set default duration unit if not set
            if phase.durationUnit == nil {
                if phase.drillType == .speedDrill {
                    phase.durationUnit = unitSystem == .imperial ? DurationUnit.yards : DurationUnit.meters
                } else {
                    phase.durationUnit = DurationUnit.seconds
                }
            }
            
            // For force drills with constant force, ensure force value is set if not already
            if phase.drillType == .forceDrill && phase.forceType == .constant && !phase.liveVariation {
                if phase.constantForceN == nil {
                    phase.constantForceN = 50.0
                }
            }
            
            // For force drills, ensure wantsBaseline is explicitly set based on toggle state
            // If toggle is off, explicitly set to false
            if phase.drillType == .forceDrill && phase.forceType == .constant && !phase.liveVariation {
                // For constant force drills without live variation, baseline is optional
                // User's toggle choice determines wantsBaseline value
                // Default is false (no baseline required) unless user enables it
            }
        }
    }
}

