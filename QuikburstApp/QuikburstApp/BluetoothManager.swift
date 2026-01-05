import Foundation
import CoreBluetooth

// For groundwork and simulator testing, this manager produces mock samples.
// You can later replace the mock with real CoreBluetooth central logic.
actor BluetoothManager {
    private var timer: Timer?
    private var sampleContinuation: AsyncStream<SensorSample>.Continuation?
    private var startDate = Date()

    func samples() -> AsyncStream<SensorSample> {
        AsyncStream { continuation in
            self.sampleContinuation = continuation
        }
    }

    func start() {
        stop()
        startDate = Date()
        // Mock: emit a smooth sine wave with noise at ~30 Hz
        let interval = 1.0 / 30.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.emitMock() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
    }

    private func emitMock() {
        let t = Date().timeIntervalSince(startDate)
        let base = sin(t * 2 * .pi * 0.25) // 0.25 Hz
        let noise = Double.random(in: -0.05...0.05)
        let value = base + noise
        let sample = SensorSample(timestamp: Date(), value: value)
        sampleContinuation?.yield(sample)
    }
}

