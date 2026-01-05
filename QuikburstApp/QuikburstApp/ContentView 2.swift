import SwiftUI

struct ContentView: View {
    let manager: BluetoothManager

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white, Color.blue.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Quikburst")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.blue)
                    .padding(.top, 8)

                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                    TabView {
                        NavigationStack {
                            LiveChartView(manager: manager)
                        }
                        .tabItem {
                            Label("Live", systemImage: "waveform.path.ecg")
                        }

                        SettingsView()
                            .tabItem {
                                Label("Settings", systemImage: "gearshape")
                            }
                        
                        StatisticsView()
                            .tabItem {
                                Label("Statistics", systemImage: "chart.bar.xaxis")
                            }
                    }
                    .tabViewStyle(.automatic)
                    .padding()
                    .transaction { $0.animation = nil }
                }
                .frame(maxWidth: 900, maxHeight: 700)
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            }
            .padding()
        }
        .tint(.blue)
    }
}

#Preview {
    ContentView(manager: BluetoothManager())
}
