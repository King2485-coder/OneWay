import SwiftUI

struct OneWayAutomationSettingsView: View {
    @StateObject private var store = OneWayAutomationPreferencesStore.shared
    @State private var showingInstructions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actionButtonSection
                contextSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .padding(.bottom, 90)
        }
        .background {
            ZStack {
                Color(hex: 0x040611)
                LinearGradient(
                    colors: [Color(hex: 0x050713), Color(hex: 0x0C0925), Color(hex: 0x160A36)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [OneWayDesignSystem.Colors.purplePrimary.opacity(0.18), .clear],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 360
                )
            }
            .ignoresSafeArea()
        }
        .navigationTitle("OneWay Button")
        .navigationBarTitleDisplayMode(.inline)
        .oneWayMenuBar()
        .sheet(isPresented: $showingInstructions) {
            ActionButtonInstructionsSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            OneWayResolvedLabel("Action Button & Automations", systemImage: "button.programmable")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(OneWayDS.ColorToken.textPrimary)
            Text("Connect OneWay to Apple-supported Shortcuts and keep sensitive automations under your control.")
                .font(.body.weight(.medium))
                .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionButtonSection: some View {
        settingsCard(title: "Action Button") {
            Toggle(isOn: $store.actionButtonEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable OneWay Action Button")
                        .font(.headline)
                    Text("Assign a OneWay shortcut from iPhone Settings. OneWay cannot change your hardware button automatically.")
                        .font(.footnote)
                        .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                }
            }
            .tint(OneWayDS.ColorToken.oneWayPurplePrimary)

            Divider()

            Picker("Primary Action", selection: $store.primaryAction) {
                ForEach(Self.supportedActions) { action in
                    OneWayResolvedLabel(action.title, systemImage: action.symbolName)
                        .tag(action)
                }
            }

            Button {
                showingInstructions = true
            } label: {
                OneWayResolvedLabel("Show Action Button Setup Instructions", systemImage: "questionmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(OneWayDS.ColorToken.oneWayPurplePrimary)
        }
    }

    private var contextSection: some View {
        settingsCard(title: "Context-Aware Actions") {
            ForEach(Self.enforcedFeatures) { feature in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title)
                                .font(.headline)
                                .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                            Text(feature.summary)
                                .font(.footnote)
                                .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                    }

                    Picker(feature.title, selection: binding(for: feature)) {
                        ForEach(AutomationPermissionState.allCases) { state in
                            Text(state.title).tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(feature.title)
                }
                .padding(.vertical, 6)

                if feature != Self.enforcedFeatures.last {
                    Divider()
                }
            }
        }
    }

    private func binding(for feature: OneWayAutomationFeature) -> Binding<AutomationPermissionState> {
        Binding(
            get: { store.state(for: feature) },
            set: { store.setState($0, for: feature) }
        )
    }

    private static let supportedActions: [OneWayButtonAction] = [
        .smartActionMenu, .startChirp, .openCamera, .callFavorite, .openQuantum, .openWallet
    ]

    private static let enforcedFeatures: [OneWayAutomationFeature] = [
        .favoriteContact, .chirpPushToTalk
    ]

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.black))
                .foregroundStyle(OneWayDS.ColorToken.textPrimary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            OneWayDesignSystem.Colors.panelGlass,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OneWayDesignSystem.Colors.purpleGlow.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.12), radius: 16, x: 0, y: 8)
    }
}

private struct VehicleAutomationRow: View {
    var vehicle: RecognizedVehicle
    @ObservedObject var store: OneWayAutomationPreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Vehicle", text: nameBinding)
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                    .background(
                        OneWayDesignSystem.Colors.deepPurple.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(OneWayDesignSystem.Colors.border.opacity(0.8), lineWidth: 1)
                    )
                Button(role: .destructive) {
                    store.forgetVehicle(id: vehicle.id)
                } label: {
                    OneWayResolvedIcon(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }

            Toggle("Driving Mode for this vehicle", isOn: enabledBinding)
                .tint(OneWayDS.ColorToken.oneWayPurplePrimary)

            Picker("Automatic behavior", selection: behaviorBinding) {
                ForEach(VehicleAutomationBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }

            Toggle("Remember this choice for this vehicle", isOn: rememberBinding)
                .tint(OneWayDS.ColorToken.oneWayPurplePrimary)
        }
        .padding(.vertical, 6)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { vehicle.name },
            set: { value in
                var updated = vehicle
                updated.name = value
                store.updateVehicle(updated)
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { vehicle.drivingModeEnabled },
            set: { value in
                var updated = vehicle
                updated.drivingModeEnabled = value
                store.updateVehicle(updated)
            }
        )
    }

    private var behaviorBinding: Binding<VehicleAutomationBehavior> {
        Binding(
            get: { vehicle.behavior },
            set: { value in
                var updated = vehicle
                updated.behavior = value
                store.updateVehicle(updated)
            }
        )
    }

    private var rememberBinding: Binding<Bool> {
        Binding(
            get: { vehicle.rememberChoice },
            set: { value in
                var updated = vehicle
                updated.rememberChoice = value
                store.updateVehicle(updated)
            }
        )
    }
}

private struct ActionButtonInstructionsSheet: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                OneWayResolvedLabel("Set Up Action Button", systemImage: "button.programmable")
                    .font(.title2.weight(.black))
                Text("OneWay exposes shortcuts that you control from iPhone Settings. Apple does not allow apps to assign the physical Action Button directly.")
                    .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    instruction("1", "Open iPhone Settings.")
                    instruction("2", "Tap Action Button.")
                    instruction("3", "Choose Shortcut.")
                    instruction("4", "Select a OneWay shortcut, such as Smart Actions.")
                }

                Spacer()
            }
            .padding(22)
            .background(OneWayLightBackground().ignoresSafeArea())
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func instruction(_ step: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(OneWayDS.ColorToken.oneWayPurplePrimary, in: Circle())
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(OneWayDS.ColorToken.textPrimary)
        }
    }
}
