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

    // MARK: Private Properties
    private var central: CBCentralManager!
    private var peripheralMap: [UUID: DiscoveredPeripheral] = [:]
    private var currentPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var mtu: Int = 20
    private let serviceUUID = CBUUID(string: "FFE0")
    private let characteristicUUID = CBUUID(string: "FFE1")
    private let queue = DispatchQueue(label: "BluetoothManagerQueue")
    private var receivedLineListeners: [UUID: (String) -> Void] = [:]
    private var lineRemainder: String = ""

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
            }
        }
    }

    func stopScanning() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isScanning {
                self.central.stopScan()
                self.updateOnMain { self.isScanning = false }
            }
        }
    }

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
        queue.async { [weak self] in
            guard let self = self,
                  let peripheral = self.currentPeripheral,
                  let tx = self.txCharacteristic,
                  self.connectionState == .connected else { return }
            guard let data = text.data(using: .utf8) else {
                self.updateOnMain { self.lastError = "Could not encode string as UTF-8." }
                return
            }
            var offset = 0
            let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
            while offset < data.count {
                let chunkSize = min(mtu, data.count - offset)
                let chunk = data.subdata(in: offset..<(offset + chunkSize))
                peripheral.writeValue(chunk, for: tx, type: .withResponse)
                offset += chunkSize
            }
            self.updateOnMain { self.txLog.append(text) }
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

    private func resetStateOnDisconnect() {
        updateOnMain {
            self.connectionState = .disconnected
            self.connectedPeripheral = nil
            self.currentPeripheral = nil
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
            self.lineRemainder = ""
        }
    }

    func sensorSamplesStream() -> AsyncStream<SensorSample> {
        // Capture a weak reference to self to avoid retaining across the stream lifetime
        weak var weakSelf = self
        return AsyncStream { continuation in
            // Avoid capturing self in the @Sendable closure by copying the listener closure locally
            let listener: (String) -> Void = { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Skip control messages
                if trimmed.hasPrefix("TRIAL_") || trimmed.hasPrefix("QUICKBURST_") || trimmed.hasPrefix("RESET_") {
                    return
                }
                
                // Parse CSV format: time_ms,counts
                let parts = trimmed.split(separator: ",")
                if parts.count == 2,
                   let timeMs = Double(parts[0]),
                   let counts = Double(parts[1]) {
                    // Use counts as the value, timestamp relative to now
                    let sample = SensorSample(timestamp: Date(), value: counts)
                    continuation.yield(sample)
                } else {
                    // Fallback: try parsing as single numeric value
                    if let value = Double(trimmed) {
                        let sample = SensorSample(timestamp: Date(), value: value)
                        continuation.yield(sample)
                    }
                }
            }
            // Register the listener via the weak reference
            let token = weakSelf?.addReceivedLineListener(listener)

            // Use onTermination without capturing strong self; hop to main when needed
            continuation.onTermination = { _ in
                guard let token = token else { return }
                Task { @MainActor in
                    weakSelf?.removeReceivedLineListener(token)
                }
            }
        }
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
        if peripheralMap[uuid] != nil {
            let updatedPeripheral = DiscoveredPeripheral(id: uuid, name: name, rssi: RSSI.intValue, peripheral: peripheral)
            peripheralMap[uuid] = updatedPeripheral
            updated = true
        } else {
            let found = DiscoveredPeripheral(id: uuid, name: name, rssi: RSSI.intValue, peripheral: peripheral)
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
        // Prefer FFE0, but fallback to first found
        let service = services.first(where: { $0.uuid == serviceUUID }) ?? services.first
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
        // Find TX/RX by FFE1, fallback to notify/write
        let tx = characteristics.first(where: { $0.uuid == characteristicUUID && $0.properties.contains(.write) }) ??
            characteristics.first(where: { $0.properties.contains(.write) })
        let rx = characteristics.first(where: { $0.uuid == characteristicUUID && $0.properties.contains(.notify) }) ??
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
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            updateOnMain { self.lastError = "Notification error: \(error!.localizedDescription)" }
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        let str: String
        if let s = String(data: data, encoding: .utf8) {
            str = s
        } else {
            str = data.map { String(format: "%02hhX", $0) }.joined(separator: " ")
        }
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
                for listener in self.receivedLineListeners.values { listener(line) }
            }
        }
    }
}