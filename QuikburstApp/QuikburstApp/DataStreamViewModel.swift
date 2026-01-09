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
            for await sample in manager.sensorSamplesStream() {
                if Task.isCancelled { break }
                append(sample)
            }
        }
    }

    func stop() {
        task?.cancel()
        // Task cancellation will end the stream consumption; listeners are removed on stream termination.
        task = nil
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

