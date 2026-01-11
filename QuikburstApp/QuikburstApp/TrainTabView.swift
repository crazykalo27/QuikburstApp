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
    @StateObject private var drillStore = DrillStore()
    @StateObject private var workoutStore = WorkoutStore()
    @StateObject private var sessionResultStore = SessionResultStore()
    @EnvironmentObject var profileStore: ProfileStore
    @ObservedObject var bluetoothManager: BluetoothManager
    
    @State private var sessionState: TrainSessionState = .idle
    @State private var selectedMode: TrainMode?
    @State private var selectedDrill: Drill?
    @State private var selectedWorkout: Workout?
    @State private var selectedLevel: Int = 1
    @State private var currentWorkoutItemIndex: Int = 0
    @State private var holdProgress: Double = 0
    @State private var countdownValue: Int = 5
    @State private var restRemaining: Int = 0
    @State private var sessionSamples: [SensorSample] = []
    @State private var sessionStartTime: Date?
    
    @StateObject private var dataStreamVM: DataStreamViewModel
    
    enum TrainMode {
        case drill
        case workout
    }
    
    init(bluetoothManager: BluetoothManager) {
        self.bluetoothManager = bluetoothManager
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
                                sessionState = .selectingItem
                            }
                        )
                        
                    case .selectingItem:
                        ItemSelectionView(
                            mode: selectedMode!,
                            drillStore: drillStore,
                            workoutStore: workoutStore,
                            onSelectDrill: { drill in
                                selectedDrill = drill
                                sessionState = .selectingLevel
                            },
                            onSelectWorkout: { workout in
                                selectedWorkout = workout
                                sessionState = .readyHold
                            }
                        )
                        
                    case .selectingLevel:
                        LevelSelectionView(
                            level: $selectedLevel,
                            onConfirm: {
                                sessionState = .readyHold
                            }
                        )
                        
                    case .readyHold:
                        ReadyHoldView(
                            progress: $holdProgress,
                            onHoldComplete: {
                                sessionState = .countdown
                                countdownValue = 5
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
                        MeasuringView(
                            bluetoothManager: bluetoothManager,
                            dataStreamVM: dataStreamVM,
                            drill: selectedDrill,
                            workoutItem: selectedWorkout?.items[currentWorkoutItemIndex],
                            drillStore: drillStore,
                            onAbort: {
                                abortSession()
                            },
                            onComplete: { samples in
                                sessionSamples = samples
                                if selectedMode == .workout {
                                    sessionState = .drillComplete
                                } else {
                                    completeSession()
                                }
                            }
                        )
                        
                    case .drillComplete:
                        DrillCompleteView(
                            samples: sessionSamples,
                            drill: selectedDrill,
                            onContinue: {
                                handleWorkoutDrillComplete()
                            }
                        )
                        
                    case .resting:
                        RestView(
                            remainingSeconds: $restRemaining,
                            nextDrillName: nextDrillName,
                            onSkip: {
                                proceedToNextDrill()
                            },
                            onComplete: {
                                proceedToNextDrill()
                            }
                        )
                        
                    case .results:
                        ResultsView(
                            sessionResult: currentSessionResult,
                            drill: selectedDrill,
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
            .navigationTitle("Train")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ProfileIndicator(profileStore: profileStore)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    BluetoothConnectionIndicator(bluetoothManager: bluetoothManager)
                }
            }
        }
        .environmentObject(drillStore)
        .environmentObject(workoutStore)
        .environmentObject(sessionResultStore)
    }
    
    private var nextDrillName: String? {
        guard let workout = selectedWorkout,
              currentWorkoutItemIndex < workout.items.count else {
            return nil
        }
        let item = workout.items[currentWorkoutItemIndex]
        
        // If it's a rest period, don't show next drill name
        if isRestPeriod(item: item) {
            return nil
        }
        
        if let drill = drillStore.getDrill(id: item.drillId) {
            return drill.name
        }
        return nil
    }
    
    private var currentSessionResult: SessionResult? {
        guard let mode = selectedMode else { return nil }
        
        let metrics = SessionMetrics(
            peakForce: sessionSamples.map { $0.value }.max(),
            averageForce: sessionSamples.isEmpty ? nil : sessionSamples.map { $0.value }.reduce(0, +) / Double(sessionSamples.count),
            duration: sessionStartTime.map { Date().timeIntervalSince($0) }
        )
        
        return SessionResult(
            mode: mode == .drill ? .drill : .workout,
            drillId: selectedDrill?.id,
            workoutId: selectedWorkout?.id,
            levelUsed: selectedLevel,
            rawESP32Data: sessionSamples,
            derivedMetrics: metrics
        )
    }
    
    private func startMeasuring() {
        sessionStartTime = Date()
        sessionSamples = []
        bluetoothManager.send("START")
        dataStreamVM.start()
        sessionState = .measuring
    }
    
    private func handleWorkoutDrillComplete() {
        guard let workout = selectedWorkout else { return }
        
        let currentItem = workout.items[currentWorkoutItemIndex]
        if currentItem.restSeconds > 0 && currentWorkoutItemIndex < workout.items.count - 1 {
            restRemaining = currentItem.restSeconds
            sessionState = .resting
        } else {
            proceedToNextDrill()
        }
    }
    
    private func proceedToNextDrill() {
        guard let workout = selectedWorkout else { return }
        
        currentWorkoutItemIndex += 1
        if currentWorkoutItemIndex < workout.items.count {
            let item = workout.items[currentWorkoutItemIndex]
            
            // Check if this is a rest period
            if isRestPeriod(item: item) {
                restRemaining = item.restSeconds
                sessionState = .resting
            } else {
                let drillId = item.drillId
                if let drill = drillStore.getDrill(id: drillId) {
                    selectedDrill = drill
                    selectedLevel = item.level ?? 1
                    sessionState = .readyHold
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
        return item.drillId == restUUID || (item.reps == 0 && drillStore.getDrill(id: item.drillId) == nil)
    }
    
    private func completeSession() {
        bluetoothManager.send("STOP")
        dataStreamVM.stop()
        
        if let result = currentSessionResult {
            sessionResultStore.addResult(result)
        }
        
        sessionState = .results
    }
    
    private func abortSession() {
        bluetoothManager.send("STOP")
        dataStreamVM.stop()
        sessionState = .aborted
    }
    
    private func resetToIdle() {
        sessionState = .idle
        selectedMode = nil
        selectedDrill = nil
        selectedWorkout = nil
        selectedLevel = 1
        currentWorkoutItemIndex = 0
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
                Text("What would you like to do?")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                
                Text("Choose your training mode")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
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
                            Text("Single Drill")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text("Focus on one exercise")
                                .font(.system(size: 14, weight: .regular, design: .rounded))
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
                            Text("Workout")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text("Complete a full routine")
                                .font(.system(size: 14, weight: .regular, design: .rounded))
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
    @ObservedObject var drillStore: DrillStore
    @ObservedObject var workoutStore: WorkoutStore
    let onSelectDrill: (Drill) -> Void
    let onSelectWorkout: (Workout) -> Void
    
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.md) {
                if mode == .drill {
                    ForEach(drillStore.drills) { drill in
                        Button {
                            onSelectDrill(drill)
                        } label: {
                            DrillSelectionRow(drill: drill)
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
}

struct DrillSelectionRow: View {
    let drill: Drill
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Category indicator
            RoundedRectangle(cornerRadius: 6)
                .fill(drill.category == .speed ? Color.blue.opacity(0.3) : Color.red.opacity(0.3))
                .frame(width: 4)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(drill.name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                HStack(spacing: Theme.Spacing.sm) {
                    CategoryBadge(category: drill.category)
                    Text("\(drill.lengthSeconds)s")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.1))
                        .cornerRadius(6)
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
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

struct WorkoutSelectionRow: View {
    let workout: Workout
    
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Workout icon indicator
            ZStack {
                Circle()
                    .fill(Theme.orange.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.orange)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(workout.name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text("\(workout.items.count) drill\(workout.items.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
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
                        .stroke(.white.opacity(0.1), lineWidth: 1)
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
                Text("Choose difficulty")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Select your level")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
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
            .onChange(of: level) { _ in
                HapticFeedback.cardTap()
            }
            
            Button {
                HapticFeedback.buttonPress()
                onConfirm()
            } label: {
                Text("Start")
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
    let onHoldComplete: () -> Void
    let onCancel: () -> Void
    
    @State private var holdTimer: Timer?
    private let holdDuration: TimeInterval = 3.0
    
    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Text("Hold to Start")
                .font(Theme.Typography.title)
                .foregroundColor(.white)
            
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 8)
                    .frame(width: 200, height: 200)
                
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: progress)
                
                Text("READY")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Button(role: .cancel) {
                cancelHold()
                onCancel()
            } label: {
                Text("Cancel")
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    startHold()
                }
                .onEnded { _ in
                    cancelHold()
                    onCancel()
                }
        )
    }
    
    private func startHold() {
        progress = 0
        let startTime = Date()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(startTime)
            progress = min(elapsed / holdDuration, 1.0)
            
            if elapsed >= holdDuration {
                timer.invalidate()
                holdTimer = nil
                onHoldComplete()
            }
        }
    }
    
    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        progress = 0
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
    let drill: Drill?
    let workoutItem: WorkoutItem?
    @ObservedObject var drillStore: DrillStore
    let onAbort: () -> Void
    let onComplete: ([SensorSample]) -> Void
    
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var collectedSamples: [SensorSample] = []
    @State private var measurementStartTime: Date?
    
    private var duration: Int {
        if let drill = drill {
            return drill.lengthSeconds
        } else if let item = workoutItem,
                  let drill = drillStore.getDrill(id: item.drillId) {
            return drill.lengthSeconds
        }
        return 10
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
    
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Live chart
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let drill = drill {
                    Text(drill.name)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                
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
                        .fill(.ultraThinMaterial)
                )
                .padding(.horizontal, Theme.Spacing.lg)
                
                if dataStreamVM.windowedSamples.isEmpty {
                    HStack {
                        Spacer()
                        Text("Waiting for data...")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
            
            // Timer
            Text("\(Int(elapsedTime))s / \(duration)s")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            // Abort button
            Button(role: .destructive) {
                HapticFeedback.buttonPress()
                abort()
            } label: {
                Text("ABORT")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
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
    
    private func startMeasuring() {
        elapsedTime = 0
        collectedSamples = []
        measurementStartTime = Date()
        
        // Start collecting all samples from the data stream
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            elapsedTime += 0.1
            
            // Collect ALL samples that have arrived since measurement started
            // Filter samples to only include those from this measurement period
            if let startTime = measurementStartTime {
                let relevantSamples = dataStreamVM.windowedSamples.filter { sample in
                    sample.timestamp >= startTime
                }
                collectedSamples = relevantSamples
            } else {
                // Fallback: collect recent samples
                collectedSamples = Array(dataStreamVM.windowedSamples.suffix(1000))
            }
            
            if elapsedTime >= Double(duration) {
                timer.invalidate()
                self.timer = nil
                
                // Final collection of all samples from the drill period
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
                    onComplete(normalizedSamples.isEmpty ? collectedSamples : normalizedSamples)
                } else {
                    onComplete(collectedSamples)
                }
            }
        }
    }
    
    private func abort() {
        timer?.invalidate()
        timer = nil
        onAbort()
    }
}

struct DrillCompleteView: View {
    let samples: [SensorSample]
    let drill: Drill?
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
                    
                    Text("Drill Complete")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    if let drill = drill {
                        Text(drill.name)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.top, Theme.Spacing.lg)
                
                // Show graph
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Performance Graph")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
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
                            .fill(.ultraThinMaterial)
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                    
                    if samples.isEmpty {
                        HStack {
                            Spacer()
                            Text("No data received")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
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
            Text("Rest")
                .font(Theme.Typography.title)
                .foregroundColor(.white)
            
            if let name = nextDrillName {
                Text("Next: \(name)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Text("\(remainingSeconds)")
                .font(.system(size: 80, weight: .bold))
                .foregroundColor(.white)
            
            Button {
                HapticFeedback.buttonPress()
                onSkip()
            } label: {
                Text("Skip Rest")
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
    let drill: Drill?
    let onDone: () -> Void
    let onStartAgain: () -> Void
    
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
                    Text("Great work!")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    if let drill = drill {
                        Text(drill.name)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Text("Drill Analysis")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                if let result = sessionResult {
                    // Performance Graph
                    if !result.rawESP32Data.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Performance Graph")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
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
                        }
                    } else {
                        // Show message if no data
                        VStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 48))
                                .foregroundColor(.white.opacity(0.5))
                            
                            Text("No data received")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
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
                                    .fill(.ultraThinMaterial)
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
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
            
            Spacer()
            
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
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
            
            Text("Session Aborted")
                .font(Theme.Typography.title)
                .foregroundColor(.white)
            
            Button {
                onReturn()
            } label: {
                Text("Return to Train")
                    .font(.headline)
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
