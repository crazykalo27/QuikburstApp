import Foundation
import Combine

@MainActor
final class DataStreamViewModel: ObservableObject {
    @Published var windowedSamples: [SensorSample] = []
    private let manager: BluetoothManager
    private var task: Task<Void, Never>?
    private let windowSeconds: TimeInterval = 20

    init(manager: BluetoothManager) {
        self.manager = manager
    }

    func start() {
        task?.cancel()
        task = Task {
            for await sample in await manager.samples() {
                append(sample)
            }
        }
        Task { await manager.start() }
    }

    func stop() {
        task?.cancel()
        task = nil
        Task { await manager.stop() }
    }

    private func append(_ sample: SensorSample) {
        windowedSamples.append(sample)
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        windowedSamples.removeAll { $0.timestamp < cutoff }
        if windowedSamples.count > 1500 {
            windowedSamples = stride(from: 0, to: windowedSamples.count, by: 2).map { windowedSamples[$0] }
        }
    }
}

