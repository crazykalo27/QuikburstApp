import SwiftUI
import Charts

struct LiveChartView: View {
    @StateObject private var vm: DataStreamViewModel
    @ObservedObject var manager: BluetoothManager
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var runStore: RunStore
    @State private var selectedProfileId: UUID?
    @State private var isRecording = false
    @State private var recordingStartTime: Date?
    @State private var showingSaveDialog = false
    @State private var pendingRunData: (duration: TimeInterval, averageValue: Double, peakValue: Double)?

    init(manager: BluetoothManager) {
        _vm = StateObject(wrappedValue: DataStreamViewModel(manager: manager))
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        VStack(spacing: 0) {
            // User selection dropdown at top
            HStack {
                Menu {
                    Text("Select User")
                        .font(.headline)
                    Divider()
                    if profileStore.users.isEmpty {
                        Text("No users available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profileStore.users) { user in
                            Button {
                                profileStore.selectUser(user.id)
                            } label: {
                                HStack {
                                    Text(user.name)
                                    if profileStore.selectedUserId == user.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.circle")
                            .font(.subheadline)
                        Text(selectedUserName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            
            // Connection status
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 10, height: 10)
                Text(connectionStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            
            // Chart area
            Chart(vm.windowedSamples) {
                LineMark(
                    x: .value("Time", $0.timestamp),
                    y: .value("Value", $0.value)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.blue)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5))
            }
            .chartYScale(domain: .automatic)
            .frame(maxHeight: .infinity)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .transaction { $0.animation = nil }
            
            // Control panel
            VStack(spacing: 12) {
                // Profile selection
                Menu {
                    Text("Choose Profile")
                        .font(.headline)
                    Divider()
                    if profileStore.profiles.isEmpty {
                        Text("No profiles available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profileStore.profiles) { profile in
                            Button {
                                selectedProfileId = profile.id
                            } label: {
                                HStack {
                                    Text(profile.name)
                                    if selectedProfileId == profile.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedProfileName)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray5))
                    .cornerRadius(8)
                }
                
                // Primary controls
                HStack(spacing: 12) {
                    Button {
                        startRecording()
                    } label: {
                        Label("Start", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(manager.connectedPeripheral == nil || isRecording)

                    Button {
                        stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!isRecording)
                }
                
                // Secondary controls
                HStack(spacing: 12) {
                    Button {
                        // TODO: Mark session
                    } label: {
                        Label("Marker", systemImage: "flag")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Menu {
                        Button {
                            // TODO: Save snapshot
                        } label: {
                            Label("Save Snapshot", systemImage: "camera")
                        }
                        Button {
                            // TODO: Reset chart
                        } label: {
                            Label("Reset View", systemImage: "arrow.uturn.backward")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Live Stream")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    // TODO: Open export sheet
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .alert("Save Recording?", isPresented: $showingSaveDialog) {
            Button("Don't Save", role: .destructive) {
                discardRecording()
            }
            Button("Save") {
                saveRecording()
            }
            Button("Cancel", role: .cancel) {
                // Keep data pending, user can try again
            }
        } message: {
            if let data = pendingRunData {
                Text("Duration: \(Int(data.duration))s\nAverage: \(String(format: "%.2f", data.averageValue))\nPeak: \(String(format: "%.2f", data.peakValue))")
            } else {
                Text("Would you like to save this recording?")
            }
        }
    }
    
    private func startRecording() {
        manager.send("START")
        vm.start()
        isRecording = true
        recordingStartTime = Date()
    }
    
    private func stopRecording() {
        manager.send("STOP")
        vm.stop()
        isRecording = false
        
        // Calculate statistics from samples collected during recording
        if let startTime = recordingStartTime {
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            
            // Get samples that were collected during this recording session (within time window)
            // Add a small buffer to account for timing differences
            let buffer: TimeInterval = 0.5
            let recordingSamples = vm.windowedSamples.filter { sample in
                sample.timestamp >= startTime.addingTimeInterval(-buffer) && sample.timestamp <= endTime.addingTimeInterval(buffer)
            }
            let values = recordingSamples.map { $0.value }
            
            guard !values.isEmpty else {
                recordingStartTime = nil
                return
            }
            
            let averageValue = values.reduce(0, +) / Double(values.count)
            let peakValue = values.max() ?? 0
            
            pendingRunData = (duration: duration, averageValue: averageValue, peakValue: peakValue)
            showingSaveDialog = true
        }
    }
    
    private func saveRecording() {
        guard let data = pendingRunData else { return }
        
        let run = RunRecord(
            date: recordingStartTime ?? Date(),
            duration: data.duration,
            averageValue: data.averageValue,
            peakValue: data.peakValue,
            userId: profileStore.selectedUserId
        )
        
        runStore.append(run)
        
        // Reset
        pendingRunData = nil
        recordingStartTime = nil
    }
    
    private func discardRecording() {
        pendingRunData = nil
        recordingStartTime = nil
    }
    
    private var connectionStatusText: String {
        if let peripheral = manager.connectedPeripheral {
            return "Connected: \(peripheral.name)"
        } else {
            return "No device connected"
        }
    }
    
    private var connectionStatusColor: Color {
        manager.connectedPeripheral != nil ? .green : .red
    }
    
    private var selectedProfileName: String {
        if let id = selectedProfileId,
           let profile = profileStore.profiles.first(where: { $0.id == id }) {
            return profile.name
        }
        return "Choose Profile"
    }
    
    private var selectedUserName: String {
        if let user = profileStore.selectedUser {
            return user.name
        }
        return "Select User"
    }
}

#Preview {
    LiveChartView(manager: BluetoothManager())
        .environmentObject(ProfileStore())
}
