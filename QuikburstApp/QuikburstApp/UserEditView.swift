import SwiftUI

struct UserEditView: View {
    @State var user: User
    @ObservedObject var profileStore: ProfileStore
    @Binding var isPresented: Bool
    var isNew: Bool = false
    
    // Available languages
    private let languages = ["English", "Spanish", "French", "German", "Italian", "Portuguese", "Chinese", "Japanese"]
    
    var body: some View {
        NavigationStack {
            Form {
                // Basic Info Section
                Section {
                    TextField("Name", text: Binding(
                        get: { user.name },
                        set: { user.name = $0 }
                    ))
                } header: {
                    Text("Basic Information")
                }
                
                // Sports Settings Section
                Section {
                    // Language
                    Picker("Language", selection: Binding(
                        get: { user.language },
                        set: { user.language = $0 }
                    )) {
                        ForEach(languages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                    
                    // Primary Sport
                    Picker("Primary Sport", selection: Binding(
                        get: { user.primarySport },
                        set: { newSport in
                            user.primarySport = newSport
                            // If not using custom units, update unit system to match sport default
                            if !user.useCustomUnits {
                                user.unitSystem = newSport.defaultUnits
                            }
                        }
                    )) {
                        ForEach(PrimarySport.allCases, id: \.self) { sport in
                            Text(sport.rawValue).tag(sport)
                        }
                    }
                    
                    // Units
                    Toggle("Use Custom Units", isOn: Binding(
                        get: { user.useCustomUnits },
                        set: { user.useCustomUnits = $0 }
                    ))
                    
                    if user.useCustomUnits {
                        Picker("Unit System", selection: Binding(
                            get: { user.unitSystem },
                            set: { user.unitSystem = $0 }
                        )) {
                            ForEach(UnitSystem.allCases, id: \.self) { system in
                                Text(system.rawValue).tag(system)
                            }
                        }
                    } else {
                        HStack {
                            Text("Unit System")
                            Spacer()
                            Text(user.effectiveUnitSystem.rawValue)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sports Settings")
                } footer: {
                    Text(user.useCustomUnits 
                         ? "You can override the default unit system for your sport."
                         : "Unit system is automatically set based on your primary sport.")
                }
                
                // Personal Settings Section
                Section {
                    // Height
                    HStack {
                        Text("Height")
                        Spacer()
                        TextField("Height", value: Binding(
                            get: { user.height },
                            set: { user.height = $0 }
                        ), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        Text(heightUnit)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Weight
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField("Weight", value: Binding(
                            get: { user.weight },
                            set: { user.weight = $0 }
                        ), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        Text(weightUnit)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Age
                    HStack {
                        Text("Age")
                        Spacer()
                        TextField("Age", value: Binding(
                            get: { user.age },
                            set: { user.age = $0 }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        Text("years")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Personal Settings")
                }
            }
            .navigationTitle(isNew ? "New User" : "Edit User")
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
                            profileStore.addUser(user)
                        } else {
                            profileStore.updateUser(user)
                        }
                        isPresented = false
                    }
                    .disabled(user.name.isEmpty)
                }
            }
        }
    }
    
    private var heightUnit: String {
        user.effectiveUnitSystem == .metric ? "cm" : "in"
    }
    
    private var weightUnit: String {
        user.effectiveUnitSystem == .metric ? "kg" : "lbs"
    }
}

#Preview {
    UserEditView(
        user: User(name: "Test User"),
        profileStore: ProfileStore(),
        isPresented: .constant(true)
    )
}
