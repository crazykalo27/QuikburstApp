import SwiftUI

struct ContentView: View {
    let manager: BluetoothManager

    var body: some View {
        MainContentView(bluetoothManager: manager)
    }
}

#Preview {
    ContentView(manager: BluetoothManager())
}
