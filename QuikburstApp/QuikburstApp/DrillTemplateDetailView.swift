import SwiftUI

struct DrillTemplateDetailView: View {
    let template: DrillTemplate
    @ObservedObject var templateStore: DrillTemplateStore
    @EnvironmentObject var baselineStore: DrillBaselineStore
    @EnvironmentObject var runStore: DrillRunStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var navigationCoordinator: AppNavigationCoordinator
    @State private var showingAddToWorkout = false
    @State private var showingEditDrill = false
    
    private var baseline: DrillBaseline? {
        baselineStore.getBaseline(for: template.id)
    }
    
    private var runs: [DrillRun] {
        runStore.fetchRuns(for: template.id)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // Header with status
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            Text(template.name)
                                .font(Theme.Typography.title)
                            Spacer()
                            ProbationStatusPill(status: template.probationStatus)
                        }
                        
                        if let description = template.description {
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(spacing: Theme.Spacing.sm) {
                            let effectivePhases = template.effectivePhases
                            if effectivePhases.count > 1 {
                                Text("\(effectivePhases.count) Phases")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(template.type.rawValue)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if let distance = template.distanceMeters {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.1fm", distance))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    // All drill details - Phases
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Phases")
                            .font(.headline)
                        
                        // Always show phases using effectivePhases
                        let effectivePhases = template.effectivePhases
                        if effectivePhases.count > 1 {
                            // Multi-phase drill
                            Text("This drill has \(effectivePhases.count) phases")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, Theme.Spacing.xs)
                        } else {
                            Text("Single phase drill")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, Theme.Spacing.xs)
                        }
                        
                        // Show all phases
                        ForEach(Array(effectivePhases.enumerated()), id: \.element.id) { index, phase in
                            PhaseDetailCard(phase: phase, phaseNumber: index + 1, totalPhases: effectivePhases.count)
                        }
                    }
                    
                    // Video attachment
                    if let videoURL = template.videoURL {
                        Divider()
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("Attachments")
                                .font(.headline)
                            HStack {
                                Text("Video")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: "video.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Primary CTA
                    VStack(spacing: Theme.Spacing.md) {
                        if template.probationStatus == .probationary {
                            Button {
                                navigationCoordinator.startDrillTemplateInTrain(template, isBaseline: true)
                                dismiss()
                            } label: {
                                Label("Run Baseline (No Motor)", systemImage: "play.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Theme.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(Theme.CornerRadius.medium)
                            }
                            .accessibilityLabel("Run Baseline")
                            .accessibilityHint("Opens Train tab to run baseline")
                            
                            Text("Run once without motor to calibrate")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Button {
                                navigationCoordinator.startDrillTemplateInTrain(template, isBaseline: false)
                                dismiss()
                            } label: {
                                Label("Run Drill", systemImage: "play.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Theme.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(Theme.CornerRadius.medium)
                            }
                            .accessibilityLabel("Run Drill")
                            .accessibilityHint("Opens Train tab to run drill")
                            
                            Button {
                                showingAddToWorkout = true
                            } label: {
                                Label("Add to Workout", systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color(.systemGray5))
                                    .foregroundColor(.primary)
                                    .cornerRadius(Theme.CornerRadius.medium)
                            }
                            .accessibilityLabel("Add to Workout")
                        }
                    }
                    
                    // Runs history
                    if !runs.isEmpty {
                        Divider()
                        
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("History")
                                .font(.headline)
                            
                            // Baseline run pinned at top
                            if let baselineRun = runs.first(where: { $0.runMode == .baselineNoEnforcement }) {
                                BaselineRunCard(run: baselineRun)
                            }
                            
                            // Recent enforced runs
                            ForEach(runs.filter { $0.runMode == .enforced }.prefix(5)) { run in
                                DrillRunCard(run: run, baseline: baseline)
                            }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingEditDrill = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit Drill")
                }
            }
            .sheet(isPresented: $showingEditDrill) {
                CreateDrillWizardView(templateStore: templateStore, editingTemplate: template)
            }
            .sheet(isPresented: $showingAddToWorkout) {
                // TODO: Add to workout flow
                Text("Add to Workout")
            }
        }
    }
    
    private var targetModeDescription: String {
        switch template.targetMode {
        case .distanceOnly:
            return "Distance Only"
        case .timeOnly:
            return "Time Only"
        case .distanceAndTime:
            return "Distance and Time"
        case .speedPercentOfBaseline:
            return "Speed % of Baseline"
        case .forcePercentOfBaseline:
            return "Force % of Baseline"
        }
    }
    
    private var enforcementIntentDescription: String {
        switch template.enforcementIntent {
        case .none:
            return "None"
        case .velocityCurve:
            return "Velocity Curve"
        case .torqueEnvelope:
            return "Torque Envelope"
        case .hybrid:
            return "Hybrid"
        }
    }
    
    @ViewBuilder
    private var targetSummaryView: some View {
        switch template.targetMode {
        case .distanceOnly:
            if let distance = template.distanceMeters {
                PropertyRow(label: "Distance", value: String(format: "%.1f m", distance))
            }
            
        case .distanceAndTime:
            if let distance = template.distanceMeters {
                PropertyRow(label: "Distance", value: String(format: "%.1f m", distance))
            }
            if let time = template.targetTimeSeconds {
                PropertyRow(label: "Time", value: String(format: "%.1f s", time))
            }
            
        case .speedPercentOfBaseline:
            if let percent = template.speedPercentOfBaseline {
                PropertyRow(label: "Speed Target", value: String(format: "%.1f%% of baseline", percent))
            }
            
        case .timeOnly:
            if let time = template.targetTimeSeconds {
                PropertyRow(label: "Time", value: String(format: "%.1f s", time))
            }
            
        case .forcePercentOfBaseline:
            if let percent = template.forcePercentOfBaseline {
                PropertyRow(label: "Force Target", value: String(format: "%.1f%% of baseline", percent))
            }
        }
    }
}

struct BaselineRunCard: View {
    let run: DrillRun
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Label("Baseline Run", systemImage: "flag.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                Spacer()
                Text(run.timestamp, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: Theme.Spacing.md) {
                if let distance = run.results.distanceMeters as Double? {
                    Text(String(format: "%.1fm", distance))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(String(format: "%.1fs", run.results.durationSeconds))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%.1f m/s", run.results.avgSpeedMps))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(Theme.CornerRadius.small)
    }
}

struct DrillRunCard: View {
    let run: DrillRun
    let baseline: DrillBaseline?
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(run.timestamp, style: .date)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let comparisons = run.derivedComparisons,
                   let speedPercent = comparisons.percentVsBaselineSpeed {
                    Text(String(format: "%.0f%%", speedPercent))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(speedPercent >= 100 ? .green : .orange)
                }
            }
            
            HStack(spacing: Theme.Spacing.md) {
                Text(String(format: "%.1fs", run.results.durationSeconds))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%.1f m/s", run.results.avgSpeedMps))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Color(.systemGray6))
        .cornerRadius(Theme.CornerRadius.small)
    }
}

struct PhaseDetailCard: View {
    let phase: DrillPhase
    let phaseNumber: Int
    let totalPhases: Int
    @EnvironmentObject var profileStore: ProfileStore
    
    private var unitSystem: UnitSystem {
        profileStore.selectedUser?.effectiveUnitSystem ?? .metric
    }
    
    private var motorBehavior: String {
        if phase.isResist && phase.isAssist {
            return "Resist & Assist"
        } else if phase.isResist {
            return "Resist"
        } else if phase.isAssist {
            return "Assist"
        } else {
            return "None"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Phase \(phaseNumber)")
                    .font(.headline)
                    .fontWeight(.semibold)
                if totalPhases > 1 {
                    Text("of \(totalPhases)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Divider()
            
            // Drill type
            PropertyRow(label: "Type", value: phase.drillType.rawValue)
            
            // Motor behavior
            PropertyRow(label: "Motor Behavior", value: motorBehavior)
            
            // Target (distance or time)
            if phase.drillType == .speedDrill {
                if let distance = phase.distanceMeters {
                    let displayDistance = unitSystem == .imperial ? distance * 1.09361 : distance
                    let unit = unitSystem == .imperial ? "yds" : "m"
                    PropertyRow(label: "Distance", value: String(format: "%.1f \(unit)", displayDistance))
                } else {
                    PropertyRow(label: "Distance", value: "Not specified")
                }
            } else {
                if let time = phase.targetTimeSeconds {
                    PropertyRow(label: "Duration", value: String(format: "%.1f s", time))
                } else {
                    PropertyRow(label: "Duration", value: "Not specified")
                }
            }
            
            // Force settings
            PropertyRow(label: "Force Type", value: phase.forceType == .constant ? "Constant" : "Percentile")
            
            if phase.forceType == .constant {
                // Phase should have constantForceN from effectivePhases conversion (legacy or new)
                if let force = phase.constantForceN {
                    PropertyRow(label: "Force", value: String(format: "%.1f N", force))
                } else {
                    PropertyRow(label: "Force", value: "Not specified")
                }
                if let rampup = phase.rampupTimeSeconds {
                    PropertyRow(label: "Rampup Time", value: String(format: "%.1f s", rampup))
                }
                
                // Show torque curve if available
                if let torqueCurve = phase.torqueCurve, !torqueCurve.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Torque Curve")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        Text("\(torqueCurve.count) points")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
            } else {
                if let percent = phase.forcePercentOfBaseline {
                    PropertyRow(label: "Percentile", value: String(format: "%.1f%% of baseline", percent))
                } else {
                    PropertyRow(label: "Percentile", value: "Not specified")
                }
                
                // Show torque curve if available (for percentile mode)
                if let torqueCurve = phase.torqueCurve, !torqueCurve.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Torque Curve")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        Text("\(torqueCurve.count) points")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Color(.systemGray6))
        .cornerRadius(Theme.CornerRadius.medium)
    }
}

// Specialized view for use in TrainTabView
struct DrillTemplateDetailViewForTrain: View {
    let template: DrillTemplate
    @ObservedObject var templateStore: DrillTemplateStore
    let isBaseline: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    @EnvironmentObject var baselineStore: DrillBaselineStore
    @EnvironmentObject var runStore: DrillRunStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditDrill = false
    
    private var baseline: DrillBaseline? {
        baselineStore.getBaseline(for: template.id)
    }
    
    private var runs: [DrillRun] {
        runStore.fetchRuns(for: template.id)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // Header with status
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            Text(template.name)
                                .font(Theme.Typography.title)
                            Spacer()
                            ProbationStatusPill(status: template.probationStatus)
                        }
                        
                        if let description = template.description {
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(spacing: Theme.Spacing.sm) {
                            let effectivePhases = template.effectivePhases
                            if effectivePhases.count > 1 {
                                Text("\(effectivePhases.count) Phases")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(template.type.rawValue)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if let distance = template.distanceMeters {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.1fm", distance))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    // All drill details - Phases
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Phases")
                            .font(.headline)
                        
                        // Always show phases using effectivePhases
                        let effectivePhases = template.effectivePhases
                        if effectivePhases.count > 1 {
                            // Multi-phase drill
                            Text("This drill has \(effectivePhases.count) phases")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, Theme.Spacing.xs)
                        } else {
                            Text("Single phase drill")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, Theme.Spacing.xs)
                        }
                        
                        // Show all phases
                        ForEach(Array(effectivePhases.enumerated()), id: \.element.id) { index, phase in
                            PhaseDetailCard(phase: phase, phaseNumber: index + 1, totalPhases: effectivePhases.count)
                        }
                    }
                    
                    // Video attachment
                    if let videoURL = template.videoURL {
                        Divider()
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("Attachments")
                                .font(.headline)
                            HStack {
                                Text("Video")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: "video.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Primary CTA
                    VStack(spacing: Theme.Spacing.md) {
                        if isBaseline || template.probationStatus == .probationary {
                            Button {
                                HapticFeedback.buttonPress()
                                onStart()
                            } label: {
                                Label("Run Baseline (No Motor)", systemImage: "play.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Theme.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(Theme.CornerRadius.medium)
                            }
                            .accessibilityLabel("Run Baseline")
                            .accessibilityHint("Starts baseline run")
                            
                            Text("Run once without motor to calibrate")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Button {
                                HapticFeedback.buttonPress()
                                onStart()
                            } label: {
                                Label("Start Drill", systemImage: "play.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Theme.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(Theme.CornerRadius.medium)
                            }
                            .accessibilityLabel("Start Drill")
                            .accessibilityHint("Starts the drill")
                        }
                    }
                    
                    // Runs history
                    if !runs.isEmpty {
                        Divider()
                        
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("History")
                                .font(.headline)
                            
                            // Baseline run pinned at top
                            if let baselineRun = runs.first(where: { $0.runMode == .baselineNoEnforcement }) {
                                BaselineRunCard(run: baselineRun)
                            }
                            
                            // Recent enforced runs
                            ForEach(runs.filter { $0.runMode == .enforced }.prefix(5)) { run in
                                DrillRunCard(run: run, baseline: baseline)
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle("Drill Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingEditDrill = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit Drill")
                }
            }
            .sheet(isPresented: $showingEditDrill) {
                CreateDrillWizardView(templateStore: templateStore, editingTemplate: template)
            }
        }
    }
    
    private var targetModeDescription: String {
        switch template.targetMode {
        case .distanceOnly:
            return "Distance Only"
        case .timeOnly:
            return "Time Only"
        case .distanceAndTime:
            return "Distance and Time"
        case .speedPercentOfBaseline:
            return "Speed % of Baseline"
        case .forcePercentOfBaseline:
            return "Force % of Baseline"
        }
    }
    
    private var enforcementIntentDescription: String {
        switch template.enforcementIntent {
        case .none:
            return "None"
        case .velocityCurve:
            return "Velocity Curve"
        case .torqueEnvelope:
            return "Torque Envelope"
        case .hybrid:
            return "Hybrid"
        }
    }
}
