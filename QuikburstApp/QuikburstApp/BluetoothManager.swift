import Foundation
import CoreBluetooth
import Combine

// MARK: - ConnectionState

enum ConnectionState: String, Equatable, Codable, CaseIterable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}


// MARK: - BluetoothManager

final class BluetoothManager: NSObject, ObservableObject {
    // MARK: Published Properties
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published private(set) var connectedPeripheral: DiscoveredPeripheral?
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var pendingConnectionID: UUID?
    @Published private(set) var rxLog: [String] = []
    @Published private(set) var txLog: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastCompletion: CompletionMessage?
    @Published private(set) var lastAck: DrillAck?
    @Published private(set) var liveEncoderData: [EncoderData] = [] // Live streaming data (grows during drill)
    @Published private(set) var isLiveStreaming: Bool = false // True when live stream is active
    
    // Drill protocol (CONTROL.py / pwmAndEncoder.ino): DRILL,<s>,<pwm>,<F|B> → GO
    enum DrillState: Equatable {
        case idle
        case armed      // READY received
        case running    // RUNNING received, motor active
        case receiving  // DONE received, buffering DATA lines
        case done       // END received, data ready
        case error(String)
    }
    @Published private(set) var drillState: DrillState = .idle
    @Published private(set) var drillEncoderData: [EncoderData] = []  // Accumulated from DATA lines
    private var drillBaseTime: Date?  // Base timestamp for relative time_ms
    
    // Private state for live streaming
    private var liveStreamStartTime: Date?
    private var currentStreamId: UInt32 = 0

    // MARK: Private Properties
    private var central: CBCentralManager!
    private var peripheralMap: [UUID: DiscoveredPeripheral] = [:]
    private var currentPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var mtu: Int = 20
    // Nordic UART Service (NUS) - matches pwmAndEncoder.ino
    private let nusServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let nusRxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")  // Write
    private let nusTxUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")  // Notify
    private let queue = DispatchQueue(label: "BluetoothManagerQueue")
    private var receivedLineListeners: [UUID: (String) -> Void] = [:]
    private var lineRemainder: String = ""
    private var staleDeviceCleanupTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: Listener Management
    @discardableResult
    func addReceivedLineListener(_ listener: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        receivedLineListeners[id] = listener
        return id
    }

    func removeReceivedLineListener(_ id: UUID) {
        receivedLineListeners.removeValue(forKey: id)
    }

