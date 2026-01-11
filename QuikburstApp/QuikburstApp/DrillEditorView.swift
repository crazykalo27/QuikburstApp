import SwiftUI

struct DrillEditorView: View {
    @ObservedObject var drillStore: DrillStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    
    var editingDrill: Drill?
    
    @State private var name: String = ""
    @State private var category: DrillCategory = .speed
    @State private var isResistive: Bool = false
    @State private var isAssistive: Bool = false
    @State private var lengthSeconds: Int = 8
    @State private var showingTorqueCurve = false
    @State private var selectedTorqueProfileId: UUID?
    
    private var isNewDrill: Bool {
        editingDrill == nil
    }
    
    init(drillStore: DrillStore, editingDrill: Drill? = nil) {
        self.drillStore = drillStore
        self.editingDrill = editingDrill
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Information") {
                    TextField("Drill Name", text: $name)
                    
                    Picker("Category", selection: $category) {
                        ForEach(DrillCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    
                    Stepper("Length: \(lengthSeconds) seconds", value: $lengthSeconds, in: 1...60)
                }
                
                Section("Properties") {
                    Toggle("Resistive", isOn: $isResistive)
                    Toggle("Assistive", isOn: $isAssistive)
                }
                
                Section("Torque Curve") {
                    NavigationLink {
                        TorqueCurveSelectionView(
                            selectedProfileId: $selectedTorqueProfileId,
                            profileStore: profileStore
                        )
                    } label: {
                        HStack {
                            Text("Torque Curve")
                            Spacer()
                            if let profileId = selectedTorqueProfileId,
                               let profile = profileStore.profiles.first(where: { $0.id == profileId }) {
                                Text(profile.name)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("None")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNewDrill ? "New Drill" : "Edit Drill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveDrill()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onAppear {
                if let drill = editingDrill {
                    loadDrill(drill)
                }
            }
        }
    }
    
    private func loadDrill(_ drill: Drill) {
        name = drill.name
        category = drill.category
        isResistive = drill.isResistive
        isAssistive = drill.isAssistive
        lengthSeconds = drill.lengthSeconds
        selectedTorqueProfileId = drill.torqueProfileId
    }
    
    private func saveDrill() {
        if let drill = editingDrill {
            var updated = drill
            updated.name = name
            updated.category = category
            updated.isResistive = isResistive
            updated.isAssistive = isAssistive
            updated.lengthSeconds = lengthSeconds
            updated.torqueProfileId = selectedTorqueProfileId
            updated.updatedAt = Date()
            drillStore.updateDrill(updated)
        } else {
            let newDrill = Drill(
                name: name,
                category: category,
                isResistive: isResistive,
                isAssistive: isAssistive,
                lengthSeconds: lengthSeconds,
                isCustom: true,
                torqueProfileId: selectedTorqueProfileId
            )
            drillStore.addDrill(newDrill)
        }
        dismiss()
    }
}

struct TorqueCurveSelectionView: View {
    @Binding var selectedProfileId: UUID?
    @ObservedObject var profileStore: ProfileStore
    @State private var showingEditor = false
    @State private var editingProfile: TorqueProfile?
    
    var body: some View {
        List {
            Section {
                Button {
                    HapticFeedback.buttonPress()
                    editingProfile = TorqueProfile(name: "New Profile")
                    showingEditor = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.orange)
                        Text("Create New Profile")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                    }
                }
            }
            
            if !profileStore.profiles.isEmpty {
                Section("Select Profile") {
                    ForEach(profileStore.profiles) { profile in
                        HStack {
                            Button {
                                HapticFeedback.cardTap()
                                selectedProfileId = profile.id
                            } label: {
                                HStack {
                                    Text(profile.name)
                                        .font(.system(size: 16, weight: .regular, design: .rounded))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if selectedProfileId == profile.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Theme.orange)
                                            .font(.system(size: 18))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            
                            Button {
                                HapticFeedback.buttonPress()
                                editingProfile = profile
                                showingEditor = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.orange)
                                    .frame(width: 32, height: 32)
                                    .background(Theme.orange.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            
            if selectedProfileId != nil {
                Section {
                    Button(role: .destructive) {
                        HapticFeedback.buttonPress()
                        selectedProfileId = nil
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                            Text("Remove Selection")
                        }
                    }
                }
            }
        }
        .navigationTitle("Torque Curve")
        .sheet(isPresented: $showingEditor) {
            if let profile = editingProfile {
                TorqueCurveEditorView(profile: profile, profileStore: profileStore) { savedProfile in
                    selectedProfileId = savedProfile.id
                }
            }
        }
    }
}

struct TorqueCurveEditorView: View {
    @State var profile: TorqueProfile
    @ObservedObject var profileStore: ProfileStore
    let onSave: (TorqueProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var draggedPoint: Int? = nil
    @State private var selectedPointIndex: Int? = nil
    private let maxTorque: Double = 100
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    // Profile name
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Profile Name")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                        
                        TextField("Enter profile name", text: Binding(
                            get: { profile.name },
                            set: { profile.name = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16, design: .rounded))
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Color(.systemGray6))
                        .cornerRadius(Theme.CornerRadius.small)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.md)
                    
                    // Chart editor
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack {
                            Text("Torque Curve")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            if let selectedIndex = selectedPointIndex {
                                Text("\(selectedIndex)s: \(String(format: "%.1f", profile.torquePoints[selectedIndex]))")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundColor(Theme.orange)
                                    .padding(.horizontal, Theme.Spacing.sm)
                                    .padding(.vertical, 4)
                                    .background(Theme.orange.opacity(0.15))
                                    .cornerRadius(6)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        
                        GeometryReader { geometry in
                            ZStack {
                                // Background
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(Color(.systemGray6))
                                
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
                                    // Horizontal lines (torque levels)
                                    for i in 0...5 {
                                        let y = CGFloat(i) / 5.0 * height
                                        path.move(to: CGPoint(x: 0, y: y))
                                        path.addLine(to: CGPoint(x: width, y: y))
                                    }
                                }
                                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                                
                                // Torque line
                                Path { path in
                                    let width = geometry.size.width
                                    let height = geometry.size.height
                                    for i in 0..<profile.torquePoints.count {
                                        let x = CGFloat(i) / 10.0 * width
                                        let y = height - (CGFloat(profile.torquePoints[i]) / maxTorque * height)
                                        if i == 0 {
                                            path.move(to: CGPoint(x: x, y: y))
                                        } else {
                                            path.addLine(to: CGPoint(x: x, y: y))
                                        }
                                    }
                                }
                                .stroke(
                                    LinearGradient(
                                        colors: [Theme.orange, Theme.secondaryAccent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                                )
                                
                                // Draggable points
                                ForEach(0..<11, id: \.self) { index in
                                    DraggablePointView(
                                        index: index,
                                        profile: $profile,
                                        geometry: geometry,
                                        maxTorque: maxTorque,
                                        draggedPoint: $draggedPoint,
                                        selectedPointIndex: $selectedPointIndex
                                    )
                                }
                            }
                        }
                        .frame(height: 350)
                        .padding(Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                .fill(Color(.systemGray6))
                                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                        )
                        .padding(.horizontal, Theme.Spacing.lg)
                        
                        // Value display and instructions
                        VStack(spacing: Theme.Spacing.xs) {
                            HStack {
                                Text("Time: 0-10 seconds")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("Torque: 0-\(Int(maxTorque))")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            
                            Text("Drag points to adjust the curve")
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.8))
                                .padding(.horizontal, Theme.Spacing.lg)
                        }
                    }
                    .padding(.top, Theme.Spacing.md)
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(profileStore.profiles.contains(where: { $0.id == profile.id }) ? "Edit Profile" : "New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        HapticFeedback.buttonPress()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        HapticFeedback.workoutComplete()
                        if profileStore.profiles.contains(where: { $0.id == profile.id }) {
                            profileStore.updateProfile(profile)
                        } else {
                            profileStore.addProfile(profile)
                        }
                        onSave(profile)
                        dismiss()
                    }
                    .disabled(profile.name.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Draggable Point View Component

struct DraggablePointView: View {
    let index: Int
    @Binding var profile: TorqueProfile
    let geometry: GeometryProxy
    let maxTorque: Double
    @Binding var draggedPoint: Int?
    @Binding var selectedPointIndex: Int?
    
    private var x: CGFloat {
        CGFloat(index) / 10.0 * geometry.size.width
    }
    
    private var y: CGFloat {
        geometry.size.height - (CGFloat(profile.torquePoints[index]) / maxTorque * geometry.size.height)
    }
    
    private var isSelected: Bool {
        draggedPoint == index || selectedPointIndex == index
    }
    
    var body: some View {
        ZStack {
            // Selection ring
            if isSelected {
                Circle()
                    .fill(Theme.orange.opacity(0.2))
                    .frame(width: 44, height: 44)
            }
            
            // Point
            Circle()
                .fill(isSelected ? Theme.orange : Theme.orange.opacity(0.8))
                .frame(width: isSelected ? 24 : 20, height: isSelected ? 24 : 20)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
        }
        .position(x: x, y: y)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleDragChanged(value)
                }
                .onEnded { _ in
                    handleDragEnded()
                }
        )
        .onTapGesture {
            handleTap()
        }
    }
    
    private func handleDragChanged(_ value: DragGesture.Value) {
        if draggedPoint == nil {
            draggedPoint = index
            selectedPointIndex = index
            HapticFeedback.play(.light)
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
    
    private func handleDragEnded() {
        draggedPoint = nil
        HapticFeedback.play(.medium)
    }
    
    private func handleTap() {
        selectedPointIndex = selectedPointIndex == index ? nil : index
        HapticFeedback.cardTap()
    }
}
