import SwiftUI
import Charts

struct TrainTelemSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let motorCurrent: Double
}

struct TrainTabView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var sessionResultStore: SessionResultStore
    @EnvironmentObject var navigationCoordinator: AppNavigationCoordinator
    @EnvironmentObject var templateStore: DrillTemplateStore
    @EnvironmentObject var drillRunStore: DrillRunStore
    @EnvironmentObject var baselineStore: DrillBaselineStore
    let startIntent: AppNavigationCoordinator.TrainStartIntent?

    private static let ampsPerLb: Double = 2.658
    private static let spoolPullAmps: Double = 4.5
    private static let stableVelMps: Double = 0.10
    private static let stableHoldSeconds: TimeInterval = 0.65
    private static let abortStopBurst = 8
    private static let monitorWindowSeconds: TimeInterval = 30

    private enum Section: String, CaseIterable {
        case train = "Train"
        case monitor = "Monitor"
    }

    private enum SessionState: Equatable {
        case needsCalibration
        case ready
    }

    private struct RunSnapshot: Identifiable {
        let id = UUID()
        let reason: String
        let enc: [EncoderData]
        let telem: [TrainTelemSample]
    }

    @State private var section: Section = .train
    @State private var sessionState: SessionState = .needsCalibration
    @State private var setpointReady = false
    @State private var showCalibrationSheet = false
    @State private var calibrationPhase: BallCalibrationPhase = .holdBall
    @State private var stableSince: Date?
    @State private var overrideHolding = false
    @State private var overridePullMotorActive = false
    @State private var firmwareArmed = false

    @State private var forceLbsText = "10"
    @State private var runTimeS: Double = 5.0
    @State private var distanceEnabled = true
    @State private var distanceM: Double = 10.0
    @State private var statusText = "Connect and calibrate"

    @State private var listenerID: UUID?
    @State private var lastPositionM: Double?
    @State private var liveEnc: [EncoderData] = []
    @State private var liveTelem: [TrainTelemSample] = []

    @State private var runActive = false
    @State private var runStartPosM: Double?
    @State private var runUpperLimitM: Double?
    @State private var runLowerLimitM: Double?
    @State private var runEnc: [EncoderData] = []
    @State private var runTelem: [TrainTelemSample] = []
    @State private var runTimeoutWork: DispatchWorkItem?
    @State private var tensionWork: DispatchWorkItem?
    @State private var rewindWork: DispatchWorkItem?
    @State private var rewinding = false
    @State private var holdPulling = false
    @State private var resultSheet: RunSnapshot?

    /// Drill/workout queued from the Drills library (requires calibration before start).
    @State private var activeTemplate: DrillTemplate?
    @State private var activeIsBaseline = false
    @State private var activeWorkout: Workout?

    private var deviceReady: Bool { sessionState == .ready && setpointReady }
    private var hasQueuedDrill: Bool { activeTemplate != nil }
    private var isConnected: Bool { bluetoothManager.connectionState == .connected }
    private var canAbortMotor: Bool { isConnected && (firmwareArmed || deviceReady || runActive) }

    private var monitorEnc: [EncoderData] {
        rollingWindow(liveEnc, timestamp: \.timestamp)
    }

    private var monitorTelem: [TrainTelemSample] {
        rollingWindow(liveTelem, timestamp: \.timestamp)
    }

    private var calibrationUIMode: BallCalibrationUIMode {
        switch calibrationPhase {
        case .waitingStill: return .holdStill
        case .finishing: return .saving
        case .holdBall:
            if setpointReady && firmwareArmed { return .armed }
            if setpointReady { return .calibrated }
            return .pullAndConfirm
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    PosterHeroHeader(
                        kicker: "VESC BLE",
                        title: "train",
                        subtitle: deviceReady
                            ? "Calibrated — wind out slightly, then start your drill or run."
                            : "After connecting, calibrate the ball against the stop before training."
                    )
                    .padding(.horizontal, Theme.Spacing.sm)

                    PosterGlassPanel {
                        HStack {
                            Circle()
                                .fill(isConnected ? Color.green : Color.red)
                                .frame(width: 9, height: 9)
                            Text(isConnected ? "Connected" : "Disconnected")
                                .font(Theme.Typography.exo2Subheadline)
                            Spacer()
                            Text(deviceReady ? "Ready" : "Calibration required")
                                .font(Theme.Typography.exo2Caption)
                                .foregroundStyle(deviceReady ? .green : .orange)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)

                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.Spacing.sm)

                    if section == .train {
                        trainPanel
                    } else {
                        monitorPanel
                    }
                }
                .padding(.bottom, Theme.Spacing.md)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .supportsKeyboardDismiss()
            .scrollDisabled(overrideHolding)
        }
        .sheet(isPresented: $showCalibrationSheet) {
            calibrationSheet
        }
        .onChange(of: showCalibrationSheet) { _, showing in
            if !showing { finishOverridePullIn(resumeArmed: false) }
        }
        .onChange(of: calibrationPhase) { _, phase in
            if phase != .holdBall { finishOverridePullIn(resumeArmed: false) }
        }
        .sheet(item: $resultSheet) { snap in
            NavigationStack {
                ScrollView {
                    VStack(spacing: 12) {
                        Text("Run complete (\(snap.reason))")
                            .font(Theme.Typography.exo2Headline)
                        MonitorChartsView(enc: snap.enc, telem: snap.telem)
                    }
                    .padding()
                }
                .navigationTitle("Run Data")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { resultSheet = nil }
                    }
                }
            }
            .supportsKeyboardDismiss()
        }
        .onAppear {
            attachLineListener()
            if isConnected {
                send("ENC_STREAM,1,25")
                send("TELEM_STREAM,1,25")
            }
            processStartIntent()
            syncWithDeviceIfConnected()
        }
        .onDisappear {
            cancelAllRunWork()
        }
        .onChange(of: startIntent) { _, _ in
            processStartIntent()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                syncWithDeviceIfConnected()
            }
        }
        .onChange(of: bluetoothManager.connectionState) { _, newState in
            if newState == .connected {
                resetForNewConnection()
            } else if newState == .disconnected {
                resetForDisconnect()
            }
        }
    }

    private var calibrationSheet: some View {
        BallCalibrationSheet(
            isConnected: isConnected,
            uiMode: calibrationUIMode,
            overrideHolding: $overrideHolding,
            onPressOverride: { beginOverrideHold() },
            onReleaseOverride: { endOverrideHold() },
            onConfirmBallSeated: { confirmBallSeated() },
            onAbort: { abortDevice() },
            onDismiss: {
                finishOverridePullIn(resumeArmed: false)
                showCalibrationSheet = false
            }
        )
        .supportsKeyboardDismiss()
        .interactiveDismissDisabled(calibrationPhase == .waitingStill || calibrationPhase == .finishing)
    }

    private var trainPanel: some View {
        PosterGlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Button("Calibration") {
                    showCalibrationSheet = true
                }
                .buttonStyle(PosterHeroButtonStyle(fill: Theme.primaryGradient))
                .disabled(!isConnected)

                if let template = activeTemplate {
                    queuedDrillPanel(template: template)
                } else if let workout = activeWorkout {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Workout: \(workout.name)")
                            .font(Theme.Typography.exo2Subheadline)
                        Text("Calibrate, then run each drill from the workout list (full workout runner coming soon).")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundStyle(Theme.textSecondary)
                        Button("Clear workout queue") { clearQueuedSession() }
                            .font(Theme.Typography.exo2Caption)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                Group {
                    if hasQueuedDrill {
                        Text("Ad-hoc test run")
                            .font(Theme.Typography.exo2Caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text("Set force (lb)")
                        .font(Theme.Typography.exo2Caption)
                    TextField("10", text: $forceLbsText)
                        .keyboardType(.decimalPad)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    Text("Target current: \(targetCurrentA, specifier: "%.3f") A  (\(Self.ampsPerLb, specifier: "%.3f") A/lb)")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundStyle(Theme.textSecondary)

                    HStack {
                        Text("Run time (s)")
                        Spacer()
                        Stepper(value: $runTimeS, in: 1...120, step: 1) {
                            Text("\(Int(runTimeS))")
                        }
                        .frame(width: 140)
                    }

                    Toggle("Enable distance stop", isOn: $distanceEnabled)
                    if distanceEnabled {
                        HStack {
                            Text("Distance stop (m)")
                            Spacer()
                            Stepper(value: $distanceM, in: 0.5...200, step: 0.5) {
                                Text(distanceM, format: .number.precision(.fractionLength(1)))
                            }
                            .frame(width: 170)
                        }
                    }

                    HStack(spacing: 8) {
                        Button(hasQueuedDrill ? "Ad-hoc start" : "Start") {
                            startRun(requiresCalibration: true)
                        }
                            .buttonStyle(PosterHeroButtonStyle(fill: Theme.primaryGradient))
                            .disabled(!isConnected || runActive || !deviceReady)
                        Button("Stop") { stopRun(reason: "manual_stop", userInitiated: true) }
                            .buttonStyle(.bordered)
                            .disabled(!isConnected || !deviceReady)
                    }
                }
                .disabled(!deviceReady)
                .opacity(deviceReady ? 1 : 0.4)

                if firmwareArmed {
                    Text("Motor is armed on device — use Abort to disarm before adjusting the ball.")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundStyle(.orange)
                }

                Button("Abort") { abortDevice() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canAbortMotor)
                    .frame(maxWidth: .infinity, minHeight: 44)

                Text(statusText)
                    .font(Theme.Typography.exo2Caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }

    @ViewBuilder
    private func queuedDrillPanel(template: DrillTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drill: \(template.name)")
                .font(Theme.Typography.exo2Subheadline)
            Text(activeIsBaseline
                 ? "Baseline capture — no motor, encoder only"
                 : "From your drill library")
                .font(Theme.Typography.exo2Caption)
                .foregroundStyle(Theme.textSecondary)

            if !deviceReady {
                Text("Complete ball calibration before starting this drill.")
                    .font(Theme.Typography.exo2Caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button(activeIsBaseline ? "Start baseline" : "Start drill") {
                    startQueuedDrill()
                }
                .buttonStyle(PosterHeroButtonStyle(fill: Theme.primaryGradient))
                .disabled(!isConnected || runActive || !deviceReady)

                Button("Cancel") { clearQueuedSession() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var monitorPanel: some View {
        PosterGlassPanel {
            VStack(spacing: 10) {
                MonitorChartsView(enc: monitorEnc, telem: monitorTelem)
                    .frame(minHeight: 420)

                HStack(spacing: 8) {
                    Button("Rewind") { startRewind(source: "manual") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isConnected)

                    HoldDownButton(
                        enabled: isConnected,
                        isHeld: $overrideHolding,
                        onHoldStart: {
                            holdPulling = true
                            beginOverrideHold()
                        },
                        onHoldEnd: {
                            holdPulling = false
                            endOverrideHold()
                        }
                    ) {
                        Text(overrideHolding ? "Pulling..." : "Hold to pull in")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(overrideHolding ? Color.orange.opacity(0.7) : Color.orange.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private var targetCurrentA: Double {
        let lbs = Double(forceLbsText) ?? 0
        return lbs * Self.ampsPerLb
    }

    // MARK: - Session / calibration

    private func resetForNewConnection() {
        if calibrationPhase == .holdBall {
            stableSince = nil
        }
        finishOverridePullIn(resumeArmed: false)
        cancelAllRunWork()
        statusText = "Connected — syncing with device…"
        send("ENC_STREAM,1,25")
        send("TELEM_STREAM,1,25")
        queryFirmwareStatus()
    }

    private func resetForDisconnect() {
        firmwareArmed = false
        setpointReady = false
        showCalibrationSheet = false
        liveEnc = []
        liveTelem = []
        finishOverridePullIn(resumeArmed: false)
        cancelAllRunWork()
        statusText = "Disconnected — connect to sync calibration state"
    }

    private func rollingWindow<T>(_ samples: [T], timestamp keyPath: KeyPath<T, Date>) -> [T] {
        guard let latest = samples.last else { return [] }
        let cutoff = latest[keyPath: keyPath].addingTimeInterval(-Self.monitorWindowSeconds)
        return samples.filter { $0[keyPath: keyPath] >= cutoff }
    }

    private func trimMonitorBuffers() {
        liveEnc = rollingWindow(liveEnc, timestamp: \.timestamp)
        liveTelem = rollingWindow(liveTelem, timestamp: \.timestamp)
    }

    private func syncWithDeviceIfConnected() {
        guard isConnected else { return }
        queryFirmwareStatus()
    }

    private func queryFirmwareStatus() {
        guard isConnected else { return }
        send("GET_STATUS")
    }

    private func applyFirmwareStatus(setpoint: Bool, armed: Bool, safetyStop: Bool) {
        firmwareArmed = armed
        if safetyStop {
            requireRecalibration(status: "Safety stop on device — use Abort or reset on device")
            return
        }

        switch calibrationPhase {
        case .waitingStill, .finishing:
            break
        case .holdBall:
            setpointReady = setpoint
            if setpoint {
                sessionState = .ready
                if armed {
                    statusText = "Armed — light tension on rope (Abort to disarm)"
                } else {
                    statusText = "Calibrated — wind out slightly, then train"
                }
            } else {
                sessionState = .needsCalibration
                statusText = "Connected — calibrate the ball"
                showCalibrationSheet = true
            }
        }
    }

    // MARK: - Drill library → Train

    private func processStartIntent() {
        guard let intent = startIntent else { return }
        navigationCoordinator.clearStartIntent()
        section = .train
        navigationCoordinator.isSessionActive = true

        switch intent {
        case .drillTemplate(let template, let isBaseline):
            activeWorkout = nil
            activeTemplate = template
            activeIsBaseline = isBaseline
            applyTemplateToRunControls(template)
            promptCalibrationIfNeeded(for: template.name)
        case .workout(let workout):
            activeTemplate = nil
            activeIsBaseline = false
            activeWorkout = workout
            statusText = "Workout \"\(workout.name)\" — calibrate before running drills"
            if isConnected && !deviceReady {
                showCalibrationSheet = true
            }
        }
    }

    private func promptCalibrationIfNeeded(for name: String) {
        if !isConnected {
            statusText = "Connect to run \"\(name)\""
            return
        }
        if !deviceReady {
            showCalibrationSheet = true
            statusText = "Calibrate before running \"\(name)\""
        } else {
            statusText = activeIsBaseline
                ? "Ready — tap Start baseline for \"\(name)\""
                : "Ready — tap Start drill for \"\(name)\""
        }
    }

    private func applyTemplateToRunControls(_ template: DrillTemplate) {
        let phase = template.effectivePhases.first
        if let seconds = phase?.targetTimeSeconds ?? template.targetTimeSeconds, seconds > 0 {
            runTimeS = min(120, max(1, seconds))
        }
        if let meters = phase?.distanceMeters ?? template.distanceMeters, meters > 0 {
            distanceEnabled = true
            distanceM = meters
        }
        if !activeIsBaseline, let newtons = phase?.constantForceN ?? template.constantForceN, newtons > 0 {
            let lbs = newtons / 4.448
            forceLbsText = String(format: "%.1f", lbs)
        }
    }

    private func startQueuedDrill() {
        guard isConnected else {
            statusText = "Connect before starting drill"
            return
        }
        guard deviceReady else {
            showCalibrationSheet = true
            statusText = "Calibrate before starting drill"
            return
        }
        guard activeTemplate != nil else { return }
        if activeIsBaseline {
            startBaselineCapture()
        } else {
            startRun(requiresCalibration: true)
        }
    }

    private func clearQueuedSession() {
        activeTemplate = nil
        activeIsBaseline = false
        activeWorkout = nil
        navigationCoordinator.isSessionActive = false
        if deviceReady {
            statusText = "Ready — wind out slightly, then train"
        } else {
            statusText = "Calibration required before training"
        }
    }

    /// Press: 4.5 A spool-in until release (firmware holds latch via OVERRIDE_SPOOL_IN / pollOverrideMaintain).
    private func beginOverrideHold() {
        guard isConnected, !overridePullMotorActive else { return }
        overridePullMotorActive = true
        send(String(format: "OVERRIDE_SPOOL_IN,%.3f", Self.spoolPullAmps))
    }

    /// Release: stop (suppress armed auto-resume so STOP is not immediately overridden).
    private func endOverrideHold() {
        guard overridePullMotorActive else {
            overrideHolding = false
            holdPulling = false
            return
        }
        overridePullMotorActive = false
        overrideHolding = false
        holdPulling = false
        guard isConnected else { return }
        send("ARM_SUPPRESS_RESUME")
        send("STOP")
    }

    private func finishOverridePullIn(resumeArmed: Bool) {
        _ = resumeArmed
        endOverrideHold()
    }

    private func confirmBallSeated() {
        guard isConnected else { return }
        endOverrideHold()
        calibrationPhase = .waitingStill
        stableSince = nil
        statusText = "Arming — hold still…"
        send(String(format: "ARM,1,%.3f", Self.spoolPullAmps))
    }

    private func evaluateStability(velocity: Double) {
        guard calibrationPhase == .waitingStill else { return }
        if abs(velocity) < Self.stableVelMps {
            if stableSince == nil { stableSince = Date() }
            if let t0 = stableSince, Date().timeIntervalSince(t0) >= Self.stableHoldSeconds {
                finishCalibrationZeroAndSetpoint()
            }
        } else {
            stableSince = nil
        }
    }

    private func finishCalibrationZeroAndSetpoint() {
        calibrationPhase = .finishing
        statusText = "Saving setpoint…"
        send("ENC_RESET")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            send("SETPOINT")
        }
    }

    private func markCalibrationComplete() {
        sessionState = .ready
        setpointReady = true
        calibrationPhase = .holdBall
        stableSince = nil
        showCalibrationSheet = false
        queryFirmwareStatus()
        if let template = activeTemplate {
            statusText = activeIsBaseline
                ? "Calibrated — tap Start baseline for \"\(template.name)\""
                : "Calibrated — tap Start drill for \"\(template.name)\""
        } else {
            statusText = "Ready — wind out slightly, then start drill"
        }
    }

    private func abortDevice() {
        cancelAllRunWork()
        endOverrideHold()
        holdPulling = false
        firmwareArmed = false
        send("ARM_SUPPRESS_RESUME")
        send("ARM,0")
        for _ in 0..<Self.abortStopBurst {
            send("STOP")
        }
        requireRecalibration(status: "Aborted — recalibrate before next run")
        queryFirmwareStatus()
    }

    /// Firmware already disarmed and stopped; sync UI and require full calibration.
    private func handleArmWindInOvershootSafety() {
        handleFirmwareSafetyAbort(
            status: "Safety stop: pulled in >0.5 m past setpoint — recalibrate"
        )
    }

    private func handleHostLinkLossSafety() {
        handleFirmwareSafetyAbort(
            status: "Safety stop: lost BLE link to app — recalibrate"
        )
    }

    private func handleFirmwareSafetyAbort(status: String) {
        cancelAllRunWork()
        endOverrideHold()
        holdPulling = false
        runActive = false
        rewinding = false
        requireRecalibration(status: status)
    }

    private func requireRecalibration(status: String) {
        sessionState = .needsCalibration
        setpointReady = false
        firmwareArmed = false
        calibrationPhase = .holdBall
        stableSince = nil
        statusText = status
        showCalibrationSheet = true
    }

    // MARK: - BLE

    private func attachLineListener() {
        if listenerID != nil { return }
        listenerID = bluetoothManager.addReceivedLineListener { line in
            handleLine(line)
        }
    }

    private func detachLineListener() {
        if let id = listenerID {
            bluetoothManager.removeReceivedLineListener(id)
            listenerID = nil
        }
    }

    private func send(_ cmd: String) {
        bluetoothManager.send(cmd + "\n")
    }

    private func handleLine(_ line: String) {
        let core = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "<< ", with: "")
        let up = core.uppercased()
        if up.hasPrefix("OK,STATUS,") {
            parseFirmwareStatusLine(core)
        }
        if up.hasPrefix("OK,SETPOINT") {
            setpointReady = true
            if calibrationPhase == .finishing {
                markCalibrationComplete()
            }
        }
        if up.hasPrefix("OK,ARM,1") {
            firmwareArmed = true
        }
        if up.hasPrefix("OK,ARM,0") {
            firmwareArmed = false
            if sessionState == .needsCalibration {
                statusText = "Disarmed — calibrate to continue"
            }
        }
        if up.hasPrefix("WARN,SETPOINT_REQUIRED") {
            statusText = "Setpoint required"
        }
        if up.hasPrefix("ERROR,SAFETY_STOP,ARM_WIND_IN_OVERSHOOT") {
            handleArmWindInOvershootSafety()
        }
        // HOST_LINK_TIMEOUT watchdog disabled on firmware; ignore stale errors from older builds.
        // if up.hasPrefix("ERROR,SAFETY_STOP,HOST_LINK_TIMEOUT") {
        //     handleHostLinkLossSafety()
        // }
        if up.hasPrefix("ERROR,SAFETY_STOP,BLE_DISCONNECTED") {
            handleHostLinkLossSafety()
        }
        if up.hasPrefix("INFO,SETPOINT_REACHED") {
            statusText = "Setpoint reached"
            rewinding = false
            if runActive { stopRun(reason: "setpoint_reached", userInitiated: false) }
        }
        if let enc = parseEnc(core) {
            lastPositionM = enc.position
            liveEnc.append(enc)
            trimMonitorBuffers()
            evaluateStability(velocity: enc.velocity)
            if runActive {
                runEnc.append(enc)
                evaluateDistanceStop(position: enc.position)
            }
        }
        if let telem = parseTelem(core) {
            liveTelem.append(telem)
            trimMonitorBuffers()
            if runActive { runTelem.append(telem) }
        }
    }

    private func parseFirmwareStatusLine(_ line: String) {
        let p = line.split(separator: ",", omittingEmptySubsequences: false)
        guard p.count >= 5,
              p[0].uppercased() == "OK",
              p[1].uppercased() == "STATUS" else { return }
        let setpoint = p[2] == "1"
        let armed = p[3] == "1"
        let safety = p[4] == "1"
        applyFirmwareStatus(setpoint: setpoint, armed: armed, safetyStop: safety)
    }

    private func parseEnc(_ line: String) -> EncoderData? {
        let p = line.split(separator: ",")
        guard p.count == 5, p[0].uppercased() == "ENC" else { return nil }
        guard let ms = Double(p[1]),
              let counts = Int32(p[2]),
              let pos = Double(p[3]),
              let vel = Double(p[4]) else { return nil }
        return EncoderData(
            timestamp: Date(timeIntervalSince1970: ms / 1000.0),
            position: pos,
            velocity: vel,
            rpm: (vel / (Double.pi * 0.1016)) * 60.0,
            acceleration: 0,
            counts: counts
        )
    }

    private func parseTelem(_ line: String) -> TrainTelemSample? {
        let p = line.split(separator: ",")
        guard p.count >= 6, p[0].uppercased() == "TELEM" else { return nil }
        guard let ms = Double(p[1]), let iMotor = Double(p[5]) else { return nil }
        return TrainTelemSample(timestamp: Date(timeIntervalSince1970: ms / 1000.0), motorCurrent: iMotor)
    }

    // MARK: - Runs

    private func startRun(requiresCalibration: Bool = true) {
        if requiresCalibration {
            guard isConnected, deviceReady else {
                if isConnected { showCalibrationSheet = true }
                statusText = "Calibrate before starting a run"
                return
            }
        } else {
            guard isConnected else { return }
        }
        cancelAllRunWork()
        runEnc = []
        runTelem = []
        runStartPosM = lastPositionM
        if distanceEnabled, let s = runStartPosM {
            runUpperLimitM = s + distanceM
            runLowerLimitM = s - distanceM
        } else {
            runUpperLimitM = nil
            runLowerLimitM = nil
        }
        statusText = "Pretension 5s…"
        send(String(format: "SET_CURRENT,%.3f", Self.spoolPullAmps))

        let tension = DispatchWorkItem {
            runActive = true
            if runStartPosM == nil { runStartPosM = lastPositionM }
            if distanceEnabled, let s = runStartPosM {
                runUpperLimitM = s + distanceM
                runLowerLimitM = s - distanceM
            }
            send(String(format: "SET_CURRENT,%.4f", targetCurrentA))
            statusText = "Run active"

            let timeout = DispatchWorkItem {
                stopRun(reason: "timed_stop", userInitiated: false)
            }
            runTimeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + runTimeS, execute: timeout)
        }
        tensionWork = tension
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: tension)
    }

    /// Baseline library run: record encoder only (no motor commands).
    private func startBaselineCapture() {
        guard isConnected, deviceReady, activeTemplate != nil else {
            showCalibrationSheet = true
            return
        }
        cancelAllRunWork()
        runEnc = []
        runTelem = []
        runActive = true
        runStartPosM = lastPositionM
        if distanceEnabled, let s = runStartPosM {
            runUpperLimitM = s + distanceM
            runLowerLimitM = s - distanceM
        } else {
            runUpperLimitM = nil
            runLowerLimitM = nil
        }
        statusText = "Baseline capture (no motor)…"

        let timeout = DispatchWorkItem {
            stopRun(reason: "baseline_timed_stop", userInitiated: false)
        }
        runTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + runTimeS, execute: timeout)
    }

    private func evaluateDistanceStop(position: Double) {
        guard distanceEnabled, let up = runUpperLimitM, let low = runLowerLimitM else { return }
        if position >= up || position <= low {
            stopRun(reason: "distance_stop", userInitiated: false)
        }
    }

    private func stopRun(reason: String, userInitiated: Bool) {
        if !runActive && !userInitiated { return }
        runActive = false
        runTimeoutWork?.cancel()
        runTimeoutWork = nil
        tensionWork?.cancel()
        tensionWork = nil
        send("STOP")
        statusText = "Stopped (\(reason))"
        finalizeRun(reason: reason)
    }

    private func finalizeRun(reason: String) {
        let snapshot = RunSnapshot(reason: reason, enc: runEnc, telem: runTelem)
        resultSheet = snapshot
        guard !runEnc.isEmpty else { return }

        if let template = activeTemplate {
            persistLibraryDrillRun(template: template, reason: reason)
        } else {
            persistAdHocTrainRun()
        }
    }

    private func persistAdHocTrainRun() {
        let duration = max(0, (runEnc.last?.timestamp.timeIntervalSince(runEnc.first?.timestamp ?? Date())) ?? 0)
        let avg = runTelem.isEmpty ? 0 : runTelem.map(\.motorCurrent).reduce(0, +) / Double(runTelem.count)
        let peak = runTelem.map { abs($0.motorCurrent) }.max() ?? 0
        let result = SessionResult(
            mode: .drill,
            rawESP32Data: [],
            encoderData: runEnc,
            derivedMetrics: SessionMetrics(
                peakForce: peak,
                averageForce: avg,
                duration: duration,
                totalWork: nil
            )
        )
        sessionResultStore.addResult(result)
    }

    private func persistLibraryDrillRun(template: DrillTemplate, reason: String) {
        let results = computeRunResults(from: runEnc)
        let runMode: RunMode = activeIsBaseline ? .baselineNoEnforcement : .enforced
        let drillRun = DrillRun(
            templateId: template.id,
            runMode: runMode,
            results: results,
            notes: reason
        )
        drillRunStore.saveRun(drillRun)

        if activeIsBaseline {
            let profile = EnforcementPlanGenerator.createBaselineVelocityProfile(
                from: results.velocityTimeSeries
            )
            let baseline = DrillBaseline(
                templateId: template.id,
                baselineRunId: drillRun.id,
                baselineDistanceMeters: results.distanceMeters,
                baselineTimeSeconds: results.durationSeconds,
                baselineAvgSpeedMps: results.avgSpeedMps,
                baselinePeakSpeedMps: results.peakSpeedMps,
                baselineVelocityProfileSummary: profile
            )
            baselineStore.saveBaseline(baseline)
            templateStore.markBaselineCaptured(for: template.id)
        }

        let avg = runTelem.isEmpty ? 0 : runTelem.map(\.motorCurrent).reduce(0, +) / Double(runTelem.count)
        let peak = runTelem.map { abs($0.motorCurrent) }.max() ?? 0
        let result = SessionResult(
            mode: .drill,
            drillId: template.id,
            rawESP32Data: [],
            encoderData: runEnc,
            derivedMetrics: SessionMetrics(
                peakForce: peak,
                averageForce: avg,
                duration: results.durationSeconds,
                totalWork: nil
            )
        )
        sessionResultStore.addResult(result)

        statusText = activeIsBaseline
            ? "Baseline saved for \"\(template.name)\" — see Progress & drill history"
            : "Run saved for \"\(template.name)\" — see Progress"
        clearQueuedSession()
    }

    private func computeRunResults(from enc: [EncoderData]) -> RunResults {
        guard enc.count >= 2 else {
            return RunResults(
                distanceMeters: 0,
                durationSeconds: 0,
                avgSpeedMps: 0,
                peakSpeedMps: 0,
                powerEstimateW: nil,
                forceEstimateN: nil,
                velocityTimeSeries: []
            )
        }
        let duration = max(0, enc.last!.timestamp.timeIntervalSince(enc.first!.timestamp))
        let distance = abs(enc.last!.position - enc.first!.position)
        let speeds = enc.map { abs($0.velocity) }
        let avg = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        let peak = speeds.max() ?? 0
        let series = enc.map {
            VelocitySample(
                timestamp: $0.timestamp,
                velocityMps: $0.velocity,
                distanceMeters: $0.position
            )
        }
        return RunResults(
            distanceMeters: distance,
            durationSeconds: duration,
            avgSpeedMps: avg,
            peakSpeedMps: peak,
            powerEstimateW: nil,
            forceEstimateN: nil,
            velocityTimeSeries: series
        )
    }

    private func startRewind(source: String) {
        guard isConnected, deviceReady else { return }
        rewinding = true
        send("ARM_SUPPRESS_RESUME")
        send(String(format: "SET_BRAKE,%.3f", 120.0))
        statusText = "Rewind (\(source)): brake 2s"
        rewindWork?.cancel()
        let w = DispatchWorkItem {
            send("ARM_SUPPRESS_RESUME")
            send("STOP")
            send(String(format: "SET_CURRENT,%.3f", Self.spoolPullAmps))
            statusText = "Rewind pull-in"
        }
        rewindWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
    }

    private func cancelAllRunWork() {
        runTimeoutWork?.cancel()
        runTimeoutWork = nil
        tensionWork?.cancel()
        tensionWork = nil
        rewindWork?.cancel()
        rewindWork = nil
        if overridePullMotorActive {
            endOverrideHold()
        }
        runActive = false
    }
}

private struct MonitorChartsView: View {
    let enc: [EncoderData]
    let telem: [TrainTelemSample]

    private var timeDomain: ClosedRange<Date>? {
        let stamps = enc.map(\.timestamp) + telem.map(\.timestamp)
        guard let lo = stamps.min(), let hi = stamps.max(), lo < hi else { return nil }
        return lo...hi
    }

    var body: some View {
        VStack(spacing: 10) {
            chartCard(title: "Position (m) — last 30 s", color: .green) {
                Chart(enc) { d in
                    LineMark(x: .value("t", d.timestamp), y: .value("pos", d.position))
                }
                .chartXScale(domain: timeDomain)
            }
            chartCard(title: "Velocity (m/s) — last 30 s", color: .blue) {
                Chart(enc) { d in
                    LineMark(x: .value("t", d.timestamp), y: .value("vel", d.velocity))
                }
                .chartXScale(domain: timeDomain)
            }
            chartCard(title: "Motor current (A) — last 30 s", color: .orange) {
                Chart(telem) { d in
                    LineMark(x: .value("t", d.timestamp), y: .value("i", d.motorCurrent))
                }
                .chartXScale(domain: timeDomain)
            }
        }
    }

    private func chartCard<Content: View>(title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Typography.exo2Subheadline).foregroundStyle(color)
            content()
                .frame(height: 140)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PosterHeroButtonStyle: ButtonStyle {
    let fill: LinearGradient
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.exo2Headline.weight(.bold))
            .foregroundStyle(Color.white.opacity(0.98))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                    .fill(fill)
                    .opacity(configuration.isPressed ? 0.86 : 1)
            )
    }
}