    // MARK: Public Methods
    func startScanning() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.central.state == .poweredOn && !self.isScanning {
                // Scan for all devices, then filter by name
                // This allows us to find Quickburst devices even if they don't advertise the service UUID
                self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                self.updateOnMain { 
                    self.isScanning = true
                    self.discoveredPeripherals.removeAll()
                    self.peripheralMap.removeAll()
                }
                // Start cleanup timer to remove stale devices
                self.startStaleDeviceCleanup()
            }
        }
    }
    
    private func startStaleDeviceCleanup() {
        // Stop existing timer if any
        staleDeviceCleanupTimer?.invalidate()
        
        // Clean up devices that haven't been seen in 3 seconds
        staleDeviceCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.queue.async {
                let now = Date()
                let staleThreshold: TimeInterval = 3.0 // Remove devices not seen in 3 seconds
                
                var removedAny = false
                for (uuid, peripheral) in self?.peripheralMap ?? [:] {
                    let timeSinceLastSeen = now.timeIntervalSince(peripheral.lastSeen)
                    if timeSinceLastSeen > staleThreshold {
                        // Device hasn't been seen recently, remove it
                        self?.peripheralMap.removeValue(forKey: uuid)
                        removedAny = true
                    }
                }
                
                if removedAny {
                    guard let peripheralMap = self?.peripheralMap else { return }
                    let sorted = Array(peripheralMap.values).sorted { $0.rssi > $1.rssi }
                    self?.updateOnMain {
                        self?.discoveredPeripherals = sorted
                    }
                }
            }
        }
    }
    
    func stopScanning() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isScanning {
                self.central.stopScan()
                self.updateOnMain { self.isScanning = false }
                // Stop cleanup timer
                self.staleDeviceCleanupTimer?.invalidate()
                self.staleDeviceCleanupTimer = nil
            }
        }
    }

    // stopScanning is now implemented above in startScanning

    func connect(to peripheral: DiscoveredPeripheral) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.updateOnMain {
                self.connectionState = .connecting
                self.pendingConnectionID = peripheral.id
            }
            // Stop scanning to reduce noise/power while connecting
            self.stopScanning()
            self.central.connect(peripheral.peripheral, options: nil)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self = self, let p = self.currentPeripheral else { return }
            self.updateOnMain { self.connectionState = .disconnecting }
            self.central.cancelPeripheralConnection(p)
        }
    }

    func send(_ text: String) {
        let timestamp = Date()
        queue.async { [weak self] in
            guard let self = self,
                  let peripheral = self.currentPeripheral,
                  let tx = self.txCharacteristic,
                  self.connectionState == .connected else {
                print("[BLE_TX] [\(timestamp)] FAILED - not connected or no characteristic")
                return
            }
            guard let data = text.data(using: .utf8) else {
                print("[BLE_TX] [\(timestamp)] ERROR - Could not encode string as UTF-8")
                self.updateOnMain { self.lastError = "Could not encode string as UTF-8." }
                return
            }
            
            // Extract message type for logging
            let msgType: String
            if text.contains("\"type\":\"keepalive\"") { msgType = "keepalive" }
            else if text.contains("\"type\":\"constantForce\"") { msgType = "constantForce" }
            else if text.contains("\"type\":\"stop\"") { msgType = "stop" }
            else if text.contains("\"type\":\"requestData\"") { msgType = "requestData" }
            else { msgType = "unknown" }
            
            print("[BLE_TX] [\(timestamp)] [\(msgType)] [\(data.count) bytes] Sending: \(text.prefix(100))")
            
            var offset = 0
            let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
            var chunkCount = 0
            while offset < data.count {
                let chunkSize = min(mtu, data.count - offset)
                let chunk = data.subdata(in: offset..<(offset + chunkSize))
                peripheral.writeValue(chunk, for: tx, type: .withResponse)
                chunkCount += 1
                offset += chunkSize
            }
            if chunkCount > 1 {
                print("[BLE_TX] [\(timestamp)] Split into \(chunkCount) chunks (MTU: \(mtu))")
            }
            self.updateOnMain { self.txLog.append(text) }
        }
    }
    
    // MARK: - New Protocol Command Support
    
    private func sendJSONCommand<T: Codable>(_ command: T) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let jsonData = try encoder.encode(command)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                send(jsonString + "\n")
            } else {
                updateOnMain { self.lastError = "Could not convert JSON to string." }
            }
        } catch {
            updateOnMain { self.lastError = "Could not encode command: \(error.localizedDescription)" }
        }
    }
    
    // Live Mode: Send duty cycle, no data back
    func sendLiveStart(_ command: LiveStartCommand) {
        sendJSONCommand(command)
    }
    
    // Live Mode: Send duty updates, no data back
    func sendLiveMode(_ command: LiveModeCommand) {
        sendJSONCommand(command)
    }
    
    // Constant Force: Send specification with force, ESP32 executes and reports
    func sendConstantForce(_ command: ConstantForceCommand) {
        sendJSONCommand(command)
    }
    
    // Percentage Baseline: Send time/distance only, ESP32 captures baseline
    func sendPercentageBaseline(_ command: PercentageBaselineCommand) {
        sendJSONCommand(command)
    }
    
    // Percentage Execution: Send calculated force after baseline
    func sendPercentageExecution(_ command: PercentageExecutionCommand) {
        sendJSONCommand(command)
    }
    
    // Stop command
    func sendStop() {
        sendJSONCommand(StopCommand())
    }
    
    // MARK: - Drill Protocol (CONTROL.py / pwmAndEncoder.ino)
    
    /// Start a drill: DRILL,<seconds>,<pwm>,<F|B>. GO is sent automatically when READY received.
    func sendDrillCommand(durationSeconds: Int, pwmPercent: Int, direction: String) {
        let dir = direction.uppercased().contains("B") ? "B" : "F"
        let cmd = "DRILL,\(durationSeconds),\(pwmPercent),\(dir)\n"
        updateOnMain {
            self.drillState = .idle
            self.drillEncoderData = []
        }
        drillBaseTime = Date()
        send(cmd)
    }
    
    /// Arm then start: send GO after READY is received.
    func sendGo() {
        send("GO\n")
    }
    
    /// Abort in-progress drill.
    func sendAbort() {
        send("ABORT\n")
    }
    
    // Request data command
    func requestData(id: UInt32) {
        struct RequestDataCommand: Codable {
            let type: String
            let id: UInt32
        }
        sendJSONCommand(RequestDataCommand(type: "requestData", id: id))
    }
    
    /// Parse completion message from ESP32
    func parseCompletion(_ jsonString: String) -> CompletionMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(CompletionMessage.self, from: data)
        } catch {
            return nil
        }
    }
    
    /// Parse ack message from ESP32
    func parseAck(_ jsonString: String) -> DrillAck? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(DrillAck.self, from: data)
        } catch {
            return nil
        }
    }

    func clearLogs() {
        updateOnMain {
            self.rxLog.removeAll()
            self.txLog.removeAll()
        }
    }

    // MARK: Helpers
    private func updateOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async { block() }
        }
    }

    func resetBatchData() {
        updateOnMain {
            self.liveEncoderData = []
            self.isLiveStreaming = false
        }
        liveStreamStartTime = nil
        currentStreamId = 0
    }
    
    func clearLiveStream() {
        updateOnMain {
            self.liveEncoderData = []
            self.isLiveStreaming = false
        }
        liveStreamStartTime = nil
        currentStreamId = 0
    }
    
    private func resetStateOnDisconnect() {
        updateOnMain {
            self.connectionState = .disconnected
            self.connectedPeripheral = nil
            self.currentPeripheral = nil
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
            self.lineRemainder = ""
            self.lastCompletion = nil
            self.lastAck = nil
            self.liveEncoderData = []
            self.isLiveStreaming = false
            self.drillState = .idle
            self.drillEncoderData = []
        }
        liveStreamStartTime = nil
        currentStreamId = 0
        drillBaseTime = nil
    }
    
    /// Parse data start message
    func parseDataStart(_ jsonString: String) -> DataStartMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(DataStartMessage.self, from: data)
        } catch {
            return nil
        }
    }
    
    /// Parse metadata message
    func parseMetadata(_ jsonString: String) -> MetadataMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(MetadataMessage.self, from: data)
        } catch {
            return nil
        }
    }
    
    /// Parse data chunk message
    func parseDataChunk(_ jsonString: String) -> DataChunkMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(DataChunkMessage.self, from: data)
        } catch {
            return nil
        }
    }
    
    /// Parse data end message
    func parseDataEnd(_ jsonString: String) -> DataEndMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(DataEndMessage.self, from: data)
        } catch {
            return nil
        }
    }
    
    /// Process pwmAndEncoder.ino text protocol lines. Returns true if line was handled.
    private func processDrillProtocolLine(_ line: String) -> Bool {
        if line.hasPrefix("READY,") {
            updateOnMain { self.drillState = .armed }
            send("GO\n")
            return true
        }
        if line == "RUNNING" {
            updateOnMain { self.drillState = .running }
            return true
        }
        if line == "DONE" {
            updateOnMain { self.drillState = .receiving }
            return true
        }
        if line.hasPrefix("DATA,") {
            let parts = line.split(separator: ",")
            guard parts.count >= 6 else { return true }
            guard let timeMs = Int(parts[2]),
                  let pos = Double(String(parts[3])),
                  let vel = Double(String(parts[4])),
                  let acc = Double(String(parts[5])) else { return true }
            let base = drillBaseTime ?? Date()
            let timestamp = base.addingTimeInterval(Double(timeMs) / 1000.0)
            let encoderData = EncoderData(
                timestamp: timestamp,
                position: pos,
                velocity: vel,
                rpm: 0,
                acceleration: acc,
                counts: 0
            )
            updateOnMain {
                self.drillEncoderData.append(encoderData)
            }
            return true
        }
        if line == "END" {
            updateOnMain { self.drillState = .done }
            return true
        }
        if line == "ABORTED" {
            updateOnMain { self.drillState = .error("Aborted") }
            return true
        }
        if line.hasPrefix("ERROR,") {
            let reason = String(line.dropFirst(6))
            updateOnMain { self.drillState = .error(reason) }
            return true
        }
        return false
    }
    
    /// Reset drill state for a new run. Call before sending DRILL.
    func resetDrillState() {
        updateOnMain {
            self.drillState = .idle
            self.drillEncoderData = []
        }
        drillBaseTime = nil
    }

}

