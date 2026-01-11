import SwiftUI

struct MainContentView: View {
    let bluetoothManager: BluetoothManager
    @State private var selectedTab: Tab = .train
    @EnvironmentObject var profileStore: ProfileStore
    
    var body: some View {
        TabBarContainer(selectedTab: $selectedTab) {
            Group {
                switch selectedTab {
                case .drill:
                    DrillTabView()
                case .train:
                    TrainTabView(bluetoothManager: bluetoothManager)
                case .progress:
                    ProgressTabView()
                case .profiles:
                    ProfilesTabView(bluetoothManager: bluetoothManager)
                }
            }
        }
        .background(Theme.deepBlue.ignoresSafeArea())
    }
}
