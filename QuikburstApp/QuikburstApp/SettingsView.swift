import SwiftUI

struct SettingsView: View {
    @AppStorage("sampleRateHz") private var sampleRateHz: Double = 25
    @AppStorage("unit") private var unit: String = "units"
    @AppStorage("autoReconnect") private var autoReconnect: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Streaming") {
                    Stepper(value: $sampleRateHz, in: 1...200, step: 1) {
                        HStack {
                            Text("Sample rate")
                            Spacer()
                            Text("\(Int(sampleRateHz)) Hz").foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Auto-reconnect", isOn: $autoReconnect)
                }

                Section("Display") {
                    TextField("Unit label", text: $unit)
                }

                Section {
                    Button {
                        // TODO: Hook up to Bluetooth connection flow
                    } label: {
                        Label("Connect Device", systemImage: "bolt.horizontal.circle")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
