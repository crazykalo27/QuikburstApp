import SwiftUI
import Charts

struct ProfilesView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @State private var selectedProfile: TorqueProfile?
    @State private var editingProfile: TorqueProfile?
    @State private var showingEditSheet = false
    @State private var showingNewProfileSheet = false
    
    var body: some View {
        List {
            Section {
                if profileStore.profiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("No profiles yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Create a new profile to get started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(profileStore.profiles) { profile in
                        ProfileRowView(profile: profile) {
                            selectedProfile = profile
                            editingProfile = profile
                            showingEditSheet = true
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            profileStore.deleteProfile(profileStore.profiles[index])
                        }
                    }
                }
            } header: {
                Text("Torque Profiles")
            } footer: {
                Text("Profiles define torque values over a 10-second period. Drag points to adjust the curve.")
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingProfile = TorqueProfile(name: "New Profile")
                    showingNewProfileSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            if let profile = editingProfile {
                ProfileEditorView(profile: profile, profileStore: profileStore, isPresented: $showingEditSheet)
            }
        }
        .sheet(isPresented: $showingNewProfileSheet) {
            if let profile = editingProfile {
                ProfileEditorView(profile: profile, profileStore: profileStore, isPresented: $showingNewProfileSheet, isNew: true)
            }
        }
        .onChange(of: showingEditSheet) { _, newValue in
            if !newValue {
                editingProfile = nil
            }
        }
        .onChange(of: showingNewProfileSheet) { _, newValue in
            if !newValue {
                editingProfile = nil
            }
        }
    }
}

struct ProfileRowView: View {
    let profile: TorqueProfile
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                // Mini preview chart
                Chart {
                    ForEach(Array(profile.torquePoints.enumerated()), id: \.offset) { index, value in
                        LineMark(
                            x: .value("Time", Double(index)),
                            y: .value("Torque", value)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(.blue)
                    }
                }
                .chartXScale(domain: 0...10)
                .chartYScale(domain: 0...max(profile.torquePoints.max() ?? 100, 100))
                .frame(height: 60)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct ProfileEditorView: View {
    @State var profile: TorqueProfile
    @ObservedObject var profileStore: ProfileStore
    @Binding var isPresented: Bool
    var isNew: Bool = false
    
    @State private var draggedPoint: Int? = nil
    @State private var dragOffset: CGSize = .zero
    
    private let maxTorque: Double = 100
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Profile name
                VStack(alignment: .leading, spacing: 8) {
                    Text("Profile Name")
                        .font(.headline)
                    TextField("Enter profile name", text: Binding(
                        get: { profile.name },
                        set: { profile.name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                
                // Chart editor
                VStack(alignment: .leading, spacing: 12) {
                    Text("Torque Profile (10 seconds)")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    GeometryReader { geometry in
                        ZStack {
                            // Background grid
                            Path { path in
                                let width = geometry.size.width
                                let height = geometry.size.height
                                // Vertical lines (seconds)
                                for i in 0...10 {
                                    let x = CGFloat(i) / 10.0 * width
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: height))
                                }
                                // Horizontal lines
                                for i in 0...5 {
                                    let y = CGFloat(i) / 5.0 * height
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: width, y: y))
                                }
                            }
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            
                            // Torque line
                            Path { path in
                                let width = geometry.size.width
                                let height = geometry.size.height
                                for (index, value) in profile.torquePoints.enumerated() {
                                    let x = CGFloat(index) / 10.0 * width
                                    let y = height - (CGFloat(value) / maxTorque * height)
                                    if index == 0 {
                                        path.move(to: CGPoint(x: x, y: y))
                                    } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                    }
                                }
                            }
                            .stroke(Color.blue, lineWidth: 2)
                            
                            // Draggable points
                            ForEach(0..<11, id: \.self) { index in
                                let x = CGFloat(index) / 10.0 * geometry.size.width
                                let y = geometry.size.height - (CGFloat(profile.torquePoints[index]) / maxTorque * geometry.size.height)
                                
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 20, height: 20)
                                    .position(x: x, y: y)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                if draggedPoint == nil {
                                                    draggedPoint = index
                                                }
                                                if draggedPoint == index {
                                                    let newY = max(0, min(geometry.size.height, value.location.y))
                                                    let normalizedY = 1.0 - (newY / geometry.size.height)
                                                    let newTorque = normalizedY * maxTorque
                                                    var updatedPoints = profile.torquePoints
                                                    updatedPoints[index] = max(0, min(maxTorque, newTorque))
                                                    profile.torquePoints = updatedPoints
                                                }
                                            }
                                            .onEnded { _ in
                                                draggedPoint = nil
                                            }
                                    )
                            }
                        }
                    }
                    .frame(height: 300)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    
                    // Value display
                    HStack {
                        Text("Time: 0-10 seconds")
                        Spacer()
                        Text("Torque: 0-\(Int(maxTorque))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                }
                
                Spacer()
            }
            .padding(.vertical)
            .navigationTitle(isNew ? "New Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isNew {
                            profileStore.addProfile(profile)
                        } else {
                            profileStore.updateProfile(profile)
                        }
                        isPresented = false
                    }
                    .disabled(profile.name.isEmpty)
                }
            }
        }
    }
}

#Preview {
    ProfilesView()
        .environmentObject(ProfileStore())
}
