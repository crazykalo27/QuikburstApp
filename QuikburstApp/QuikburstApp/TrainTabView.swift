import SwiftUI
import Charts

enum TrainSessionState {
    case idle
    case selectingMode
    case selectingItem
    case selectingLevel
    case readyHold
    case countdown
    case measuring
    case drillComplete // Show graph after drill completion
    case resting
    case results
    case aborted
}

struct TrainTabView: View {
    @EnvironmentObject var templateStore: DrillTemplateStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var sessionResultStore: SessionResultStore
    @EnvironmentObject var runStore: DrillRunStore
    @EnvironmentObject var baselineStore: DrillBaselineStore
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var navigationCoordinator: AppNavigationCoordinator
    @ObservedObject var bluetoothManager: BluetoothManager
    
    @State private var sessionState: TrainSessionState = .idle
    @State private var selectedMode: TrainMode?
    @State private var selectedTemplate: DrillTemplate?
    @State private var isBaselineRun: Bool = false
    @State private var selectedWorkout: Workout?
    @State private var currentWorkoutItemIndex: Int = 0
    @State private var currentWorkoutRepIndex: Int = 0 // Track current rep within the current workout item
    @State private var currentWorkoutSessionId: UUID?
    @State private var holdProgress: Double = 0
    @AppStorage("countdownDuration") private var countdownDuration: Int = 5
    @State private var countdownValue: Int = 5
    @State private var restRemaining: Int = 0
    @State private var sessionSamples: [SensorSample] = []
    @State private var sessionStartTime: Date?
    @State private var isFirstWorkoutDrill: Bool = true // Track if this is the first drill in the workout
    @State private var restIsBetweenDrills: Bool = false // Track if rest is between drills (vs between reps)
    @State private var phaseLiveVariationValues: [UUID: Double] = [:] // Store selected values per phase ID
    
    @StateObject private var dataStreamVM: DataStreamViewModel
    
    let startIntent: AppNavigationCoordinator.TrainStartIntent?
    
    enum TrainMode {
        case drill
        case workout
        case liveMode
    }
    
