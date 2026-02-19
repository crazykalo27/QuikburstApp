import SwiftUI
import CoreBluetooth
import Foundation

struct BluetoothConsoleView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var message: String = ""
    @State private var autoScrollToBottom: Bool = true
    
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Bluetooth state + scan button
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(stateColor)
                            .frame(width: 8, height: 8)
                        Text("Bluetooth: \(stateText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                
                HStack {
                    if bluetooth.bluetoothState == .poweredOn {
                        if bluetooth.isScanning {
                            Button {
                                bluetooth.stopScanning()
                            } label: {
                                Label("Stop Scanning", systemImage: "stop.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        } else {
                            Button {
                                bluetooth.startScanning()
                            } label: {
                                Label("Scan for Devices", systemImage: "magnifyingglass")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                    } else {
                        Button {
                            // Try to start scanning anyway - might prompt user to enable Bluetooth
                            bluetooth.startScanning()
                        } label: {
                            Label("Enable Bluetooth to Scan", systemImage: "exclamationmark.triangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            
            // Device list or connection status
            if bluetooth.connectedPeripheral == nil {
                if bluetooth.discoveredPeripherals.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: bluetooth.bluetoothState == .poweredOn ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text(bluetooth.bluetoothState == .poweredOn ? "No devices found" : "Bluetooth Not Available")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(bluetooth.bluetoothState == .poweredOn ? "Press 'Scan for Devices' to search for Quickburst devices" : "Please enable Bluetooth in Settings to scan for devices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    List {
                        Section(header: Text("Nearby Devices")) {
                            ForEach(bluetooth.discoveredPeripherals) { peripheral in
                                let isConnecting = bluetooth.connectionState == .connecting && bluetooth.pendingConnectionID == peripheral.id
                                BluetoothRowView(
                                    peripheral: peripheral,
                                    isConnected: false,
                                    isConnecting: isConnecting
                                ) {
                                    bluetooth.connect(to: peripheral)
                                }
                                .disabled(isConnecting)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .frame(maxHeight: 280)
                }
            } else if let connected = bluetooth.connectedPeripheral {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(connectionStatusColor)
                                    .frame(width: 8, height: 8)
                                Text(connectionStatusText)
                                    .font(.headline)
                            }
                            Text(connected.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Signal: \(connected.rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // Show live streaming status if available
                            if bluetooth.isLiveStreaming {
                                Text("Live Streaming")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .padding(.top, 2)
                            }
                        }
                        Spacer()
                        Button("Disconnect", role: .destructive, action: bluetooth.disconnect)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if bluetooth.connectionState == .connecting {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Connecting...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            
            Divider()
            
            // Terminal log - scrollable area above keyboard
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Console Log")
                        .font(.headline)
                    Spacer()
                    Toggle("Auto-scroll", isOn: $autoScrollToBottom)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                
                TerminalLogView(rxLog: bluetooth.rxLog, txLog: bluetooth.txLog, autoScrollToBottom: $autoScrollToBottom)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Dismiss keyboard when tapping on console
                        isTextFieldFocused = false
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Input section - fixed at bottom
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Type a message...", text: $message)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            sendMessage()
                        }
                    Button("Send") {
                        sendMessage()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bluetooth.connectedPeripheral == nil)
                }
                
                HStack {
                    Button("Clear Log", role: .destructive) {
                        bluetooth.clearLogs()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        copyLogsToClipboard()
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Spacer()
                    
                    if let error = bluetooth.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Bluetooth Console")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func sendMessage() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            bluetooth.send(trimmed + "\n")
            message = ""
        }
    }
    
    private func copyLogsToClipboard() {
        let combinedLogs = (bluetooth.txLog.map { "→ \($0)" } + bluetooth.rxLog.map { "← \($0)" }).joined(separator: "\n")
        UIPasteboard.general.string = combinedLogs
    }
    
    private var stateText: String {
        switch bluetooth.bluetoothState {
        case .poweredOn: return "On"
        case .poweredOff: return "Off"
        case .resetting: return "Resetting"
        case .unauthorized: return "Unauthorized"
        case .unsupported: return "Unsupported"
        case .unknown: return "Unknown"
        @unknown default: return "Other"
        }
    }
    
    private var stateColor: Color {
        switch bluetooth.bluetoothState {
        case .poweredOn: return .green
        case .poweredOff, .unauthorized, .unsupported: return .red
        default: return .orange
        }
    }
    
    private var connectionStatusColor: Color {
        switch bluetooth.connectionState {
        case .connected: return .green
        case .disconnected: return .red
        case .connecting: return .orange
        case .disconnecting: return .orange
        }
    }
    
    private var connectionStatusText: String {
        switch bluetooth.connectionState {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        }
    }
}

struct BluetoothRowView: View {
    let peripheral: DiscoveredPeripheral
    let isConnected: Bool
    let isConnecting: Bool
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading) {
                Text(peripheral.name.isEmpty ? "(Unnamed)" : peripheral.name)
                    .fontWeight(isConnected ? .bold : .regular)
                Text(peripheral.id.uuidString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(peripheral.rssi) dBm")
                .foregroundStyle(.secondary)
            if isConnected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if isConnecting {
                ProgressView()
            } else {
                Button("Connect", action: onConnect)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TerminalLogView: View {
    let rxLog: [String]
    let txLog: [String]
    @Binding var autoScrollToBottom: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(zip(txLog.indices, txLog)), id: \.0) { idx, tx in
                        Text("→ \(tx)").foregroundStyle(.blue)
                    }
                    ForEach(Array(zip(rxLog.indices, rxLog)), id: \.0) { idx, rx in
                        Text("← \(rx)").foregroundStyle(.primary)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal)
            }
            .onChange(of: rxLog.count) { _, _ in
                if autoScrollToBottom {
                    withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
            }
            .onChange(of: txLog.count) { _, _ in
                if autoScrollToBottom {
                    withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
            }
            .onAppear {
                if autoScrollToBottom {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
        }
    }
}

#Preview {
    BluetoothConsoleView(bluetooth: BluetoothManager())
}
