import SwiftUI

struct ContentView: View {
    let manager: BluetoothManager

    @State private var showHelp = false
    @State private var showAbout = false
    @State private var showExport = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white, Color.blue.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // App title header
                HStack {
                    Text("Quikburst")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.blue)
                    Spacer()
                    HStack(spacing: 12) {
                        Button {
                            showExport = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.borderless)

                        Button {
                            showHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.borderless)

                        Button {
                            showAbout = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

                // Main content area
                TabView {
                    NavigationStack {
                        LiveChartView(manager: manager)
                    }
                    .tabItem {
                        Label("Live", systemImage: "waveform.path.ecg")
                    }

                    NavigationStack {
                        ProfilesView()
                    }
                    .tabItem {
                        Label("Profiles", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    
                    NavigationStack {
                        SettingsView()
                    }
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    
                    NavigationStack {
                        StatisticsView()
                    }
                    .tabItem {
                        Label("Statistics", systemImage: "chart.bar.xaxis")
                    }
                    
                    NavigationStack {
                        BluetoothConsoleView(bluetooth: manager)
                    }
                    .tabItem {
                        Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .tabViewStyle(.automatic)
            }
        }
        .tint(.blue)
        .sheet(isPresented: $showHelp) { HelpView() }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showExport) { ExportView() }
    }
}

#Preview {
    ContentView(manager: BluetoothManager())
}
