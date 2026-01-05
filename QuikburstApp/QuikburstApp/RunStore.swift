import Foundation
import Combine
import UniformTypeIdentifiers

final class RunStore: ObservableObject {
    @Published private(set) var runs: [RunRecord] = [] {
        didSet { save() }
    }

    init() {
        load()
    }

    func append(_ run: RunRecord) {
        runs.append(run)
    }

    // MARK: - Persistence
    private var fileURL: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("QuikburstApp", conformingTo: .directory)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("runs.json")
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([RunRecord].self, from: data)
            self.runs = decoded
        } catch {
            // First run or failed to decode; start empty
            self.runs = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(runs)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // You could log this error in a real app
        }
    }
}

