import SwiftUI

/// Train tab: matches CONTROL.py / pwmAndEncoder.ino protocol.
/// User pairs in Profiles → Device Pairing. Here: pick direction, time, pwm → run → view plots.
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
            ScrollView {
                VStack(spacing: 16) {
                    connectionStatus
                    controlSection
                    dataSection
                }
                .padding()
                .contentShape(Rectangle())
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    isConfirmingStart = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Train")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: bluetoothManager.drillState) { _, newState in
                handleDrillStateChange(newState)
            }
        }
    }
    
    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Connected" : "Disconnected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run")
                .font(.headline)
            
            // Direction
            Picker("Direction", selection: $direction) {
                Text("Forward").tag("F")
                Text("Backward").tag("B")
            }
            .pickerStyle(.segmented)
            
            // Duration 1–10 seconds
            VStack(alignment: .leading) {
                Text("Duration (seconds)")
                Picker("Duration", selection: $durationSeconds) {
                    ForEach(1...10, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            // PWM 0–100%
            VStack(alignment: .leading) {
                Text("PWM (%)")
                TextField("0–100", text: $pwmPercentText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            
            Button(isDrillActive ? "Stop" : (isConfirmingStart ? "Confirm" : "Run")) {
                if isDrillActive {
                    bluetoothManager.sendAbort()
                } else if isConfirmingStart {
                    runDrill()
                    isConfirmingStart = false
                } else {
                    isConfirmingStart = true
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isConnected)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data")
                .font(.headline)
            
            if isDrillActive {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if let err = errorMessage {
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else if displayedData.isEmpty {
                Text("Run a drill to see graphs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LiveEncoderGraphsView(encoderData: displayedData)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

#Preview {
    TrainTabView(bluetoothManager: BluetoothManager())
}