    init(bluetoothManager: BluetoothManager, startIntent: AppNavigationCoordinator.TrainStartIntent? = nil) {
        self.bluetoothManager = bluetoothManager
        self.startIntent = startIntent
        _dataStreamVM = StateObject(wrappedValue: DataStreamViewModel(manager: bluetoothManager))
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.deepBlue.ignoresSafeArea()
                
                Group {
                    switch sessionState {
                    case .idle, .selectingMode:
                        ModeSelectionView(
                            onSelectMode: { mode in
                                selectedMode = mode
                                if mode == .liveMode {
                                    // For live mode, go directly to live mode view
                                    sessionState = .measuring
                                } else {
                                    sessionState = .selectingItem
                                }
                            }
                        )
                        
                    case .selectingItem:
                        ItemSelectionView(
                            mode: selectedMode!,
                            templateStore: templateStore,
                            workoutStore: workoutStore,
                            onSelectTemplate: { template, isBaseline in
                                selectedTemplate = template
                                isBaselineRun = isBaseline
                                
                                // Initialize live variation values for phases that need them
                                if template.probationStatus == .baselineCaptured && !isBaseline {
                                    for phase in template.effectivePhases where phase.liveVariation {
                                        if phase.forceType == .constant,
                                           let min = phase.constantForceN,
                                           let max = phase.constantForceMaxN,
                                           min <= max {
                                            phaseLiveVariationValues[phase.id] = (min + max) / 2.0
                                        } else if phase.forceType == .percentile,
                                                  let min = phase.forcePercentOfBaseline,
                                                  let max = phase.forcePercentOfBaselineMax,
                                                  min <= max {
                                            phaseLiveVariationValues[phase.id] = (min + max) / 2.0
                                        }
                                    }
                                }
                                sessionState = .readyHold
                            },
                            onSelectWorkout: { workout in
                                // Set up workout and navigate directly to readyHold
                                selectedWorkout = workout
                                currentWorkoutSessionId = UUID()
                                currentWorkoutItemIndex = 0
                                currentWorkoutRepIndex = 0
                                isFirstWorkoutDrill = true
                                restIsBetweenDrills = false
                                // Set the first template for display
                                if let firstItem = workout.items.first,
                                   let firstTemplate = templateStore.getTemplate(id: firstItem.drillId) {
                                    selectedTemplate = firstTemplate
                                }
                                sessionState = .readyHold
                            }
                        )
                        
                    case .selectingLevel:
                        // Level selection - transition to readyHold
                        // (Level selection may be handled in drill detail view)
                        ReadyHoldView(
                            progress: $holdProgress,
                            template: selectedTemplate,
                            isBaseline: isBaselineRun,
                            workout: nil,
                            workoutStore: workoutStore,
                            templateStore: templateStore,
                            phaseLiveVariationValues: $phaseLiveVariationValues,
                            onHoldComplete: {
                                sessionState = .countdown
                                countdownValue = countdownDuration
                            },
                            onCancel: {
                                resetToIdle()
                            }
                        )
                        
                    case .readyHold:
                        ReadyHoldView(
                            progress: $holdProgress,
                            template: selectedTemplate,
                            isBaseline: isBaselineRun,
                            workout: selectedWorkout,
                            workoutStore: workoutStore,
                            templateStore: templateStore,
                            phaseLiveVariationValues: $phaseLiveVariationValues,
                            onHoldComplete: {
                                // Only show countdown for first drill in workout or for single drills
                                if selectedMode == .workout && isFirstWorkoutDrill {
                                    sessionState = .countdown
                                    countdownValue = countdownDuration
                                } else if selectedMode == .drill {
                                    sessionState = .countdown
                                    countdownValue = countdownDuration
                                } else {
                                    // Skip countdown for subsequent workout drills
                                    startMeasuring()
                                }
                            },
                            onCancel: {
                                resetToIdle()
                            }
                        )
                        
                    case .countdown:
                        CountdownView(
                            value: $countdownValue,
                            onComplete: {
                                startMeasuring()
                            }
                        )
                        
                    case .measuring:
                        if selectedMode == .liveMode {
                            LiveModeView(
                                bluetoothManager: bluetoothManager,
                                dataStreamVM: dataStreamVM,
                                onStop: {
                                    // Stop data collection and reset to idle without saving
                                    resetToIdle()
                                }
                            )
                        } else {
                            MeasuringView(
                                bluetoothManager: bluetoothManager,
                                dataStreamVM: dataStreamVM,
                                template: selectedTemplate,
                                isBaseline: isBaselineRun,
                                workoutItem: selectedWorkout?.items[currentWorkoutItemIndex],
                                templateStore: templateStore,
                                onAbort: {
                                    abortSession()
                                },
                                onComplete: { samples in
                                    sessionSamples = samples
                                    if selectedMode == .workout {
                                        // Save DrillRun for this individual drill in the workout
                                        if let template = selectedTemplate {
                                            let sessionId = currentWorkoutSessionId ?? UUID()
                                            currentWorkoutSessionId = sessionId
                                            
                                            if let drillRun = convertSamplesToDrillRun(samples: samples, templateId: template.id, isBaseline: isBaselineRun, startTime: sessionStartTime) {
                                                runStore.saveRun(drillRun)
                                                
                                                // If this was a baseline run, create the baseline and mark template as baselineCaptured
                                                if isBaselineRun {
                                                    createBaseline(from: drillRun, templateId: template.id)
                                                }
                                            }
                                            
                                            if let drillResult = buildSessionResult(
                                                from: samples,
                                                mode: .drill,
                                                templateId: template.id,
                                                workout: selectedWorkout,
                                                sessionId: sessionId
                                            ) {
                                                sessionResultStore.addResult(drillResult)
                                            }
                                        }
                                        // For workouts, skip DrillCompleteView and go directly to rest or next drill
                                        handleWorkoutDrillComplete()
                                    } else {
                                        completeSession()
                                    }
                                }
                            )
                        }
                        
                    case .drillComplete:
                        DrillCompleteView(
                            samples: sessionSamples,
                            template: selectedTemplate,
                            onContinue: {
                                handleWorkoutDrillComplete()
                            }
                        )
                        
                    case .resting:
                        RestView(
                            remainingSeconds: $restRemaining,
                            nextDrillName: nextDrillName,
                            onSkip: {
                                handleRestComplete()
                            },
                            onComplete: {
                                handleRestComplete()
                            }
                        )
                        
                    case .results:
                        ResultsView(
                            sessionResult: currentSessionResult,
                            template: selectedTemplate,
                            workout: selectedWorkout,
                            workoutSessionId: currentWorkoutSessionId,
                            sessionResultStore: sessionResultStore,
                            templateStore: templateStore,
                            workoutStore: workoutStore,
                            onDone: {
                                resetToIdle()
                            },
                            onStartAgain: {
                                resetToIdle()
                            }
                        )
                        
                    case .aborted:
                        AbortedView(onReturn: {
                            resetToIdle()
                        })
                    }
                }
            }
            .drukNavigationTitle("Train")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ProfileIndicator(profileStore: profileStore)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    BluetoothConnectionIndicator(bluetoothManager: bluetoothManager)
                        .accessibilityLabel("Bluetooth connection status")
                }
            }
        }
        .onAppear {
            // Process start intent when view appears
            if let intent = startIntent {
                processStartIntent(intent)
            }
            updateSessionActiveState()
        }
        .onChange(of: startIntent) { newIntent in
            // Handle intent changes (e.g., when navigating from another tab)
            if let intent = newIntent {
                processStartIntent(intent)
            }
        }
        .onChange(of: sessionState) { _, _ in
            updateSessionActiveState()
        }
    }
    
    /// Update the navigation coordinator's session active state based on current session state
    private func updateSessionActiveState() {
        // Hide tab bar during active session (after countdown starts, during measuring, drill complete, resting, or results)
        // Show tab bar when idle, selecting, readyHold (before starting), or aborted
        let shouldHideTabBar: Bool
        switch sessionState {
        case .idle, .selectingMode, .selectingItem, .selectingLevel, .readyHold, .aborted:
            shouldHideTabBar = false
        case .countdown, .measuring, .drillComplete, .resting, .results:
            shouldHideTabBar = true
        }
        navigationCoordinator.isSessionActive = shouldHideTabBar
    }
    
    /// Process a start intent from DrillDetailView or WorkoutDetailView
    /// This implements deep-linking: "Start in Train" button triggers this
    private func processStartIntent(_ intent: AppNavigationCoordinator.TrainStartIntent) {
        switch intent {
        case .drillTemplate(let template, let isBaseline):
            selectedMode = .drill
            selectedTemplate = template
            isBaselineRun = isBaseline
            // Drill templates skip level selection, go directly to Hold-to-Start
            sessionState = .readyHold
            
        case .workout(let workout):
            selectedMode = .workout
            selectedWorkout = workout
            currentWorkoutItemIndex = 0
            currentWorkoutRepIndex = 0
            currentWorkoutSessionId = UUID()
            isFirstWorkoutDrill = true
            restIsBetweenDrills = false
            // Workouts skip level selection, go directly to Hold-to-Start
            sessionState = .readyHold
        }
        
        // Clear the intent after processing
        navigationCoordinator.clearStartIntent()
    }
    
    private var nextDrillName: String? {
        guard let workout = selectedWorkout else {
            return nil
        }
        
        // Look ahead to find the next drill (skip rest periods)
        var searchIndex = currentWorkoutItemIndex
        if restIsBetweenDrills {
            // If we're currently showing rest between drills, we're already past the current item
            searchIndex += 1
        }
        
        while searchIndex < workout.items.count {
            let item = workout.items[searchIndex]
            
            // Skip rest periods
            if isRestPeriod(item: item) {
                searchIndex += 1
                continue
            }
            
            // Found a drill
            if let template = templateStore.getTemplate(id: item.drillId) {
                return template.name
            }
            searchIndex += 1
        }
        
        return nil
    }
    
    private var currentSessionResult: SessionResult? {
        guard let mode = selectedMode else { return nil }
        
        // Calculate proper metrics from encoder data
        let metrics: SessionMetrics
        if !sessionSamples.isEmpty, let phaseMetrics = EncoderConversions.analyzePhase(
            samples: sessionSamples,
            phaseType: selectedTemplate?.type ?? .speedDrill
        ) {
            metrics = SessionMetrics(
                peakForce: phaseMetrics.peakForce,
                averageForce: phaseMetrics.averageForce,
                duration: phaseMetrics.duration
            )
        } else {
            // Fallback: calculate basic metrics
            let duration = sessionStartTime.map { Date().timeIntervalSince($0) }
            metrics = SessionMetrics(
                peakForce: nil,
                averageForce: nil,
                duration: duration
            )
        }
        
        if mode == .workout, currentWorkoutSessionId == nil {
            currentWorkoutSessionId = UUID()
        }
        
        return SessionResult(
            mode: mode == .drill ? .drill : .workout,
            drillId: selectedTemplate?.id,
            workoutId: selectedWorkout?.id,
            workoutSessionId: mode == .workout ? currentWorkoutSessionId : nil,
            workoutNameSnapshot: selectedWorkout?.name,
            levelUsed: nil,
            rawESP32Data: sessionSamples,
            derivedMetrics: metrics
        )
    }
    
    private func startMeasuring() {
        if selectedMode == .workout, currentWorkoutSessionId == nil {
            currentWorkoutSessionId = UUID()
        }
        sessionStartTime = Date()
        sessionSamples = []
        bluetoothManager.send("START")
        dataStreamVM.start()
        sessionState = .measuring
    }
    
    private func handleWorkoutDrillComplete() {
        guard let workout = selectedWorkout else { return }
        
        let currentItem = workout.items[currentWorkoutItemIndex]
        
        // Check if we need to do more reps of this drill
        currentWorkoutRepIndex += 1
        if currentWorkoutRepIndex < currentItem.reps {
            // More reps to do - show rest if needed, then continue to next rep
            // Rest only happens BETWEEN reps, not after the last rep
            restIsBetweenDrills = false
            if currentItem.restSeconds > 0 {
                restRemaining = currentItem.restSeconds
                sessionState = .resting
            } else {
                // No rest, immediately start next rep
                proceedToNextRep()
            }
        } else {
            // All reps done for this item - move to next item
            // NO REST after the last rep - rest only happens between reps
            currentWorkoutRepIndex = 0
            proceedToNextDrill()
        }
    }
    
    private func handleRestComplete() {
        if restIsBetweenDrills {
            // Rest was between drills - move to next drill
            proceedToNextDrill()
        } else {
            // Rest was between reps - continue with next rep
            proceedToNextRep()
        }
    }
    
    private func proceedToNextRep() {
        // Start the next rep of the current drill immediately (no countdown/hold)
        isFirstWorkoutDrill = false
        startMeasuring()
    }
    
    private func proceedToNextDrill() {
        guard let workout = selectedWorkout else { return }
        
        currentWorkoutItemIndex += 1
        currentWorkoutRepIndex = 0
        restIsBetweenDrills = false
        
        if currentWorkoutItemIndex < workout.items.count {
            let item = workout.items[currentWorkoutItemIndex]
            
            // Check if this is a rest period
            if isRestPeriod(item: item) {
                restRemaining = item.restSeconds
                restIsBetweenDrills = true
                sessionState = .resting
            } else {
                let drillId = item.drillId
                if let template = templateStore.getTemplate(id: drillId) {
                    selectedTemplate = template
                    isBaselineRun = false
                    isFirstWorkoutDrill = false // Not the first drill anymore
                    // Skip readyHold and countdown - go directly to measuring
                    proceedToNextRep()
                } else {
                    // Skip missing drill and continue
                    proceedToNextDrill()
                }
            }
        } else {
            completeSession()
        }
    }
    
    private func isRestPeriod(item: WorkoutItem) -> Bool {
        let restUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return item.drillId == restUUID || (item.reps == 0 && templateStore.getTemplate(id: item.drillId) == nil)
    }
    
    private func completeSession() {
        bluetoothManager.send("STOP")
        dataStreamVM.stop()
        
        if let result = currentSessionResult {
            sessionResultStore.addResult(result)
            
            // Also save as DrillRun if it's a drill session
            if result.mode == .drill, let templateId = result.drillId {
                // Use samples directly (more reliable than converting from SessionResult)
                if let drillRun = convertSamplesToDrillRun(samples: sessionSamples, templateId: templateId, isBaseline: isBaselineRun, startTime: sessionStartTime) {
                    runStore.saveRun(drillRun)
                    
                    // If this was a baseline run, create the baseline and mark template as baselineCaptured
                    if isBaselineRun {
                        createBaseline(from: drillRun, templateId: templateId)
                    }
                }
            }
        }
        
        sessionState = .results
    }
    
    /// Create a baseline from a baseline run and mark the template as baselineCaptured
    private func createBaseline(from run: DrillRun, templateId: UUID) {
        let velocityProfile = EnforcementPlanGenerator.createBaselineVelocityProfile(
            from: run.results.velocityTimeSeries
        )
        
        let baseline = DrillBaseline(
            templateId: templateId,
            baselineRunId: run.id,
            baselineDistanceMeters: run.results.distanceMeters,
            baselineTimeSeconds: run.results.durationSeconds,
            baselineAvgSpeedMps: run.results.avgSpeedMps,
            baselinePeakSpeedMps: run.results.peakSpeedMps,
            baselinePowerEstimateW: run.results.powerEstimateW,
            baselineForceEstimateN: run.results.forceEstimateN,
            baselineVelocityProfileSummary: velocityProfile
        )
        
        baselineStore.saveBaseline(baseline)
        templateStore.markBaselineCaptured(for: templateId)
    }
    
    private func buildSessionResult(
        from samples: [SensorSample],
        mode: SessionMode,
        templateId: UUID?,
        workout: Workout?,
        sessionId: UUID?
    ) -> SessionResult? {
        guard !samples.isEmpty else { return nil }
        
        // Calculate proper metrics from encoder data
        let drillType: DrillType
        if let templateId = templateId, let template = templateStore.getTemplate(id: templateId) {
            drillType = template.type
        } else {
            drillType = .speedDrill
        }
        
        let metrics: SessionMetrics
        if let phaseMetrics = EncoderConversions.analyzePhase(
            samples: samples,
            phaseType: drillType
        ) {
            metrics = SessionMetrics(
                peakForce: phaseMetrics.peakForce,
                averageForce: phaseMetrics.averageForce,
                duration: phaseMetrics.duration
            )
        } else {
            // Fallback: calculate basic duration
            let duration: TimeInterval
            if let start = sessionStartTime {
                duration = max(0, samples.last?.timestamp.timeIntervalSince(start) ?? 0)
            } else if let first = samples.first, let last = samples.last {
                duration = max(0, last.timestamp.timeIntervalSince(first.timestamp))
            } else {
                duration = 0
            }
            
            metrics = SessionMetrics(
                peakForce: nil,
                averageForce: nil,
                duration: duration
            )
        }
        
        return SessionResult(
            mode: mode,
            drillId: templateId,
            workoutId: workout?.id,
            workoutSessionId: sessionId,
            workoutNameSnapshot: workout?.name,
            levelUsed: nil,
            rawESP32Data: samples,
            derivedMetrics: metrics
        )
    }
    
    /// Converts SensorSample array directly to DrillRun (for workout drills)
    private func convertSamplesToDrillRun(samples: [SensorSample], templateId: UUID, isBaseline: Bool, startTime: Date?) -> DrillRun? {
        // Handle empty samples - still create a DrillRun with zero/default values
        if samples.isEmpty {
            let duration: Double = 0 // Default duration when no samples
            let timestamp = startTime ?? Date()
            
            let runResults = RunResults(
                distanceMeters: 0,
                durationSeconds: duration,
                avgSpeedMps: 0,
                peakSpeedMps: 0,
                powerEstimateW: nil,
                forceEstimateN: nil,
                velocityTimeSeries: []
            )
            
            let runMode: RunMode = isBaseline ? .baselineNoEnforcement : .enforced
            
            return DrillRun(
                templateId: templateId,
                timestamp: timestamp,
                runMode: runMode,
                requestedPlan: nil,
                results: runResults,
                notes: nil,
                derivedComparisons: nil
            )
        }
        
        let firstSample = samples.first!
        let lastSample = samples.last!
        let duration = lastSample.timestamp.timeIntervalSince(firstSample.timestamp)
        guard duration > 0 else {
            // If duration is 0 or negative, still create a DrillRun with minimal data
            let runResults = RunResults(
                distanceMeters: 0,
                durationSeconds: 0,
                avgSpeedMps: 0,
                peakSpeedMps: 0,
                powerEstimateW: nil,
                forceEstimateN: samples.isEmpty ? nil : samples.map { $0.value }.reduce(0, +) / Double(samples.count),
                velocityTimeSeries: []
            )
            
            let runMode: RunMode = isBaseline ? .baselineNoEnforcement : .enforced
            
            return DrillRun(
                templateId: templateId,
                timestamp: startTime ?? Date(),
                runMode: runMode,
                requestedPlan: nil,
                results: runResults,
                notes: nil,
                derivedComparisons: nil
            )
        }
        
        // Convert SensorSample to VelocitySample
        let velocitySamples = samples.enumerated().map { index, sample -> VelocitySample in
            // Estimate velocity from force value
            // For now, treat value as velocity directly (or apply conversion)
            let estimatedVelocity = max(0, sample.value)
            
            // Calculate cumulative distance
            var distance: Double = 0
            if index > 0 {
                let timeDiff = sample.timestamp.timeIntervalSince(samples[index - 1].timestamp)
                let prevVelocity = max(0, samples[index - 1].value)
                distance = (prevVelocity + estimatedVelocity) / 2.0 * timeDiff
            }
            
            return VelocitySample(
                timestamp: sample.timestamp,
                velocityMps: estimatedVelocity,
                distanceMeters: nil // Will calculate cumulative below
            )
        }
        
        // Calculate cumulative distances
        var cumulativeDistance: Double = 0
        let updatedVelocitySamples = velocitySamples.enumerated().map { index, sample -> VelocitySample in
            if index > 0 {
                let timeDiff = sample.timestamp.timeIntervalSince(velocitySamples[index - 1].timestamp)
                let avgVelocity = (sample.velocityMps + velocitySamples[index - 1].velocityMps) / 2.0
                cumulativeDistance += avgVelocity * timeDiff
            }
            return VelocitySample(
                timestamp: sample.timestamp,
                velocityMps: sample.velocityMps,
                distanceMeters: cumulativeDistance
            )
        }
        
        let velocities = updatedVelocitySamples.map { $0.velocityMps }
        let avgSpeed = velocities.reduce(0, +) / Double(velocities.count)
        let peakSpeed = velocities.max() ?? 0
        let totalDistance = cumulativeDistance > 0 ? cumulativeDistance : avgSpeed * duration
        
        let runResults = RunResults(
            distanceMeters: totalDistance,
            durationSeconds: duration,
            avgSpeedMps: avgSpeed,
            peakSpeedMps: peakSpeed,
            powerEstimateW: nil,
            forceEstimateN: samples.map { $0.value }.reduce(0, +) / Double(samples.count),
            velocityTimeSeries: updatedVelocitySamples
        )
        
        let runMode: RunMode = isBaseline ? .baselineNoEnforcement : .enforced
        
        return DrillRun(
            templateId: templateId,
            timestamp: startTime ?? Date(),
            runMode: runMode,
            requestedPlan: nil,
            results: runResults,
            notes: nil,
            derivedComparisons: nil
        )
    }
    
    /// Converts a SessionResult to a DrillRun
    /// This allows drill runs to appear in the Progress tab's Drills section
    private func convertSessionResultToDrillRun(result: SessionResult, templateId: UUID, isBaseline: Bool) -> DrillRun? {
        guard let duration = result.derivedMetrics.duration, duration > 0 else {
            return nil
        }
        
        let samples = result.rawESP32Data
        guard !samples.isEmpty else {
            return nil
        }
        
        // Convert SensorSample (force) to VelocitySample
        // For now, we'll estimate velocity from force values
        // Assuming force values can be converted to velocity using a scaling factor
        // In a real implementation, this would use physics calculations
        let velocitySamples = samples.enumerated().map { index, sample in
            // Estimate velocity: assume velocity is proportional to force
            // Using a simple conversion: velocity ≈ force * scaling_factor
            // For now, treat the force value as velocity directly (if it's already velocity-like)
            // Otherwise, apply a conversion factor
            let estimatedVelocity = sample.value // Assuming value is already velocity-like, or apply conversion
            
            // Calculate distance increment (simplified: assume constant velocity over sample interval)
            let timeInterval = index < samples.count - 1 
                ? samples[index + 1].timestamp.timeIntervalSince(sample.timestamp)
                : duration / Double(samples.count)
            
            return VelocitySample(
                timestamp: sample.timestamp,
                velocityMps: max(0, estimatedVelocity), // Ensure non-negative
                distanceMeters: nil // Will calculate total distance below
            )
        }
        
        // Calculate total distance from velocity samples
        var totalDistance: Double = 0
        var cumulativeDistance: Double = 0
        let updatedVelocitySamples = velocitySamples.enumerated().map { index, sample -> VelocitySample in
            if index > 0 {
                let timeDiff = sample.timestamp.timeIntervalSince(velocitySamples[index - 1].timestamp)
                cumulativeDistance += sample.velocityMps * timeDiff
            }
            return VelocitySample(
                timestamp: sample.timestamp,
                velocityMps: sample.velocityMps,
                distanceMeters: cumulativeDistance
            )
        }
        totalDistance = cumulativeDistance
        
        // Calculate average and peak speeds
        let velocities = updatedVelocitySamples.map { $0.velocityMps }
        let avgSpeed = velocities.reduce(0, +) / Double(velocities.count)
        let peakSpeed = velocities.max() ?? 0
        
        // If we don't have distance, estimate it from average speed and duration
        if totalDistance == 0 {
            totalDistance = avgSpeed * duration
        }
        
        // Create RunResults
        let runResults = RunResults(
            distanceMeters: totalDistance,
            durationSeconds: duration,
            avgSpeedMps: avgSpeed,
            peakSpeedMps: peakSpeed,
            powerEstimateW: nil, // Could calculate from force and velocity
            forceEstimateN: result.derivedMetrics.averageForce,
            velocityTimeSeries: updatedVelocitySamples
        )
        
        // Determine run mode
        let runMode: RunMode = isBaseline ? .baselineNoEnforcement : .enforced
        
        // Create DrillRun
        let drillRun = DrillRun(
            templateId: templateId,
            timestamp: result.date,
            runMode: runMode,
            requestedPlan: nil,
            results: runResults,
            notes: nil,
            derivedComparisons: nil
        )
        
        return drillRun
    }
    
    private func abortSession() {
        bluetoothManager.send("STOP")
        dataStreamVM.stop()
        currentWorkoutSessionId = nil
        sessionState = .aborted
    }
    
    private func resetToIdle() {
        sessionState = .idle
        selectedMode = nil
        selectedTemplate = nil
        selectedWorkout = nil
        currentWorkoutSessionId = nil
        isBaselineRun = false
        currentWorkoutItemIndex = 0
        currentWorkoutRepIndex = 0
        isFirstWorkoutDrill = true
        restIsBetweenDrills = false
        holdProgress = 0
        countdownValue = 5
        restRemaining = 0
        sessionSamples = []
        sessionStartTime = nil
    }
}

