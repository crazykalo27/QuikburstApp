import SwiftUI

struct FeatureComingSoonView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("OK") {}
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding()
        .presentationDetents([.medium, .large])
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Help & Tips").font(.title.bold())
                Text("• Connect to your Bluetooth device from the Bluetooth tab.\n• Use Live to start and stop streaming.\n• Settings lets you configure streaming and display.\n• Statistics shows your session history.")
                Text("Have feedback?")
                Button {
                    // TODO: Open feedback form
                } label: {
                    Label("Send Feedback", systemImage: "envelope")
                }
            }
            .padding()
        }
        .presentationDetents([.medium, .large])
    }
}

struct ExportView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Export Data").font(.title2.bold())
            Text("Export options will appear here. CSV, JSON, and share sheet are planned.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                // TODO: Implement export
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .presentationDetents([.fraction(0.4), .medium])
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .padding(.bottom, 4)
            Text("Quikburst").font(.largeTitle.bold())
            Text("Version 1.0").foregroundStyle(.secondary)
            Divider().padding(.vertical, 8)
            Text("Quikburst visualizes live sensor data over Bluetooth and helps you manage sessions and statistics.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding()
        .presentationDetents([.fraction(0.45), .medium])
    }
}

#Preview {
    Group {
        FeatureComingSoonView(title: "Coming Soon", message: "This feature is not yet available.")
        HelpView()
        ExportView()
        AboutView()
    }
}
