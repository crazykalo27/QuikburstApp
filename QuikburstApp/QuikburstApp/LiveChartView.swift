import SwiftUI
import Charts

struct LiveChartView: View {
    @StateObject private var vm: DataStreamViewModel

    init(manager: BluetoothManager) {
        _vm = StateObject(wrappedValue: DataStreamViewModel(manager: manager))
    }

    var body: some View {
        VStack(spacing: 12) {
            Chart(vm.windowedSamples) {
                LineMark(
                    x: .value("Time", $0.timestamp),
                    y: .value("Value", $0.value)
                )
                .interpolationMethod(.linear)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5))
            }
            .chartYScale(domain: .automatic)
            .frame(height: 240)
            .transaction { $0.animation = nil }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button {
                    vm.start()
                } label: {
                    Label("Start", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    vm.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .navigationTitle("Live")
    }
}

#Preview {
    LiveChartView(manager: BluetoothManager())
}