struct ModeSelectionView: View {
    let onSelectMode: (TrainTabView.TrainMode) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: Theme.Spacing.md) {
                Text("WHAT WOULD YOU LIKE TO DO?")
                    .font(Theme.Typography.drukTitle)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                
                Text("Choose your training mode")
                    .font(Theme.Typography.exo2Callout)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.bottom, Theme.Spacing.xxl)
            
            VStack(spacing: Theme.Spacing.md + 4) {
                Button {
                    HapticFeedback.buttonPress()
                    onSelectMode(.drill)
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.2))
                                .frame(width: 56, height: 56)
                            
                            Image(systemName: "figure.run")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SINGLE DRILL")
                                .font(Theme.Typography.drukSection)
                                .foregroundColor(.white)
                            
                            Text("Focus on one exercise")
                                .font(Theme.Typography.exo2Subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.lg)
                    .background(
                        LinearGradient(
                            colors: [Theme.orange, Theme.secondaryAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(Theme.CornerRadius.large)
                    .shadow(color: Theme.orange.opacity(0.3), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                
                Button {
                    HapticFeedback.buttonPress()
                    onSelectMode(.workout)
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.15))
                                .frame(width: 56, height: 56)
                            
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WORKOUT")
                                .font(Theme.Typography.drukSection)
                                .foregroundColor(.white)
                            
                            Text("Complete a full routine")
                                .font(Theme.Typography.exo2Subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                
                Button {
                    HapticFeedback.buttonPress()
                    onSelectMode(.liveMode)
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.15))
                                .frame(width: 56, height: 56)
                            
                            Text("∞")
                                .font(.system(size: 32, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LIVE MODE")
                                .font(Theme.Typography.drukSection)
                                .foregroundColor(.white)
                            
                            Text("Manual force control")
                                .font(Theme.Typography.exo2Subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            
            Spacer()
        }
    }
}

struct ItemSelectionView: View {
    let mode: TrainTabView.TrainMode
    @ObservedObject var templateStore: DrillTemplateStore
    @ObservedObject var workoutStore: WorkoutStore
    let onSelectTemplate: (DrillTemplate, Bool) -> Void
    let onSelectWorkout: (Workout) -> Void
    
    @State private var showProbationaryDrills: Bool = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.md) {
                if mode == .drill {
                    // Toggle for probationary drills
                    HStack {
                        Text("Probationary Drills")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                        Spacer()
                        Toggle("", isOn: $showProbationaryDrills)
                            .labelsHidden()
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(.white.opacity(0.1))
                    .cornerRadius(Theme.CornerRadius.small)
                    .padding(.horizontal, Theme.Spacing.md)
                    
                    // Drill templates
                    ForEach(filteredTemplates) { template in
                        Button {
                            let isBaseline = template.probationStatus == .probationary
                            onSelectTemplate(template, isBaseline)
                        } label: {
                            DrillTemplateSelectionRow(template: template)
                        }
                    }
                } else {
                    ForEach(workoutStore.workouts) { workout in
                        Button {
                            onSelectWorkout(workout)
                        } label: {
                            WorkoutSelectionRow(workout: workout)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.md)
        }
    }
    
    private var filteredTemplates: [DrillTemplate] {
        let templates = templateStore.fetchTemplates()
        if showProbationaryDrills {
            // Show only probationary drills
            return templates.filter { $0.probationStatus == .probationary }
        } else {
            // Show only baseline-captured (ready) drills
            return templates.filter { $0.probationStatus == .baselineCaptured }
        }
    }
}

struct DrillTemplateSelectionRow: View {
    let template: DrillTemplate
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Type indicator
            RoundedRectangle(cornerRadius: 6)
                .fill(template.type == .speedDrill ? Theme.orange.opacity(0.6) : Theme.orange.opacity(0.6))
                .frame(width: 4)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(template.name.uppercased())
                        .font(Theme.Typography.drukDrillName)
                        .foregroundColor(.white)
                    
                    if template.probationStatus == .probationary {
                        Text("BASELINE")
                            .font(Theme.Typography.exo2Caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                
                HStack(spacing: Theme.Spacing.sm) {
                    Text(template.type.rawValue)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.1))
                        .cornerRadius(6)
                    
                    if let time = template.targetTimeSeconds {
                        Text("\(Int(time))s")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.65))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1))
                            .cornerRadius(6)
                    }
                    
                    if template.isResist {
                        Text("Resist")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    if template.isAssist {
                        Text("Assist")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

struct WorkoutSelectionRow: View {
    let workout: Workout
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Type indicator - matching drill style
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.orange.opacity(0.6))
                .frame(width: 4)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(workout.name.uppercased())
                    .font(Theme.Typography.drukDrillName)
                    .foregroundColor(.white)
                
                HStack(spacing: Theme.Spacing.sm) {
                    Text("WORKOUT")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.1))
                        .cornerRadius(6)
                    
                    Text("\(workout.items.count) drill\(workout.items.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.1))
                        .cornerRadius(6)
                    
                    if workout.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

struct LevelSelectionView: View {
    @Binding var level: Int
    let onConfirm: () -> Void
    
    var body: some View {
        VStack(spacing: Theme.Spacing.xl + 8) {
            VStack(spacing: Theme.Spacing.sm) {
                Text("CHOOSE DIFFICULTY")
                    .font(Theme.Typography.drukTitle)
                    .foregroundColor(.white)
                
                Text("Select your level")
                    .font(Theme.Typography.exo2Subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.top, Theme.Spacing.xl)
            
            Picker("Level", selection: $level) {
                ForEach(1...5, id: \.self) { lvl in
                    Text("\(lvl)").tag(lvl)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.lg)
            .onChange(of: level) {
                HapticFeedback.cardTap()
            }
            
            Button {
                HapticFeedback.buttonPress()
                onConfirm()
            } label: {
                Text("START")
                    .font(Theme.Typography.exo2Headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(
                            colors: [Theme.orange, Theme.secondaryAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(Theme.CornerRadius.medium)
                    .shadow(color: Theme.orange.opacity(0.4), radius: 8, x: 0, y: 4)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.md)
            
            Spacer()
        }
    }
}

struct ReadyHoldView: View {
    @Binding var progress: Double
    let template: DrillTemplate?
    let isBaseline: Bool
    let workout: Workout?
    let workoutStore: WorkoutStore?
    let templateStore: DrillTemplateStore?
    @Binding var phaseLiveVariationValues: [UUID: Double]
    let onHoldComplete: () -> Void
    let onCancel: () -> Void
    
    @State private var isHolding = false
    @EnvironmentObject var profileStore: ProfileStore
    
    private var restUUID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
    
    private func isRestPeriod(item: WorkoutItem) -> Bool {
        guard let templateStore = templateStore else { return false }
        return item.drillId == restUUID || (item.reps == 0 && templateStore.getTemplate(id: item.drillId) == nil)
    }
    
    // Helper function to get default value (midpoint) for a phase with live variation
    private func getDefaultValue(for phase: DrillPhase) -> Double {
        if phase.forceType == .constant {
            if let min = phase.constantForceN, let max = phase.constantForceMaxN, min <= max {
                return (min + max) / 2.0
            }
        } else {
            if let min = phase.forcePercentOfBaseline, let max = phase.forcePercentOfBaselineMax, min <= max {
                return (min + max) / 2.0
            }
        }
        // Fallback: return midpoint of reasonable defaults
        return phase.forceType == .constant ? 50.0 : 90.0
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Workout Name Section (if workout)
            if let workout = workout {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(workout.name.uppercased())
                        .font(Theme.Typography.drukDrillName)
                        .foregroundColor(.white)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.md)
                }
            }
            
            // Drill Details Section (only if no workout)
            if workout == nil, let template = template {
                VStack(spacing: 0) {
                    // Fixed Header
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.name.uppercased())
                                    .font(Theme.Typography.drukDrillName)
                                    .foregroundColor(.white)
                                
                                let effectivePhases = template.effectivePhases
                                if effectivePhases.count > 1 {
                                    Text("\(effectivePhases.count) Phases")
                                        .font(Theme.Typography.exo2Label)
                                        .foregroundColor(.white.opacity(0.7))
                                } else {
                                    if let phase = effectivePhases.first {
                                        Text(phase.drillType.rawValue)
                                            .font(Theme.Typography.exo2Label)
                                            .foregroundColor(.white.opacity(0.7))
                                    } else {
                                        Text(template.type.rawValue)
                                            .font(Theme.Typography.exo2Label)
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            ProbationStatusPill(status: template.probationStatus)
                        }
                        
                        if isBaseline {
                            HStack {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                                Text("BASELINE RUN")
                                    .font(Theme.Typography.exo2Caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.sm)
                    
                    // Scrollable Phase Information Section
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            let effectivePhases = template.effectivePhases
                            
                            if effectivePhases.count > 1 {
                                Text("PHASES")
                                    .font(Theme.Typography.exo2Caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white.opacity(0.6))
                                
                                ForEach(Array(effectivePhases.enumerated()), id: \.element.id) { index, phase in
                                    TrainPhaseDetailCard(phase: phase, phaseNumber: index + 1, totalPhases: effectivePhases.count)
                                    
                                    // Show slider if phase has live variation and baseline is collected
                                    if phase.liveVariation && template.probationStatus == .baselineCaptured && !isBaseline {
                                        LiveVariationSliderCard(
                                            phase: phase,
                                            selectedValue: Binding(
                                                get: { phaseLiveVariationValues[phase.id] ?? getDefaultValue(for: phase) },
                                                set: { phaseLiveVariationValues[phase.id] = $0 }
                                            )
                                        )
                                    }
                                }
                            } else if let phase = effectivePhases.first {
                                Text("DETAILS")
                                    .font(Theme.Typography.exo2Caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white.opacity(0.6))
                                
                                TrainPhaseDetailCard(phase: phase, phaseNumber: 1, totalPhases: 1)
                                
                                // Show slider if phase has live variation and baseline is collected
                                if phase.liveVariation && template.probationStatus == .baselineCaptured && !isBaseline {
                                    LiveVariationSliderCard(
                                        phase: phase,
                                        selectedValue: Binding(
                                            get: { phaseLiveVariationValues[phase.id] ?? getDefaultValue(for: phase) },
                                            set: { phaseLiveVariationValues[phase.id] = $0 }
                                        )
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.bottom, Theme.Spacing.md)
                    }
                    .frame(maxHeight: 400) // Fixed max height so only this section scrolls
                }
            }
            
            // Workout Program - Scrollable center area
            if let workout = workout, let templateStore = templateStore {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        ForEach(workout.items) { item in
                            if isRestPeriod(item: item) {
                                ReadyHoldRestPeriodRow(item: item)
                                    .padding(.horizontal, Theme.Spacing.md)
                            } else if let template = templateStore.getTemplate(id: item.drillId) {
                                ReadyHoldWorkoutItemRow(item: item, template: template)
                                    .padding(.horizontal, Theme.Spacing.md)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            
            // Hold to Start Button - Smaller and on the side
            HStack {
                Spacer()
                
                    VStack(spacing: Theme.Spacing.sm) {
                        Text("HOLD TO START")
                        .font(Theme.Typography.drukSection)
                        .foregroundColor(.white.opacity(0.8))
                    
                    HoldButton(
                        progress: $progress,
                        isHolding: $isHolding,
                        onPress: {
                            // Button handles its own press
                        },
                        onRelease: {
                            // Button handles its own release
                        },
                        onComplete: {
                            onHoldComplete()
                        }
                    )
                    .frame(width: 100, height: 100)
                }
                .padding(.trailing, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xl)
            }
            
            // Cancel button
            Button(role: .cancel) {
                onCancel()
            } label: {
                Text("CANCEL")
                    .foregroundColor(.white.opacity(0.7))
                    .font(Theme.Typography.exo2Subheadline)
            }
            .padding(.bottom, Theme.Spacing.md)
        }
    }
    
    private func targetModeDescription(_ template: DrillTemplate) -> String {
        switch template.targetMode {
        case .distanceOnly:
            return "Distance Only"
        case .timeOnly:
            return "Time Only"
        case .distanceAndTime:
            return "Distance + Time"
        case .speedPercentOfBaseline:
            if let percent = template.speedPercentOfBaseline {
                return String(format: "%.0f%% of baseline speed", percent)
            }
            return "Speed % of Baseline"
        case .forcePercentOfBaseline:
            if let percent = template.forcePercentOfBaseline {
                return String(format: "%.0f%% of baseline force", percent)
            }
            return "Force % of Baseline"
        }
    }
    
    private func compactTargetModeDescription(_ template: DrillTemplate) -> String {
        switch template.targetMode {
        case .distanceOnly:
            return "Distance"
        case .timeOnly:
            return "Time"
        case .distanceAndTime:
            return "Dist+Time"
        case .speedPercentOfBaseline:
            if let percent = template.speedPercentOfBaseline {
                return String(format: "%.0f%% Speed", percent)
            }
            return "Speed %"
        case .forcePercentOfBaseline:
            if let percent = template.forcePercentOfBaseline {
                return String(format: "%.0f%% Force", percent)
            }
            return "Force %"
        }
    }
    
    private func enforcementDescription(_ template: DrillTemplate) -> String {
        switch template.enforcementIntent {
        case .none:
            return "No Enforcement"
        case .velocityCurve:
            return "Velocity Curve"
        case .torqueEnvelope:
            return "Torque Envelope"
        case .hybrid:
            return "Hybrid"
        }
    }
}

// Styled workout item rows for ReadyHoldView (deep blue background)
struct ReadyHoldWorkoutItemRow: View {
    let item: WorkoutItem
    let template: DrillTemplate
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(template.name)
                    .font(Theme.Typography.exo2Subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                
                HStack(spacing: Theme.Spacing.md) {
                    Text("\(item.reps) rep\(item.reps == 1 ? "" : "s")")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundColor(.white.opacity(0.7))
                    
                    if item.restSeconds > 0 {
                        Text("\(item.restSeconds)s rest")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    if let level = item.level {
                        Text("Level \(level)")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

struct ReadyHoldRestPeriodRow: View {
    let item: WorkoutItem
    
    var body: some View {
        HStack {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "timer")
                    .foregroundColor(Theme.orange)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Rest Period")
                        .font(Theme.Typography.exo2Subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    Text("\(item.restSeconds) seconds")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                        .stroke(Theme.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct CountdownView: View {
    @Binding var value: Int
    let onComplete: () -> Void
    
    @State private var timer: Timer?
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.orange.opacity(0.2))
                .frame(width: 200, height: 200)
            
            Text("\(value)")
                .font(.system(size: 80, weight: .bold))
                .foregroundColor(.white)
        }
        .onAppear {
            startCountdown()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func startCountdown() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if value > 1 {
                value -= 1
                // Haptic feedback could be added here
            } else {
                timer.invalidate()
                self.timer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onComplete()
                }
            }
        }
    }
}

struct MeasuringView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @ObservedObject var dataStreamVM: DataStreamViewModel
    let template: DrillTemplate?
    let isBaseline: Bool
    let workoutItem: WorkoutItem?
    @ObservedObject var templateStore: DrillTemplateStore
    @EnvironmentObject var profileStore: ProfileStore
    let onAbort: () -> Void
    let onComplete: ([SensorSample]) -> Void
    
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var collectedSamples: [SensorSample] = []
    @State private var measurementStartTime: Date?
    @State private var lastDataTime: Date?
    @State private var initialEncoderCount: Double = 0
    @State private var cumulativeDistance: Double = 0 // Distance in meters
    
    // Multi-phase support
    @State private var currentPhaseIndex: Int = 0
    @State private var phaseStartTime: Date?
    @State private var phaseElapsedTime: TimeInterval = 0
    @State private var allPhaseSamples: [SensorSample] = []
    
    // Encoder constants (from Arduino code)
    private let COUNTS_PER_REV: Double = 2400.0
    private let SPOOL_RADIUS_M: Double = 0.1016 // 4 inches in meters
    
    // Get effective phases (handles both multi-phase and legacy single-phase drills)
    private var phases: [DrillPhase] {
        if let template = template {
            return template.effectivePhases
        } else if let item = workoutItem,
                  let template = templateStore.getTemplate(id: item.drillId) {
            return template.effectivePhases
        }
        return [DrillPhase()]
    }
    
    private var currentPhase: DrillPhase {
        guard currentPhaseIndex < phases.count else {
            return phases.first ?? DrillPhase()
        }
        return phases[currentPhaseIndex]
    }
    
    private var isMultiPhase: Bool {
        phases.count > 1
    }
    
    private var isSpeedDrill: Bool {
        currentPhase.drillType == .speedDrill
    }
    
    private var targetDistanceMeters: Double? {
        currentPhase.distanceMeters
    }
    
    private var duration: Int {
        if isSpeedDrill {
            // For speed drills, duration is not used for stopping, but shown as reference
            return 10
        }
        return Int(currentPhase.targetTimeSeconds ?? 10.0)
    }
    
    // Convert encoder counts to distance in meters
    private func countsToDistance(_ counts: Double) -> Double {
        let revolutions = counts / COUNTS_PER_REV
        return revolutions * 2 * .pi * SPOOL_RADIUS_M
    }
    
    private var drillName: String {
        template?.name ?? "Drill"
    }
    
    // Generate flat line data if no samples
    private var chartData: [SensorSample] {
        if collectedSamples.isEmpty && dataStreamVM.windowedSamples.isEmpty {
            // Create flat line at 0
            let startTime = measurementStartTime ?? Date().addingTimeInterval(-Double(duration))
            return (0..<max(2, duration * 10)).map { index in
                SensorSample(
                    timestamp: startTime.addingTimeInterval(Double(index) * 0.1),
                    value: 0.0
                )
            }
        }
        // Use collected samples if available, otherwise use windowed samples
        return collectedSamples.isEmpty ? dataStreamVM.windowedSamples : collectedSamples
    }
    
    private func startMeasuring() {
        elapsedTime = 0
        phaseElapsedTime = 0
        collectedSamples = []
        allPhaseSamples = []
        cumulativeDistance = 0
        currentPhaseIndex = 0
        measurementStartTime = Date()
        phaseStartTime = Date()
        lastDataTime = Date()
        
        // Get initial encoder count for speed drills
        if isSpeedDrill && !dataStreamVM.windowedSamples.isEmpty {
            initialEncoderCount = dataStreamVM.windowedSamples.last?.value ?? 0
        }
        
        // Start collecting all samples from the data stream
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            Task { @MainActor in
                elapsedTime += 0.1
                phaseElapsedTime += 0.1
                
                // Collect ALL samples that have arrived since measurement started
                // Filter samples to only include those from this measurement period
                if let startTime = measurementStartTime {
                    let relevantSamples = dataStreamVM.windowedSamples.filter { sample in
                        sample.timestamp >= startTime
                    }
                    collectedSamples = relevantSamples
                    
                    // Update last data time if we have new samples
                    if !relevantSamples.isEmpty {
                        lastDataTime = relevantSamples.last?.timestamp ?? Date()
                    }
                } else {
                    // Fallback: collect recent samples
                    collectedSamples = Array(dataStreamVM.windowedSamples.suffix(1000))
                }
                
                // Calculate cumulative distance for speed drills (reset per phase)
                if isSpeedDrill {
                    if let phaseStart = phaseStartTime {
                        let samplesSincePhaseStart = dataStreamVM.windowedSamples.filter { sample in
                            sample.timestamp >= phaseStart
                        }
                        
                        if !samplesSincePhaseStart.isEmpty {
                            // Calculate distance from encoder counts for current phase
                            let phaseInitialCount = samplesSincePhaseStart.first?.value ?? initialEncoderCount
                            let maxCounts = samplesSincePhaseStart.map { $0.value }.max() ?? phaseInitialCount
                            let countsTraveled = max(0, maxCounts - phaseInitialCount)
                            cumulativeDistance = countsToDistance(countsTraveled)
                            
                            // Check if target distance reached for current phase
                            if let targetDistance = targetDistanceMeters, cumulativeDistance >= targetDistance {
                                completeCurrentPhase()
                                return
                            }
                        }
                    }
                    
                    // Check if 5 seconds have passed without data
                    if let lastData = lastDataTime {
                        let timeSinceLastData = Date().timeIntervalSince(lastData)
                        if timeSinceLastData >= 5.0 {
                            completeCurrentPhase()
                            return
                        }
                    }
                } else {
                    // For force drills, check if duration has been reached for current phase
                    if phaseElapsedTime >= Double(duration) {
                        completeCurrentPhase()
                    }
                }
            }
        }
    }
    
    private func completeCurrentPhase() {
        timer?.invalidate()
        
        // Collect samples for this phase
        if let phaseStart = phaseStartTime {
            let phaseSamples = dataStreamVM.windowedSamples.filter { sample in
                sample.timestamp >= phaseStart && sample.timestamp <= Date()
            }
            allPhaseSamples.append(contentsOf: phaseSamples)
        }
        
        // Check if there are more phases
        if currentPhaseIndex < phases.count - 1 {
            // Move to next phase
            currentPhaseIndex += 1
            phaseElapsedTime = 0
            phaseStartTime = Date()
            cumulativeDistance = 0
            
            // Reset encoder count for next phase if it's a speed drill
            if currentPhase.drillType == .speedDrill && !dataStreamVM.windowedSamples.isEmpty {
                initialEncoderCount = dataStreamVM.windowedSamples.last?.value ?? 0
            }
            
            // Restart timer for next phase
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                Task { @MainActor in
                    elapsedTime += 0.1
                    phaseElapsedTime += 0.1
                    
                    if let startTime = measurementStartTime {
                        let relevantSamples = dataStreamVM.windowedSamples.filter { sample in
                            sample.timestamp >= startTime
                        }
                        collectedSamples = relevantSamples
                        
                        if !relevantSamples.isEmpty {
                            lastDataTime = relevantSamples.last?.timestamp ?? Date()
                        }
                    }
                    
                    if isSpeedDrill {
                        if let phaseStart = phaseStartTime {
                            let samplesSincePhaseStart = dataStreamVM.windowedSamples.filter { sample in
                                sample.timestamp >= phaseStart
                            }
                            
                            if !samplesSincePhaseStart.isEmpty {
                                let phaseInitialCount = samplesSincePhaseStart.first?.value ?? initialEncoderCount
                                let maxCounts = samplesSincePhaseStart.map { $0.value }.max() ?? phaseInitialCount
                                let countsTraveled = max(0, maxCounts - phaseInitialCount)
                                cumulativeDistance = countsToDistance(countsTraveled)
                                
                                if let targetDistance = targetDistanceMeters, cumulativeDistance >= targetDistance {
                                    completeCurrentPhase()
                                    return
                                }
                            }
                        }
                        
                        if let lastData = lastDataTime {
                            let timeSinceLastData = Date().timeIntervalSince(lastData)
                            if timeSinceLastData >= 5.0 {
                                completeCurrentPhase()
                                return
                            }
                        }
                    } else {
                        if phaseElapsedTime >= Double(duration) {
                            completeCurrentPhase()
                        }
                    }
                }
            }
        } else {
            // All phases complete
            completeMeasurement()
        }
    }
    
    private func completeMeasurement() {
        timer?.invalidate()
        timer = nil
        
        // Final collection of all samples from all phases
        if let startTime = measurementStartTime {
            let finalSamples = dataStreamVM.windowedSamples.filter { sample in
                sample.timestamp >= startTime && sample.timestamp <= Date()
            }
            // Normalize timestamps to start from 0 relative to drill start
            let normalizedSamples = finalSamples.map { sample in
                SensorSample(
                    timestamp: Date(timeIntervalSince1970: sample.timestamp.timeIntervalSince(startTime)),
                    value: sample.value
                )
            }
            onComplete(normalizedSamples.isEmpty ? (allPhaseSamples.isEmpty ? collectedSamples : allPhaseSamples) : normalizedSamples)
        } else {
            onComplete(allPhaseSamples.isEmpty ? collectedSamples : allPhaseSamples)
        }
    }
    
    private func abort() {
        timer?.invalidate()
        timer = nil
        onAbort()
    }
    
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Drill info header
            VStack(spacing: Theme.Spacing.xs) {
                Text(drillName.uppercased())
                    .font(Theme.Typography.drukDrillName)
                    .foregroundColor(.white)
                
                HStack(spacing: Theme.Spacing.md) {
                    if isMultiPhase {
                        Text("Phase \(currentPhaseIndex + 1) of \(phases.count)")
                            .font(Theme.Typography.exo2Subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Text(currentPhase.drillType.rawValue)
                        .font(Theme.Typography.exo2Subheadline)
                        .foregroundColor(.white.opacity(0.8))
                    
                    if isSpeedDrill, let distance = targetDistanceMeters {
                        // Show distance for speed drills
                        let unitSystem = profileStore.selectedUser?.effectiveUnitSystem ?? .metric
                        if unitSystem == .imperial {
                            let yards = distance * 1.09361
                            Text("• \(String(format: "%.1f", yards)) yds")
                                .font(Theme.Typography.exo2Subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        } else {
                            Text("• \(String(format: "%.1f", distance)) m")
                                .font(Theme.Typography.exo2Subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    } else if let time = currentPhase.targetTimeSeconds {
                        Text("• \(Int(time))s")
                            .font(Theme.Typography.exo2Subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    if isBaseline {
                        Text("• BASELINE")
                            .font(Theme.Typography.exo2Subheadline)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.sm)
            
            // Live chart
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                
                    Chart(chartData) {
                        LineMark(
                            x: .value("Time", $0.timestamp),
                            y: .value("Value", $0.value)
                        )
                        .foregroundStyle(Theme.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .frame(height: 280)
                    .padding(Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                            .fill(Color(.systemGray6))
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Live performance chart")
                    
                    // Chart accessibility summary
                    if !chartData.isEmpty {
                        let peak = chartData.map { $0.value }.max() ?? 0
                        let avg = chartData.map { $0.value }.reduce(0, +) / Double(chartData.count)
                        let duration = chartData.last?.timestamp.timeIntervalSince(chartData.first?.timestamp ?? Date()) ?? 0
                        Text("Peak: \(String(format: "%.1f", peak)), Avg: \(String(format: "%.1f", avg)), Duration: \(String(format: "%.1f", duration))s")
                            .font(Theme.Typography.exo2Caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, Theme.Spacing.lg)
                            .accessibilityLabel("Chart summary: Peak \(String(format: "%.1f", peak)), Average \(String(format: "%.1f", avg)), Duration \(String(format: "%.1f", duration)) seconds")
                    }
                
                if dataStreamVM.windowedSamples.isEmpty {
                    HStack {
                        Spacer()
                        Text("Waiting for data...")
                            .font(Theme.Typography.exo2Label)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
            
            // Timer/Distance display
            Group {
                if isSpeedDrill {
                    if let target = targetDistanceMeters {
                        let unitSystem = profileStore.selectedUser?.effectiveUnitSystem ?? .metric
                        let displayDistance = unitSystem == .imperial ? cumulativeDistance * 1.09361 : cumulativeDistance
                        let displayTarget = unitSystem == .imperial ? target * 1.09361 : target
                        let unit = unitSystem == .imperial ? "yds" : "m"
                        
                        Text("\(String(format: "%.1f", displayDistance)) / \(String(format: "%.1f", displayTarget)) \(unit)")
                            .font(Theme.Typography.exo2Metric)
                            .foregroundColor(.white)
                    } else {
                        Text("\(Int(phaseElapsedTime))s")
                            .font(Theme.Typography.exo2Metric)
                            .foregroundColor(.white)
                    }
                } else {
                    Text("\(Int(phaseElapsedTime))s / \(duration)s")
                        .font(Theme.Typography.exo2Metric)
                        .foregroundColor(.white)
                }
                
                if isMultiPhase {
                    Text("Total: \(String(format: "%.1f", elapsedTime))s")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            // Abort button
            Button(role: .destructive) {
                HapticFeedback.buttonPress()
                abort()
            } label: {
                Text("ABORT")
                    .font(Theme.Typography.exo2Headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(Theme.CornerRadius.medium)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .onAppear {
            startMeasuring()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
}

struct DrillCompleteView: View {
    let samples: [SensorSample]
    let template: DrillTemplate?
    let onContinue: () -> Void
    
    // Generate flat line data if no samples
    private var chartData: [SensorSample] {
        if samples.isEmpty {
            // Create flat line at 0
            let startTime = Date().addingTimeInterval(-10)
            return (0..<20).map { index in
                SensorSample(
                    timestamp: startTime.addingTimeInterval(Double(index) * 0.5),
                    value: 0.0
                )
            }
        }
        return samples
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(Theme.orange)
                    
                    Text("DRILL COMPLETE")
                        .font(Theme.Typography.drukSection)
                        .foregroundColor(.white)
                    
                    if let template = template {
                        Text(template.name.uppercased())
                            .font(Theme.Typography.drukDrillName)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.top, Theme.Spacing.lg)
                
                // Show graph
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("PERFORMANCE GRAPH")
                        .font(Theme.Typography.drukSection)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, Theme.Spacing.lg)
                    
                    Chart(chartData) {
                        LineMark(
                            x: .value("Time", $0.timestamp),
                            y: .value("Value", $0.value)
                        )
                        .foregroundStyle(Theme.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .frame(height: 280)
                    .padding(Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                            .fill(Color(.systemGray6))
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Drill performance chart")
                    
                    // Chart accessibility summary
                    if !chartData.isEmpty {
                        let peak = chartData.map { $0.value }.max() ?? 0
                        let avg = chartData.map { $0.value }.reduce(0, +) / Double(chartData.count)
                        let duration = chartData.last?.timestamp.timeIntervalSince(chartData.first?.timestamp ?? Date()) ?? 0
                        Text("Peak: \(String(format: "%.1f", peak)), Avg: \(String(format: "%.1f", avg)), Duration: \(String(format: "%.1f", duration))s")
                            .font(Theme.Typography.exo2Caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, Theme.Spacing.lg)
                            .accessibilityLabel("Chart summary: Peak \(String(format: "%.1f", peak)), Average \(String(format: "%.1f", avg)), Duration \(String(format: "%.1f", duration)) seconds")
                    }
                    
                    if samples.isEmpty {
                        HStack {
                            Spacer()
                            Text("No data received")
                                .font(Theme.Typography.exo2Label)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                
                Button {
                    HapticFeedback.buttonPress()
                    onContinue()
                } label: {
                    Text("Continue")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            LinearGradient(
                                colors: [Theme.orange, Theme.secondaryAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(Theme.CornerRadius.medium)
                        .shadow(color: Theme.orange.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)
                
                Spacer()
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
    }
}

struct RestView: View {
    @Binding var remainingSeconds: Int
    let nextDrillName: String?
    let onSkip: () -> Void
    let onComplete: () -> Void
    
    @State private var timer: Timer?
    
    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Text("REST")
                .font(Theme.Typography.drukTitle)
                .foregroundColor(.white)
            
            if let name = nextDrillName {
                Text("Next: \(name.uppercased())")
                    .font(Theme.Typography.exo2Headline)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Text("\(remainingSeconds)")
                .font(Theme.Typography.exo2Metric)
                .foregroundColor(.white)
            
            Button {
                HapticFeedback.buttonPress()
                onSkip()
            } label: {
                Text("SKIP REST")
                    .font(Theme.Typography.exo2Subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .onAppear {
            startRestTimer()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func startRestTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if remainingSeconds > 0 {
                remainingSeconds -= 1
            } else {
                timer.invalidate()
                self.timer = nil
                onComplete()
            }
        }
    }
}

struct ResultsView: View {
    let sessionResult: SessionResult?
    let template: DrillTemplate?
    let workout: Workout?
    let workoutSessionId: UUID?
    let sessionResultStore: SessionResultStore
    let templateStore: DrillTemplateStore
    let workoutStore: WorkoutStore
    let onDone: () -> Void
    let onStartAgain: () -> Void
    
    init(
        sessionResult: SessionResult?,
        template: DrillTemplate?,
        workout: Workout? = nil,
        workoutSessionId: UUID? = nil,
        sessionResultStore: SessionResultStore,
        templateStore: DrillTemplateStore,
        workoutStore: WorkoutStore,
        onDone: @escaping () -> Void,
        onStartAgain: @escaping () -> Void
    ) {
        self.sessionResult = sessionResult
        self.template = template
        self.workout = workout
        self.workoutSessionId = workoutSessionId
        self.sessionResultStore = sessionResultStore
        self.templateStore = templateStore
        self.workoutStore = workoutStore
        self.onDone = onDone
        self.onStartAgain = onStartAgain
    }
    
    // Check if this is a workout session
    private var isWorkoutSession: Bool {
        sessionResult?.mode == .workout || workout != nil
    }
    
    // Normalize timestamps to start from 0 for display
    private var chartData: [SensorSample] {
        guard let result = sessionResult, !result.rawESP32Data.isEmpty else {
            return []
        }
        
        // If timestamps are already normalized (starting from 0), use as-is
        // Otherwise, normalize them relative to the first sample
        let firstTimestamp = result.rawESP32Data.first?.timestamp ?? Date()
        return result.rawESP32Data.map { sample in
            SensorSample(
                timestamp: Date(timeIntervalSince1970: sample.timestamp.timeIntervalSince(firstTimestamp)),
                value: sample.value
            )
        }
    }
    
    var body: some View {
        if isWorkoutSession, let workout = workout, let sessionId = workoutSessionId {
            // Show workout analysis view
            WorkoutAnalysisView(
                workout: workout,
                workoutSessionId: sessionId,
                sessionResultStore: sessionResultStore,
                templateStore: templateStore,
                onDone: onDone,
                onStartAgain: onStartAgain
            )
        } else {
            // Show single drill analysis (existing code)
            drillAnalysisView
        }
    }
    
    private var drillAnalysisView: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Success icon
                ZStack {
                    Circle()
                        .fill(Theme.orange.opacity(0.2))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(Theme.orange)
                }
                .padding(.top, Theme.Spacing.lg)
                
                VStack(spacing: Theme.Spacing.sm) {
                    Text("GREAT WORK!")
                        .font(Theme.Typography.drukTitle)
                        .foregroundColor(.white)
                    
                    if let template = template {
                        Text(template.name.uppercased())
                            .font(Theme.Typography.drukDrillName)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Text("Drill Analysis")
                        .font(Theme.Typography.exo2Callout)
                        .foregroundColor(.white.opacity(0.7))
                }
                
                if let result = sessionResult {
                    // Performance Graph
                    if !result.rawESP32Data.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("PERFORMANCE GRAPH")
                                .font(Theme.Typography.drukSection)
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, Theme.Spacing.lg)
                            
                            Chart(chartData) {
                                LineMark(
                                    x: .value("Time", $0.timestamp.timeIntervalSince1970),
                                    y: .value("Value", $0.value)
                                )
                                .foregroundStyle(Theme.orange)
                                .lineStyle(StrokeStyle(lineWidth: 2.5))
                            }
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                    AxisGridLine()
                                    AxisValueLabel {
                                        if let timeValue = value.as(Double.self) {
                                            Text(String(format: "%.1fs", timeValue))
                                                .font(.system(size: 10))
                                        }
                                    }
                                }
                            }
                            .chartYAxis {
                                AxisMarks(values: .automatic(desiredCount: 5))
                            }
                            .frame(height: 300)
                            .padding(Theme.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                            .stroke(.white.opacity(0.1), lineWidth: 1)
                                    )
                            )
                            .padding(.horizontal, Theme.Spacing.lg)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Session results chart")
                            
                            // Chart accessibility summary
                            if !chartData.isEmpty {
                                let peak = result.derivedMetrics.peakForce ?? 0
                                let avg = result.derivedMetrics.averageForce ?? 0
                                let duration = result.derivedMetrics.duration ?? 0
                                Text("Peak: \(String(format: "%.1f", peak)), Avg: \(String(format: "%.1f", avg)), Duration: \(String(format: "%.1f", duration))s")
                                    .font(Theme.Typography.exo2Caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.horizontal, Theme.Spacing.lg)
                                    .padding(.top, Theme.Spacing.xs)
                                    .accessibilityLabel("Chart summary: Peak \(String(format: "%.1f", peak)), Average \(String(format: "%.1f", avg)), Duration \(String(format: "%.1f", duration)) seconds")
                            }
                        }
                    } else {
                        // Show message if no data
                        VStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 48))
                                .foregroundColor(.white.opacity(0.5))
                            
                            Text("No data received")
                                .font(Theme.Typography.exo2Callout)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .frame(height: 300)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                .fill(.ultraThinMaterial)
                        )
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                    
                    // Metrics
                    VStack(spacing: Theme.Spacing.md) {
                        if let peak = result.derivedMetrics.peakForce {
                            ResultRow(
                                icon: "arrow.up.circle.fill",
                                label: "Peak Force",
                                value: String(format: "%.2f", peak),
                                color: Theme.orange
                            )
                        }
                        if let avg = result.derivedMetrics.averageForce {
                            ResultRow(
                                icon: "chart.line.uptrend.xyaxis",
                                label: "Average Force",
                                value: String(format: "%.2f", avg),
                                color: .blue
                            )
                        }
                        if let duration = result.derivedMetrics.duration {
                            ResultRow(
                                icon: "clock.fill",
                                label: "Duration",
                                value: String(format: "%.1fs", duration),
                                color: .green
                            )
                        }
                    }
                    .padding(Theme.Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                                    .stroke(.white.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                
                VStack(spacing: Theme.Spacing.md) {
                    Button {
                        HapticFeedback.workoutComplete()
                        onDone()
                    } label: {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                LinearGradient(
                                    colors: [Theme.orange, Theme.secondaryAccent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(Theme.CornerRadius.medium)
                            .shadow(color: Theme.orange.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    
                    Button {
                        HapticFeedback.buttonPress()
                        onStartAgain()
                    } label: {
                        Text("Start Again")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(Color(.systemGray6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                            .stroke(.white.opacity(0.2), lineWidth: 1)
                                    )
                            )
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.deepBlue.ignoresSafeArea())
    }
}

// MARK: - Workout Analysis View

struct WorkoutAnalysisView: View {
    let workout: Workout
    let workoutSessionId: UUID
    @ObservedObject var sessionResultStore: SessionResultStore
    @ObservedObject var templateStore: DrillTemplateStore
    let onDone: () -> Void
    let onStartAgain: () -> Void
    
    @State private var selectedDrillResult: SessionResult?
    @State private var showingDrillAnalysis = false
    
    private var drillResults: [SessionResult] {
        sessionResultStore.getResults(forWorkoutSessionId: workoutSessionId)
            .sorted { $0.date < $1.date }
    }
    
    private var restUUID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
    
    private func isRestPeriod(item: WorkoutItem) -> Bool {
        item.drillId == restUUID || (item.reps == 0 && templateStore.getTemplate(id: item.drillId) == nil)
    }
    
    private func getResultForItem(_ item: WorkoutItem) -> SessionResult? {
        // Get the latest result for this drill (in case of multiple reps)
        drillResults
            .filter { $0.drillId == item.drillId }
            .sorted { $0.date > $1.date }
            .first
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Success icon
                ZStack {
                    Circle()
                        .fill(Theme.orange.opacity(0.2))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(Theme.orange)
                }
                .padding(.top, Theme.Spacing.lg)
                
                VStack(spacing: Theme.Spacing.sm) {
                    Text("GREAT WORK!")
                        .font(Theme.Typography.drukTitle)
                        .foregroundColor(.white)
                    
                    Text(workout.name.uppercased())
                        .font(Theme.Typography.drukDrillName)
                        .foregroundColor(.white.opacity(0.8))
                    
                    Text("Workout Analysis")
                        .font(Theme.Typography.exo2Callout)
                        .foregroundColor(.white.opacity(0.7))
                }
                
                // Workout program scrollview
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("WORKOUT PROGRAM")
                        .font(Theme.Typography.drukSection)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, Theme.Spacing.lg)
                    
                    ScrollView {
                        VStack(spacing: Theme.Spacing.sm) {
                            ForEach(workout.items) { item in
                                if isRestPeriod(item: item) {
                                    WorkoutAnalysisRestRow(item: item)
                                } else if let template = templateStore.getTemplate(id: item.drillId) {
                                    let drillResult = getResultForItem(item)
                                    WorkoutAnalysisDrillRow(
                                        item: item,
                                        template: template,
                                        hasResult: drillResult != nil
                                    ) {
                                        if let result = drillResult {
                                            selectedDrillResult = result
                                            showingDrillAnalysis = true
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                    .frame(maxHeight: 400)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .stroke(.white.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                
                VStack(spacing: Theme.Spacing.md) {
                    Button {
                        HapticFeedback.workoutComplete()
                        onDone()
                    } label: {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                LinearGradient(
                                    colors: [Theme.orange, Theme.secondaryAccent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(Theme.CornerRadius.medium)
                            .shadow(color: Theme.orange.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    
                    Button {
                        HapticFeedback.buttonPress()
                        onStartAgain()
                    } label: {
                        Text("Start Again")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(Color(.systemGray6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                            .stroke(.white.opacity(0.2), lineWidth: 1)
                                    )
                            )
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.deepBlue.ignoresSafeArea())
        .sheet(isPresented: $showingDrillAnalysis) {
            if let result = selectedDrillResult,
               let drillId = result.drillId,
               let template = templateStore.getTemplate(id: drillId) {
                NavigationStack {
                    DrillAnalysisView(sessionResult: result, template: template)
                        .navigationTitle("Drill Analysis")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") {
                                    showingDrillAnalysis = false
                                }
                            }
                        }
                }
            }
        }
    }
}

struct WorkoutAnalysisDrillRow: View {
    let item: WorkoutItem
    let template: DrillTemplate
    let hasResult: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(template.name)
                        .font(Theme.Typography.exo2Subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    
                    HStack(spacing: Theme.Spacing.md) {
                        Text("\(item.reps) rep\(item.reps == 1 ? "" : "s")")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        if item.restSeconds > 0 {
                            Text("\(item.restSeconds)s rest")
                                .font(Theme.Typography.exo2Caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        
                        if let level = item.level {
                            Text("Level \(level)")
                                .font(Theme.Typography.exo2Caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
                
                Spacer()
                
                if hasResult {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Text("No data")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasResult)
    }
}

struct WorkoutAnalysisRestRow: View {
    let item: WorkoutItem
    
    var body: some View {
        HStack {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "timer")
                    .foregroundColor(Theme.orange)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Rest Period")
                        .font(Theme.Typography.exo2Subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    Text("\(item.restSeconds) seconds")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                        .stroke(Theme.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct ResultRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 32)
            
            Text(label)
                .font(Theme.Typography.exo2Subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.8))
            
            Spacer()
            
            Text(value)
                .font(Theme.Typography.exo2MetricSmall)
                .foregroundColor(.white)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }
}

struct AbortedView: View {
    let onReturn: () -> Void
    
    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundColor(.red)
            
            Text("SESSION ABORTED")
                .font(Theme.Typography.drukTitle)
                .foregroundColor(.white)
            
            Button {
                onReturn()
            } label: {
                Text("RETURN TO TRAIN")
                    .font(Theme.Typography.exo2Headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Theme.orange)
                    .foregroundColor(.white)
                    .cornerRadius(Theme.CornerRadius.medium)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

struct TrainPhaseDetailCard: View {
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
                    .font(Theme.Typography.exo2Subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                if totalPhases > 1 {
                    Text("of \(totalPhases)")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
            }
            
            Divider()
                .background(.white.opacity(0.2))
            
            // Drill type
            TrainPropertyRow(label: "Type", value: phase.drillType.rawValue)
            
            // Motor behavior
            TrainPropertyRow(label: "Motor Behavior", value: motorBehavior)
            
            // Target (distance or time)
            if phase.drillType == .speedDrill {
                if let distance = phase.distanceMeters {
                    let displayDistance = unitSystem == .imperial ? distance * 1.09361 : distance
                    let unit = unitSystem == .imperial ? "yds" : "m"
                    TrainPropertyRow(label: "Distance", value: String(format: "%.1f \(unit)", displayDistance))
                } else {
                    TrainPropertyRow(label: "Distance", value: "Not specified")
                }
            } else {
                if let time = phase.targetTimeSeconds {
                    TrainPropertyRow(label: "Duration", value: String(format: "%.1f s", time))
                } else {
                    TrainPropertyRow(label: "Duration", value: "Not specified")
                }
            }
            
            // Force settings
            TrainPropertyRow(label: "Force Type", value: phase.forceType == .constant ? "Constant" : "Percentile")
            
            if phase.forceType == .constant {
                if let force = phase.constantForceN {
                    TrainPropertyRow(label: "Force", value: String(format: "%.1f N", force))
                } else {
                    TrainPropertyRow(label: "Force", value: "Not specified")
                }
                if let rampup = phase.rampupTimeSeconds {
                    TrainPropertyRow(label: "Rampup Time", value: String(format: "%.1f s", rampup))
                }
                
                // Show torque curve if available
                if let torqueCurve = phase.torqueCurve, !torqueCurve.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Torque Curve")
                            .font(Theme.Typography.exo2Caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.7))
                        Text("\(torqueCurve.count) points")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
            } else {
                if let percent = phase.forcePercentOfBaseline {
                    TrainPropertyRow(label: "Percentile", value: String(format: "%.1f%% of baseline", percent))
                } else {
                    TrainPropertyRow(label: "Percentile", value: "Not specified")
                }
                
                // Show torque curve if available (for percentile mode)
                if let torqueCurve = phase.torqueCurve, !torqueCurve.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Torque Curve")
                            .font(Theme.Typography.exo2Caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.7))
                        Text("\(torqueCurve.count) points")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                        .stroke(Theme.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct TrainPropertyRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(Theme.Typography.exo2Caption)
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(Theme.Typography.exo2Caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
        }
    }
}

struct CompactDetailBadge: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(Theme.Typography.exo2Caption)
                .foregroundColor(.white.opacity(0.6))
            Text(value)
                .font(Theme.Typography.exo2Label)
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                .fill(.ultraThinMaterial)
        )
    }
}

struct BluetoothConnectionIndicator: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            
            if bluetoothManager.connectionState == .connected {
                if let peripheral = bluetoothManager.connectedPeripheral {
                    Text(peripheral.name)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            } else {
                Text(connectionText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .cornerRadius(8)
    }
    
    private var connectionColor: Color {
        switch bluetoothManager.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnecting:
            return .orange
        case .disconnected:
            return .red
        }
    }
    
    private var connectionText: String {
        switch bluetoothManager.connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnecting:
            return "Disconnecting..."
        case .disconnected:
            return "Disconnected"
        }
    }
}

// MARK: - Train Drill Detail View

struct TrainDrillDetailView: View {
    let template: DrillTemplate
    let isBaselineRun: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // Header
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            Text(template.name)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Spacer()
                            ProbationStatusPill(status: template.probationStatus)
                        }
                        
                        if let description = template.description, !description.isEmpty {
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.md)
                    
                    Divider()
                        .padding(.horizontal, Theme.Spacing.md)
                    
                    // All Details Section
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Drill Details")
                            .font(.headline)
                            .padding(.horizontal, Theme.Spacing.md)
                        
                        VStack(spacing: 0) {
                            DetailRow(label: "Type", value: template.type.rawValue)
                            DetailRow(label: "Resist", value: template.isResist ? "Yes" : "No")
                            DetailRow(label: "Assist", value: template.isAssist ? "Yes" : "No")
                            
                            if let distance = template.distanceMeters {
                                DetailRow(label: "Distance", value: String(format: "%.1f m", distance))
                            }
                            
                            if let time = template.targetTimeSeconds {
                                DetailRow(label: "Duration", value: String(format: "%.1f s", time))
                            }
                            
                            if let speed = template.targetSpeedMps {
                                DetailRow(label: "Target Speed", value: String(format: "%.2f m/s", speed))
                            }
                            
                            // Force settings
                            if let forceType = template.forceType {
                                DetailRow(
                                    label: "Force Type",
                                    value: forceType == .constant ? "Constant Force" : "Percentile Force"
                                )
                                
                                if forceType == .constant {
                                    if let force = template.constantForceN {
                                        DetailRow(label: "Force Amount", value: String(format: "%.1f N", force))
                                    }
                                    if let rampup = template.rampupTimeSeconds {
                                        DetailRow(label: "Rampup Time", value: String(format: "%.1f s", rampup))
                                    }
                                } else {
                                    DetailRow(label: "Force Mode", value: "Requires baseline run")
                                }
                            }
                            
                            // Target mode
                            DetailRow(label: "Target Mode", value: targetModeDescription)
                            
                            // Percent targets (if applicable)
                            if let speedPercent = template.speedPercentOfBaseline {
                                DetailRow(label: "Speed Target", value: String(format: "%.1f%% of baseline", speedPercent))
                            }
                            
                            if let forcePercent = template.forcePercentOfBaseline {
                                DetailRow(label: "Force Target", value: String(format: "%.1f%% of baseline", forcePercent))
                            }
                            
                            // Sport tag
                            if let sportTag = template.sportTag, !sportTag.isEmpty {
                                DetailRow(label: "Sport", value: sportTag)
                            }
                            
                            // Enforcement intent
                            DetailRow(label: "Enforcement", value: enforcementDescription)
                            
                            // Video attachment
                            if let videoURL = template.videoURL, !videoURL.isEmpty {
                                DetailRow(label: "Video", value: "Attached", icon: "video.fill")
                            }
                            
                            // Probation status
                            DetailRow(
                                label: "Status",
                                value: template.probationStatus == .probationary ? "Probationary (needs baseline)" : "Ready"
                            )
                        }
                        .background(Color(.systemGray6))
                        .cornerRadius(Theme.CornerRadius.medium)
                        .padding(.horizontal, Theme.Spacing.md)
                        
                        // Torque Curve Preview (if available)
                        if let torqueCurve = template.torqueCurve, !torqueCurve.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                Text("Torque Curve")
                                    .font(.headline)
                                    .padding(.horizontal, Theme.Spacing.md)
                                
                                TorqueCurvePreview(torqueCurve: torqueCurve, duration: template.targetTimeSeconds ?? 8.0)
                                    .frame(height: 200)
                                    .padding(.horizontal, Theme.Spacing.md)
                            }
                            .padding(.top, Theme.Spacing.md)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                    
                    Spacer(minLength: Theme.Spacing.xl)
                }
            }
            .background(Color(.systemGroupedBackground))
            .drukNavigationTitle("Drill Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isBaselineRun ? "Run Baseline" : "Start Drill") {
                        onStart()
                        dismiss()
                    }
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.orange)
                }
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
            return "Distance + Time"
        case .speedPercentOfBaseline:
            if let percent = template.speedPercentOfBaseline {
                return String(format: "%.0f%% of baseline speed", percent)
            }
            return "Speed % of Baseline"
        case .forcePercentOfBaseline:
            if let percent = template.forcePercentOfBaseline {
                return String(format: "%.0f%% of baseline force", percent)
            }
            return "Force % of Baseline"
        }
    }
    
    private var enforcementDescription: String {
        switch template.enforcementIntent {
        case .none:
            return "No Enforcement"
        case .velocityCurve:
            return "Velocity Curve"
        case .torqueEnvelope:
            return "Torque Envelope"
        case .hybrid:
            return "Hybrid"
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var icon: String? = nil
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
            
            Spacer()
            
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(.blue)
                }
                Text(value)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Color(.systemBackground))
    }
}

struct ReadyHoldDetailRow: View {
    let label: String
    let value: String
    var icon: String? = nil
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
            
            Spacer()
            
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.orange)
                }
                Text(value)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }
}

struct HoldButton: View {
    @Binding var progress: Double
    @Binding var isHolding: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    let onComplete: () -> Void
    
    @State private var holdTimer: Timer?
    private let holdDuration: TimeInterval = 3.0
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 4)
                .frame(width: 100, height: 100)
            
            // Progress circle
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 100, height: 100)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
            
            // Center logo
            Image("QuikLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .foregroundColor(.white)
        }
        .contentShape(Circle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Check if touch is within button bounds (50 is radius)
                    let center = CGPoint(x: 50, y: 50)
                    let distance = sqrt(pow(value.location.x - center.x, 2) + pow(value.location.y - center.y, 2))
                    
                    if distance <= 50 { // Within circle radius
                        if !isHolding {
                            startHold()
                            onPress()
                        }
                    } else {
                        // Released outside bounds
                        if isHolding {
                            cancelHold()
                            onRelease()
                        }
                    }
                }
                .onEnded { _ in
                    if isHolding {
                        cancelHold()
                        onRelease()
                    }
                }
        )
    }
    
    private func startHold() {
        progress = 0
        isHolding = true
        let startTime = Date()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(startTime)
            progress = min(elapsed / holdDuration, 1.0)
            
            if elapsed >= holdDuration {
                timer.invalidate()
                holdTimer = nil
                isHolding = false
                progress = 0
                onComplete()
            }
        }
    }
    
    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        progress = 0
        isHolding = false
    }
}

struct LiveModeView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @ObservedObject var dataStreamVM: DataStreamViewModel
    let onStop: () -> Void
    
    @State private var isRunning = false
    @State private var isShowingCountdown = false
    @AppStorage("countdownDuration") private var countdownDuration: Int = 5
    @State private var countdownValue: Int = 5
    @State private var holdProgress: Double = 0
    @State private var isHolding = false
    @State private var forceValue: Double = 0.0 // Force in Newtons, 0-100
    
    var body: some View {
        ZStack {
            if isShowingCountdown {
                // Countdown View
                CountdownView(
                    value: $countdownValue,
                    onComplete: {
                        isShowingCountdown = false
                        startLiveMode()
                    }
                )
            } else {
                // Main Live Mode View
                VStack(spacing: Theme.Spacing.xxl) {
                    Spacer()
                    
                    // Title
                    Text("LIVE MODE")
                        .font(Theme.Typography.drukTitle)
                        .foregroundColor(.white)
                    
                    // Slider and Button Side by Side
                    HStack(spacing: Theme.Spacing.xl) {
                        // Force Slider
                        VStack(spacing: Theme.Spacing.md) {
                            Text("Force")
                                .font(Theme.Typography.exo2Headline)
                                .foregroundColor(.white.opacity(0.8))
                            
                            Text("\(Int(forceValue)) N")
                                .font(Theme.Typography.drukTitle)
                                .foregroundColor(.white)
                            
                            // Vertical slider
                            GeometryReader { geometry in
                                ZStack(alignment: .bottom) {
                                    // Background track
                                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                        .fill(Color.white.opacity(0.2))
                                        .frame(width: 80)
                                    
                                    // Fill based on value
                                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                        .fill(
                                            LinearGradient(
                                                colors: [Theme.orange, Theme.secondaryAccent],
                                                startPoint: .bottom,
                                                endPoint: .top
                                            )
                                        )
                                        .frame(
                                            width: 80,
                                            height: max(20, CGFloat(forceValue / 100.0) * geometry.size.height)
                                        )
                                    
                                    // Slider thumb - always draggable
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 70, height: 70)
                                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                        .overlay(
                                            Circle()
                                                .stroke(Theme.orange, lineWidth: 3)
                                                .frame(width: 70, height: 70)
                                        )
                                        .offset(y: -CGFloat(forceValue / 100.0) * (geometry.size.height - 70))
                                }
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { dragValue in
                                            // Calculate value based on drag location relative to geometry
                                            // Y=0 is at top, Y=height is at bottom
                                            // Convert to value where 0% is bottom, 100% is top
                                            let thumbRadius: CGFloat = 35
                                            let trackHeight = geometry.size.height - (thumbRadius * 2)
                                            let dragY = dragValue.location.y
                                            let clampedY = max(thumbRadius, min(geometry.size.height - thumbRadius, dragY))
                                            let normalizedY = (geometry.size.height - thumbRadius - clampedY) / trackHeight
                                            let newValue = max(0, min(100, normalizedY * 100))
                                            forceValue = newValue
                                            
                                            // Send force value to device immediately if running
                                            if isRunning {
                                                sendForceValue(newValue)
                                            }
                                        }
                                        .onEnded { dragValue in
                                            // Ensure final value is sent when drag ends
                                            if isRunning {
                                                sendForceValue(forceValue)
                                            }
                                        }
                                )
                            }
                            .frame(height: 400)
                        }
                        .frame(maxWidth: .infinity)
                        
                        // Start/Stop Button on the right
                        VStack {
                            Spacer()
                            
                            if !isRunning {
                                // Hold-down start button
                                HoldButton(
                                    progress: $holdProgress,
                                    isHolding: $isHolding,
                                    onPress: {
                                        HapticFeedback.buttonPress()
                                    },
                                    onRelease: {
                                        HapticFeedback.buttonPress()
                                        // Cancel hold, don't start
                                    },
                                    onComplete: {
                                        // Hold complete, show countdown
                                        isShowingCountdown = true
                                        countdownValue = countdownDuration
                                    }
                                )
                            } else {
                                // Circular stop button
                                Button {
                                    HapticFeedback.buttonPress()
                                    stopLiveMode()
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 100, height: 100)
                                        
                                        Image(systemName: "stop.fill")
                                            .font(.system(size: 40, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                }
                            }
                            
                            Spacer()
                        }
                        .frame(width: 120)
                        .padding(.trailing, Theme.Spacing.lg)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    
                    Spacer()
                    
                    // Exit button
                    Button {
                        HapticFeedback.buttonPress()
                        if isRunning {
                            stopLiveMode()
                        }
                        onStop()
                    } label: {
                        Text("EXIT")
                            .font(Theme.Typography.exo2Subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.bottom, Theme.Spacing.md)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.deepBlue.ignoresSafeArea())
    }
    
    private func startLiveMode() {
        isRunning = true
        bluetoothManager.send("START")
        dataStreamVM.start()
        // Send initial force value
        sendForceValue(forceValue)
    }
    
    private func stopLiveMode() {
        isRunning = false
        bluetoothManager.send("STOP")
        dataStreamVM.stop()
        // Don't reset force or navigate away - just stop and stay on page
        // Force value stays at current setting for next run
    }
    
    private func sendForceValue(_ value: Double) {
        // Send force value as command to device
        // Format: "FORCE:50.0" for example
        let command = String(format: "FORCE:%.1f", value)
        bluetoothManager.send(command)
    }
}

struct LiveVariationSliderCard: View {
    let phase: DrillPhase
    @Binding var selectedValue: Double
    
    // Get bounds from the phase - these are set in CreateDrillWizardView when live variation is enabled
    // For constant force: constantForceN (min) and constantForceMaxN (max)
    // For percentile: forcePercentOfBaseline (min) and forcePercentOfBaselineMax (max)
    private var minValue: Double {
        if phase.forceType == .constant {
            // When live variation is enabled, constantForceN stores the min value
            // If nil, use a reasonable default (this shouldn't happen if data is saved correctly)
            return phase.constantForceN ?? 0
        } else {
            // When live variation is enabled, forcePercentOfBaseline stores the min value
            return phase.forcePercentOfBaseline ?? 0
        }
    }
    
    private var maxValue: Double {
        if phase.forceType == .constant {
            // constantForceMaxN stores the max value for live variation
            // If nil, use a reasonable default (this shouldn't happen if data is saved correctly)
            return phase.constantForceMaxN ?? 100
        } else {
            // forcePercentOfBaselineMax stores the max value for live variation
            return phase.forcePercentOfBaselineMax ?? 100
        }
    }
    
    // Clamped binding that enforces bounds
    private var clampedValue: Binding<Double> {
        Binding(
            get: {
                // Return value clamped to bounds
                max(minValue, min(maxValue, selectedValue))
            },
            set: { newValue in
                // Clamp the new value to bounds before setting
                selectedValue = max(minValue, min(maxValue, newValue))
            }
        )
    }
    
    private var unit: String {
        phase.forceType == .constant ? "N" : "%"
    }
    
    private var percentageLabelText: String {
        if phase.forceType == .percentile {
            if phase.quikburstMode == .resist {
                return "% under max speed"
            } else if phase.quikburstMode == .assist {
                return "% over max speed"
            }
        }
        return "%"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Live Variation: Select Strength")
                .font(Theme.Typography.exo2Subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            
            // Value Display
            if phase.forceType == .percentile {
                Text("\(Int(selectedValue)) \(percentageLabelText)")
                    .font(Theme.Typography.drukSection)
                    .foregroundColor(Theme.orange)
            } else {
                Text("\(Int(selectedValue)) \(unit)")
                    .font(Theme.Typography.drukSection)
                    .foregroundColor(Theme.orange)
            }
            
            // Slider
            VStack(spacing: Theme.Spacing.xs) {
                Slider(
                    value: clampedValue,
                    in: minValue...maxValue,
                    step: phase.forceType == .constant ? 1.0 : 0.5
                )
                .tint(Theme.orange)
                
                // Min/Max labels
                HStack {
                    if phase.forceType == .percentile {
                        Text("\(Int(minValue)) \(percentageLabelText)")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text("\(Int(maxValue)) \(percentageLabelText)")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundColor(.white.opacity(0.6))
                    } else {
                        Text("\(Int(minValue)) \(unit)")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text("\(Int(maxValue)) \(unit)")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                        .stroke(Theme.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct TorqueCurvePreview: View {
    let torqueCurve: [TorquePoint]
    let duration: Double
    
    var body: some View {
        Chart {
            ForEach(Array(torqueCurve.enumerated()), id: \.offset) { index, point in
                LineMark(
                    x: .value("Time", point.timeNormalized * duration),
                    y: .value("Force", point.forceN)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.orange)
                
                AreaMark(
                    x: .value("Time", point.timeNormalized * duration),
                    y: .value("Force", point.forceN)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.orange.opacity(0.3), Theme.orange.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .chartXScale(domain: 0...duration)
        .chartYScale(domain: 0...(torqueCurve.map { $0.forceN }.max() ?? 100) * 1.1)
        .chartXAxis {
            AxisMarks(values: .stride(by: max(1, duration / 5))) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(doubleValue, format: .number.precision(.fractionLength(1)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(doubleValue, format: .number.precision(.fractionLength(0)))
                    }
                }
            }
        }
        .frame(height: 200)
        .background(Color(.systemBackground))
        .cornerRadius(Theme.CornerRadius.medium)
    }
}

