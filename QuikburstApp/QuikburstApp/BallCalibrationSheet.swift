import SwiftUI
import AVKit

enum BallCalibrationPhase: Equatable {
    case holdBall
    case waitingStill
    case finishing
}

/// What to show on the calibration sheet (driven by local wizard phase + ESP32 GET_STATUS).
enum BallCalibrationUIMode: Equatable {
    case pullAndConfirm
    case holdStill
    case saving
    case armed
    case calibrated
}

/// Looping calibration clip — add `arm_video.mp4` to the QuikburstApp target (file lives beside this source file).
private struct CalibrationLoopingVideo: View {
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.2))
                    .overlay {
                        Text("Add arm_video.mp4 to the app target")
                            .font(Theme.Typography.exo2Caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.textSecondary)
                            .padding()
                    }
            }
        }
        .onAppear { setupPlayer() }
    }

    private func setupPlayer() {
        guard player == nil,
              let url = Bundle.main.url(forResource: "arm_video", withExtension: "mp4")
        else { return }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer(playerItem: item)
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
    }
}

struct BallCalibrationSheet: View {
    let isConnected: Bool
    let uiMode: BallCalibrationUIMode
    @Binding var overrideHolding: Bool
    let onPressOverride: () -> Void
    let onReleaseOverride: () -> Void
    let onConfirmBallSeated: () -> Void
    let onAbort: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    headerText

                    CalibrationLoopingVideo()
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous))

                    modeContent
                }
                .padding()
            }
            .scrollDisabled(overrideHolding)
            .navigationTitle("Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(uiMode == .pullAndConfirm ? "Cancel" : "Done") {
                        onDismiss()
                    }
                }
            }
        }
        .supportsKeyboardDismiss()
    }

    @ViewBuilder
    private var headerText: some View {
        switch uiMode {
        case .pullAndConfirm:
            Text("Press the ball against the device as shown, then confirm.")
                .font(Theme.Typography.exo2Subheadline)
                .foregroundStyle(Theme.textSecondary)
        case .holdStill:
            Text("Hold the ball steady while the rope stops moving.")
                .font(Theme.Typography.exo2Subheadline)
                .foregroundStyle(Theme.textSecondary)
        case .saving:
            Text("Saving calibration on the device…")
                .font(Theme.Typography.exo2Subheadline)
                .foregroundStyle(Theme.textSecondary)
        case .armed:
            Text("The motor is armed with light tension. Use Abort to disarm before adjusting the ball.")
                .font(Theme.Typography.exo2Subheadline)
                .foregroundStyle(Theme.textSecondary)
        case .calibrated:
            Text("Ball is calibrated on the device. You can train, or open this screen again to check status.")
                .font(Theme.Typography.exo2Subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch uiMode {
        case .pullAndConfirm:
            pullAndConfirmSection
        case .holdStill:
            holdStillSection
        case .saving:
            savingSection
        case .armed:
            armedSection
        case .calibrated:
            calibratedSection
        }
    }

    private var pullAndConfirmSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Hold Pull in until the ball is seated against the stop with light tension — same as the video.")
                .font(Theme.Typography.exo2Body)

            HoldDownButton(
                enabled: isConnected,
                isHeld: $overrideHolding,
                onHoldStart: onPressOverride,
                onHoldEnd: onReleaseOverride
            ) {
                Text(overrideHolding ? "Pulling in…" : "Hold to pull in")
                    .font(Theme.Typography.exo2Headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(overrideHolding ? Color.orange.opacity(0.75) : Color.orange.opacity(0.3))
                    .foregroundStyle(isConnected ? .primary : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, minHeight: 52)

            Button("Confirm ball is calibrated") {
                onConfirmBallSeated()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!isConnected)
        }
    }

    private var holdStillSection: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Hold steady… waiting for rope to stop moving")
                .font(Theme.Typography.exo2Body)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var savingSection: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Zeroing encoder and saving setpoint…")
                .font(Theme.Typography.exo2Body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var armedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label("System armed", systemImage: "bolt.fill")
                .font(Theme.Typography.exo2Headline)
                .foregroundStyle(.orange)

            Button("Abort — disarm motor") {
                onAbort()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!isConnected)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
    }

    private var calibratedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label("Calibrated", systemImage: "checkmark.circle.fill")
                .font(Theme.Typography.exo2Headline)
                .foregroundStyle(.green)

            Button("Recalibrate") {
                onDismiss()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}
