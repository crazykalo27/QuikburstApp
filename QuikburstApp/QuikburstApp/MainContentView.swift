import SwiftUI

struct MainContentView: View {
    let bluetoothManager: BluetoothManager
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var navigationCoordinator: AppNavigationCoordinator
    @StateObject private var templateStore = DrillTemplateStore()
    @StateObject private var workoutStore = WorkoutStore()
    @StateObject private var sessionResultStore = SessionResultStore()
    @StateObject private var drillRunStore = DrillRunStore()
    @StateObject private var baselineStore = DrillBaselineStore()
    
    var body: some View {
        TabBarContainer(selectedTab: $navigationCoordinator.selectedTab) {
            Group {
                switch navigationCoordinator.selectedTab {
                case .drill:
                    DrillTabView()
                case .train:
                    TrainTabView(
                        bluetoothManager: bluetoothManager,
                        startIntent: navigationCoordinator.trainStartIntent
                    )
                case .progress:
                    ProgressTabView()
                case .profiles:
                    ProfilesTabView(bluetoothManager: bluetoothManager)
                }
            }
        }
        .background(Theme.deepBlue.ignoresSafeArea())
        .environmentObject(templateStore)
        .environmentObject(workoutStore)
        .environmentObject(sessionResultStore)
        .environmentObject(drillRunStore)
        .environmentObject(baselineStore)
    }
}