// MARK: - CBCentralManagerDelegate, CBPeripheralDelegate

extension BluetoothManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateOnMain {
            self.bluetoothState = central.state
            if central.state != .poweredOn {
                self.stopScanning()
                self.resetStateOnDisconnect()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                       advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard RSSI.intValue != 127 else { return }
        
        // Extract device name from advertisement data or peripheral name
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let peripheralName = peripheral.name ?? advertisedName ?? ""
        let name = peripheralName.isEmpty ? "Unnamed" : peripheralName
        let uuid = peripheral.identifier

        // Filter for Quickburst devices only (case-insensitive)
        let nameLower = name.lowercased()
        guard nameLower.contains("quickburst") || nameLower.contains("quikburst") else {
            return
        }

        // De-dupe and update RSSI on rediscovery
        var updated = false
        let now = Date()
        if peripheralMap[uuid] != nil {
            // Update existing peripheral with new RSSI and lastSeen time
            let updatedPeripheral = DiscoveredPeripheral(id: uuid, name: name, rssi: RSSI.intValue, peripheral: peripheral, lastSeen: now)
            peripheralMap[uuid] = updatedPeripheral
            updated = true
        } else {
            // New peripheral found
            let found = DiscoveredPeripheral(id: uuid, name: name, rssi: RSSI.intValue, peripheral: peripheral, lastSeen: now)
            peripheralMap[uuid] = found
            updated = true
        }
        if updated {
            let sorted = Array(peripheralMap.values).sorted { $0.rssi > $1.rssi }
            updateOnMain {
                self.discoveredPeripherals = sorted
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        updateOnMain {
            self.connectionState = .connected
            self.lastError = nil
            self.pendingConnectionID = nil
        }
        self.currentPeripheral = peripheral
        peripheral.delegate = self
        
        // Request larger MTU for better throughput (matches ESP32 MTU setting)
        if #available(iOS 11.0, *) {
            peripheral.readRSSI() // Keep connection active
        }
        
        peripheral.discoverServices(nil)
        updateOnMain {
            if let match = self.peripheralMap[peripheral.identifier] {
                self.connectedPeripheral = match
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        updateOnMain {
            self.lastError = "Failed to connect: \(error?.localizedDescription ?? "Unknown error")"
            self.connectionState = .disconnected
            self.connectedPeripheral = nil
            self.pendingConnectionID = nil
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let timestamp = Date()
        if let error = error {
            print("[CONNECTION] [\(timestamp)] DISCONNECTED with error: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("[CONNECTION] [\(timestamp)] Error domain: \(nsError.domain), code: \(nsError.code)")
            }
        } else {
            print("[CONNECTION] [\(timestamp)] DISCONNECTED (no error)")
        }
        updateOnMain {
            if let error = error {
                self.lastError = "Disconnected: \(error.localizedDescription)"
            }
            self.pendingConnectionID = nil
            self.resetStateOnDisconnect()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            updateOnMain { self.lastError = "Service discovery failed: \(error!.localizedDescription)" }
            self.disconnect()
            return
        }
        guard let services = peripheral.services else {
            updateOnMain { self.lastError = "No services found" }
            self.disconnect()
            return
        }
        // Prefer NUS (pwmAndEncoder.ino), fallback to first found
        let service = services.first(where: { $0.uuid == nusServiceUUID }) ?? services.first
        guard let useService = service else {
            updateOnMain { self.lastError = "BLE service not found" }
            self.disconnect()
            return
        }
        peripheral.discoverCharacteristics(nil, for: useService)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            updateOnMain { self.lastError = "Characteristic discovery failed: \(error!.localizedDescription)" }
            self.disconnect()
            return
        }
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            updateOnMain { self.lastError = "No characteristics found" }
            self.disconnect()
            return
        }
        // NUS: RX=write (6E400002), TX=notify (6E400003)
        let tx = characteristics.first(where: { $0.uuid == nusRxUUID && $0.properties.contains(.write) }) ??
            characteristics.first(where: { $0.properties.contains(.write) })
        let rx = characteristics.first(where: { $0.uuid == nusTxUUID && $0.properties.contains(.notify) }) ??
            characteristics.first(where: { $0.properties.contains(.notify) })
        self.txCharacteristic = tx
        self.rxCharacteristic = rx
        // Subscribe for notifications
        if let rx = rx {
            peripheral.setNotifyValue(true, for: rx)
        }
        // Check for missing required
        if tx == nil || rx == nil {
            updateOnMain { self.lastError = "Required TX/RX characteristics not found" }
            self.disconnect()
            return
        }
        
        // Ready for commands
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let timestamp = Date()
        guard error == nil else {
            print("[BLE_RX] [\(timestamp)] ERROR: \(error!.localizedDescription)")
            updateOnMain { self.lastError = "Notification error: \(error!.localizedDescription)" }
            return
        }
        guard let data = characteristic.value, !data.isEmpty else {
            print("[BLE_RX] [\(timestamp)] WARNING: Empty data received")
            return
        }
        let str: String
        if let s = String(data: data, encoding: .utf8) {
            str = s
        } else {
            str = data.map { String(format: "%02hhX", $0) }.joined(separator: " ")
        }
        
        print("[BLE_RX] [\(timestamp)] [\(data.count) bytes] Raw chunk: \(str.prefix(100))")
        
        updateOnMain {
            // Log raw chunk to console
            self.rxLog.append(str)
            // Accumulate and emit complete lines to listeners
            self.lineRemainder += str
            let parts = self.lineRemainder.components(separatedBy: .newlines)
            // Keep the last part as remainder (may be empty if chunk ended with a newline)
            self.lineRemainder = parts.last ?? ""
            let completeLines = parts.dropLast()
            for line in completeLines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                
                // Extract message type for logging
                let msgType: String
                if trimmed.contains("\"type\":\"keepalive\"") { msgType = "keepalive" }
                else if trimmed.contains("\"type\":\"dataStart\"") { msgType = "dataStart" }
                else if trimmed.contains("\"type\":\"dataEnd\"") { msgType = "dataEnd" }
                else if trimmed.contains("\"type\":\"dataChunk\"") { msgType = "dataChunk" }
                else if trimmed.contains("\"type\":\"metadata\"") { msgType = "metadata" }
                else if trimmed.contains("\"type\":\"ack\"") { msgType = "ack" }
                else if trimmed.contains("\"type\":\"completion\"") { msgType = "completion" }
                else if trimmed.contains("\"type\":\"connectionStatus\"") { msgType = "connectionStatus" }
                else { msgType = "unknown" }
                
                print("[BLE_RX] [\(Date())] [\(msgType)] Parsed: \(trimmed.prefix(150))")
                
                // Drill protocol (pwmAndEncoder.ino text protocol) - check first
                if self.processDrillProtocolLine(trimmed) {
                    // Handled by drill protocol
                } else if let dataStart = self.parseDataStart(trimmed) {
                    print("[BLE_RX] [\(Date())] [dataStart] ID: \(dataStart.id) - Starting live stream")
                    // Start of live streaming - clear previous data
                    self.currentStreamId = dataStart.id
                    self.liveStreamStartTime = Date()
                    self.updateOnMain {
                        self.isLiveStreaming = true
                        self.liveEncoderData = []
                    }
                } else if let metadata = self.parseMetadata(trimmed) {
                    // Metadata received (informational only)
                    print("[BLE_RX] [\(Date())] [metadata] countsPerRev=\(metadata.countsPerRev), spoolRadiusM=\(metadata.spoolRadiusM), sampleIntervalMs=\(metadata.sampleIntervalMs)")
                } else if let dataChunk = self.parseDataChunk(trimmed) {
                    // Process LIVE STREAMING data chunks (one sample per chunk from ESP32)
                    if dataChunk.id == self.currentStreamId {
                        // Process each data point in the chunk (usually just one)
                        for point in dataChunk.data {
                            // Convert to EncoderData with timestamp
                            let timestamp = self.liveStreamStartTime?.addingTimeInterval(Double(point.t) / 1000.0) ?? Date()
                            let encoderData = EncoderData(
                                timestamp: timestamp,
                                position: point.position,
                                velocity: point.velocity,
                                rpm: point.rpm,
                                acceleration: point.acceleration,
                                counts: point.counts
                            )
                            
                            // Add to live stream IMMEDIATELY
                            self.updateOnMain {
                                self.liveEncoderData.append(encoderData)
                            }
                        }
                    } else {
                        print("[BLE_RX] [\(Date())] [dataChunk] WARNING: ID mismatch (expected \(self.currentStreamId), got \(dataChunk.id)) - chunk ignored")
                    }
                } else if let dataEnd = self.parseDataEnd(trimmed) {
                    print("[BLE_RX] [\(Date())] [dataEnd] ID: \(dataEnd.id) - Live stream ended, total samples: \(self.liveEncoderData.count)")
                    // End of live streaming
                    if dataEnd.id == self.currentStreamId {
                        self.updateOnMain {
                            self.isLiveStreaming = false
                        }
                        // Keep liveEncoderData for post-drill display
                        self.liveStreamStartTime = nil
                    } else {
                        print("[BLE_RX] [\(Date())] [dataEnd] WARNING: ID mismatch (expected \(self.currentStreamId), got \(dataEnd.id))")
                    }
                } else if trimmed.contains("\"type\":\"keepalive\"") {
                    print("[BLE_RX] [\(Date())] [keepalive] Received keepalive from ESP32")
                } else if let ack = self.parseAck(trimmed) {
                    print("[BLE_RX] [\(Date())] [ack] ID: \(ack.id ?? 0), Status: \(ack.status)")
                    self.updateOnMain {
                        self.lastAck = ack
                    }
                } else if let completion = self.parseCompletion(trimmed) {
                    print("[BLE_RX] [\(Date())] [completion] ID: \(completion.id), Reason: \(completion.reason)")
                    self.updateOnMain {
                        self.lastCompletion = completion
                    }
                }
                
                // Forward to all listeners - always forward encoder data
                for listener in self.receivedLineListeners.values { listener(trimmed) }
            }
        }
    }
    
}