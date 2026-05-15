import SwiftUI
import Charts

struct TrainTelemSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let motorCurrent: Double
}

struct TrainTabView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @EnvironmentObject var sessionResultStore: SessionResultStore
    let startIntent: AppNavigationCoordinator.TrainStartIntent?

    private static let ampsPerLb: Double = 2.658

    private enum Section: String, CaseIterable {
        case train = "Train"
        case monitor = "Monitor"
    }

    private struct RunSnapshot: Identifiable {
        let id = UUID()
        let reason: String
        let enc: [EncoderData]
        let telem: [TrainTelemSample]
    }

    @State private var section: Section = .train
    @State private var setpointReady = false
    @State private var forceLbsText = "10"
    @State private var runTimeS: Double = 5.0
    @State private var distanceEnabled = true
    @State private var distanceM: Double = 10.0
    @State private var autoRewind = false
    @State private var statusText = "Idle"

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    PosterHeroHeader(
                        kicker: "VESC BLE",
                        title: "train",
                        subtitle: "Setpoint-gated force run with time/distance stop, monitor traces, and rewind."
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
                            Text(setpointReady ? "Setpoint: set" : "Setpoint: required")
                                .font(Theme.Typography.exo2Caption)
                                .foregroundStyle(setpointReady ? .green : .orange)
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
        }
        .onAppear {
            attachLineListener()
            send("ENC_STREAM,1,25")
            send("TELEM_STREAM,1,25")
        }
        .onDisappear {
            detachLineListener()
            cancelAllRunWork()
        }
    }

    private var trainPanel: some View {
        PosterGlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Button("Setpoint") {
                    guard isConnected else { return }
                    send("SETPOINT")
                }
                .buttonStyle(PosterHeroButtonStyle(fill: Theme.primaryGradient))
                .disabled(!isConnected)

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

                Toggle("Auto-rewind at end of run", isOn: $autoRewind)

                HStack(spacing: 8) {
                    Button("Start") { startRun() }
                        .buttonStyle(PosterHeroButtonStyle(fill: Theme.primaryGradient))
                        .disabled(!isConnected || runActive || !setpointReady)
                    Button("Stop") { stopRun(reason: "manual_stop", userInitiated: true) }
                        .buttonStyle(.bordered)
                }

                Text(statusText)
                    .font(Theme.Typography.exo2Caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private var monitorPanel: some View {
        PosterGlassPanel {
            VStack(spacing: 10) {
                MonitorChartsView(enc: liveEnc, telem: liveTelem)
                    .frame(minHeight: 420)

                HStack(spacing: 8) {
                    Button("Rewind") { startRewind(source: "manual") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isConnected || !setpointReady)

                    HoldToPullButton(
                        title: holdPulling ? "Pulling..." : "Hold to pull in",
                        onPress: {
                            guard isConnected, setpointReady else { return }
                            holdPulling = true
                            send("SET_DUTY,0.1200")
                        },
                        onRelease: {
                            holdPulling = false
                            send("STOP")
                        }
                    )
                    .disabled(!isConnected || !setpointReady)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private var isConnected: Bool { bluetoothManager.connectionState == .connected }

    private var targetCurrentA: Double {
        let lbs = Double(forceLbsText) ?? 0
        return lbs * Self.ampsPerLb
    }

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
        if up.hasPrefix("OK,SETPOINT") { setpointReady = true }
        if up.hasPrefix("WARN,SETPOINT_REQUIRED") { statusText = "Setpoint required" }
        if up.hasPrefix("INFO,SETPOINT_REACHED") {
            statusText = "Setpoint reached"
            rewinding = false
            if runActive { stopRun(reason: "setpoint_reached", userInitiated: false) }
        }
        if let enc = parseEnc(core) {
            lastPositionM = enc.position
            liveEnc.append(enc)
            if liveEnc.count > 2000 { liveEnc.removeFirst(liveEnc.count - 2000) }
            if runActive {
                runEnc.append(enc)
                evaluateDistanceStop(position: enc.position)
            }
        }
        if let telem = parseTelem(core) {
            liveTelem.append(telem)
            if liveTelem.count > 2000 { liveTelem.removeFirst(liveTelem.count - 2000) }
            if runActive { runTelem.append(telem) }
        }
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

    private func startRun() {
        guard isConnected, setpointReady else { return }
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
        statusText = "Pretension 5s..."
        send("SET_DUTY,0.1200")

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
        if autoRewind && !userInitiated {
            startRewind(source: "auto")
        }
    }

    private func finalizeRun(reason: String) {
        let snapshot = RunSnapshot(reason: reason, enc: runEnc, telem: runTelem)
        resultSheet = snapshot
        if !runEnc.isEmpty {
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
    }

    private func startRewind(source: String) {
        guard isConnected, setpointReady else { return }
        rewinding = true
        let brake = 120.0
        send(String(format: "SET_BRAKE,%.3f", brake))
        statusText = "Rewind (\(source)): brake 2s"
        rewindWork?.cancel()
        let w = DispatchWorkItem {
            send("STOP")
            send("SET_DUTY,0.1200")
            statusText = "Rewind pull-in to setpoint"
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
        runActive = false
    }
}

private struct MonitorChartsView: View {
    let enc: [EncoderData]
    let telem: [TrainTelemSample]

    var body: some View {
        VStack(spacing: 10) {
            chartCard(title: "Position (m)", color: .green) {
                Chart(enc) { d in
                    LineMark(x: .value("t", d.timestamp), y: .value("pos", d.position))
                }
            }
            chartCard(title: "Velocity (m/s)", color: .blue) {
                Chart(enc) { d in
                    LineMark(x: .value("t", d.timestamp), y: .value("vel", d.velocity))
                }
            }
            chartCard(title: "Motor Current (A)", color: .orange) {
                Chart(telem) { d in
                    LineMark(x: .value("t", d.timestamp), y: .value("i", d.motorCurrent))
                }
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

private struct HoldToPullButton: View {
    let title: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var active = false

    var body: some View {
        Text(title)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(active ? Color.orange.opacity(0.7) : Color.orange.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !active {
                            active = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        if active {
                            active = false
                            onRelease()
                        }
                    }
            )
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
