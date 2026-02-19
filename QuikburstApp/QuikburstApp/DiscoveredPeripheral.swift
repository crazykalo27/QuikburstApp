import Foundation
import CoreBluetooth

struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
    let lastSeen: Date // Track when device was last seen during scanning

    init(id: UUID, name: String, rssi: Int, peripheral: CBPeripheral, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.peripheral = peripheral
        self.lastSeen = lastSeen
    }

    static func ==(lhs: DiscoveredPeripheral, rhs: DiscoveredPeripheral) -> Bool {
        lhs.id == rhs.id
    }
}
