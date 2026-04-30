import SwiftUI

/// Train tab: matches CONTROL.py / pwmAndEncoder.ino protocol.
/// User pairs in Profiles → Device Pairing. Here: pick direction, time, pwm → run → view plots.
/// Telemetry strip mirrors Python `TELEM,...` rows (RPM, duty, V bat, currents, temps)—UI-only until bridged from BLE/VESC stream.
struct TrainTabView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    let startIntent: AppNavigationCoordinator.TrainStartIntent?

    @State private var direction: String = "F"  // "F" forward, "B" backward
    @State private var durationSeconds: Int = 5
    @State private var pwmPercentText: String = "0"

    @State private var displayedData: [EncoderData] = []
    @State private var isConfirmingStart: Bool = false

    init(bluetoothManager: BluetoothManager, startIntent: AppNavigationCoordinator.TrainStartIntent? = nil) {
        self.bluetoothManager = bluetoothManager
        self.startIntent = startIntent
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundGradient
                    .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: Theme.Spacing.md) {
                        PosterHeroHeader(
                            kicker: "Session control",
                            title: "train",
                            subtitle: "PWM run + encoder traces; stack mirrors VESC live serial fields for poster parity."
                        )
                        .padding(.horizontal, Theme.Spacing.sm)

                        connectionSection
                        controlSection

                        PosterGlassPanel {
                            telemDashboard
                                .padding(.top, Theme.Spacing.xs)
                            Divider()
                                .background(Theme.textTertiary.opacity(0.35))
                                .padding(.vertical, Theme.Spacing.sm)
                            dataSection
                                .padding(.top, Theme.Spacing.xs)
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                    }
                    .padding(.bottom, Theme.Spacing.md)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        isConfirmingStart = false
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: bluetoothManager.drillState) { _, newState in
                handleDrillStateChange(newState)
            }
        }
        .tint(Theme.primaryAccent)
    }

    @ViewBuilder
    private var telemDashboard: some View {
        if isDrillActive {
            TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: false)) { context in
                let sample = MockVESCWave.sample(at: context.date.timeIntervalSinceReferenceDate)
                VESCStyleTelemetryDashboard(
                    rpm: sample.rpm,
                    dutyFraction: sample.dutyFraction,
                    volts: sample.vb,
                    motorAmps: sample.imotor,
                    batteryAmps: sample.iin,
                    mosTempC: sample.tmos,
                    motorTempC: sample.tmotor,
                    isLive: true
                )
            }
        } else if isConnected {
            VESCStyleTelemetryDashboard(
                rpm: 420,
                dutyFraction: 0.12,
                volts: 48.9,
                motorAmps: 4.2,
                batteryAmps: 2.1,
                mosTempC: 36,
                motorTempC: 40,
                isLive: false
            )
        } else {
            VESCStyleTelemetryDashboard(
                rpm: 0,
                dutyFraction: 0,
                volts: Double.nan,
                motorAmps: 0,
                batteryAmps: 0,
                mosTempC: Double.nan,
                motorTempC: Double.nan,
                isLive: false
            )
        }
    }

    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Connected" : "Disconnected")
                .font(Theme.Typography.exo2Subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    private var connectionSection: some View {
        PosterGlassPanel(cornerRadius: Theme.CornerRadius.medium) {
            connectionStatus
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private var controlSection: some View {
        PosterGlassPanel {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("manual run")
                        .font(Theme.Typography.exo2SemiBold(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                    PosterCaptionPill(text: "Ble stream")
                    Spacer()
                }

                Text("direction")
                    .font(Theme.Typography.exo2Caption)
                    .foregroundStyle(Theme.textTertiary)
                Picker("Direction", selection: $direction) {
                    Text("Forward").tag("F")
                    Text("Backward").tag("B")
                }
                .pickerStyle(.segmented)
                .tint(Theme.primaryAccent)

                Text("duration (seconds)")
                    .font(Theme.Typography.exo2Caption)
                    .foregroundStyle(Theme.textTertiary)
                Picker("Duration", selection: $durationSeconds) {
                    ForEach(1...10, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Theme.primaryAccent)

                VStack(alignment: .leading, spacing: 6) {
                    Text("pwm (%)")
                        .font(Theme.Typography.exo2Caption)
                        .foregroundStyle(Theme.textTertiary)
                    TextField("0–100", text: $pwmPercentText)
                        .keyboardType(.numberPad)
                        .padding(Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .foregroundStyle(Theme.textPrimary)
                }

                Button(isDrillActive ? "stop" : (isConfirmingStart ? "confirm" : "run")) {
                    if isDrillActive {
                        bluetoothManager.sendAbort()
                    } else if isConfirmingStart {
                        runDrill()
                        isConfirmingStart = false
                    } else {
                        isConfirmingStart = true
                    }
                }
                .buttonStyle(PosterHeroButtonStyle(fill: Theme.primaryGradient))
                .disabled(!isConnected)
                .opacity(!isConnected ? 0.5 : 1)
                .allowsHitTesting(isConnected)

                Text("two-step start prevents accidental bursts when demoing.")
                    .font(Theme.Typography.exo2Caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("motion capture")
                    .font(Theme.Typography.exo2SemiBold(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                PosterCaptionPill(text: "encoder")
                Spacer()
            }

            if isDrillActive {
                VStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                        .tint(Theme.primaryAccent)
                        .scaleEffect(1.25)
                    Text(statusText)
                        .font(Theme.Typography.exo2Subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xl)
            } else if let err = errorMessage {
                Text(err)
                    .font(Theme.Typography.exo2Subheadline)
                    .foregroundStyle(.red.opacity(0.92))
            } else if displayedData.isEmpty {
                Text("Run a burst to populate live position / velocity / RPM charts.")
                    .font(Theme.Typography.exo2Subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LiveEncoderGraphsView(encoderData: displayedData)
            }
        }
    }

    private var isConnected: Bool {
        bluetoothManager.connectionState == .connected
    }

    private var isDrillActive: Bool {
        switch bluetoothManager.drillState {
        case .armed, .running, .receiving: return true
        default: return false
        }
    }

    private var statusText: String {
        switch bluetoothManager.drillState {
        case .armed: return "Armed..."
        case .running: return "Running..."
        case .receiving: return "Receiving data..."
        default: return ""
        }
    }

    private var errorMessage: String? {
        if case .error(let msg) = bluetoothManager.drillState {
            return msg
        }
        return nil
    }

    private func runDrill() {
        let pwm = Int(pwmPercentText) ?? 0
        let clampedPwm = min(100, max(0, pwm))
        displayedData = []
        bluetoothManager.sendDrillCommand(
            durationSeconds: durationSeconds,
            pwmPercent: clampedPwm,
            direction: direction
        )
    }

    private func handleDrillStateChange(_ state: BluetoothManager.DrillState) {
        switch state {
        case .done:
            displayedData = bluetoothManager.drillEncoderData
        case .error:
            break  // errorMessage shows it
        default:
            break
        }
    }
}

/// Poster-style primary CTA.
private struct PosterHeroButtonStyle: ButtonStyle {
    let fill: LinearGradient

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.exo2Headline.weight(.bold))
            .foregroundStyle(Color.white.opacity(0.98))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.sm + 2)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                        .fill(fill)
                        .opacity(configuration.isPressed ? 0.86 : 1)
                    if configuration.isPressed {
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                            .opacity(0.8)
                            .scaleEffect(1.015)
                            .animation(nil, value: configuration.isPressed)
                    }
                }
            }
            .minimumTouchTarget(height: Theme.TouchTarget.minimum)
    }
}

private extension View {
    func minimumTouchTarget(height: CGFloat) -> some View {
        frame(minHeight: height)
            .contentShape(Rectangle())
    }
}

#Preview {
    TrainTabView(bluetoothManager: BluetoothManager())
}
