import SwiftUI
import Combine

struct SafetyCenterView: View {
    @StateObject private var viewModel: SafetyCenterViewModel

    init(service: SafetyService) {
        _viewModel = StateObject(wrappedValue: SafetyCenterViewModel(service: service))
    }

    var body: some View {
        Form {
            Section("Block") {
                TextField("@handle", text: $viewModel.blockHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Block User") {
                    Task { await viewModel.blockUser() }
                }
            }

            Section("Report") {
                TextField("@handle", text: $viewModel.reportHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Reason", text: $viewModel.reportReason)

                Button("Report User") {
                    Task { await viewModel.reportUser() }
                }
            }

            Section("Privacy Preset") {
                Picker("Preset", selection: $viewModel.selectedPreset) {
                    ForEach(PrivacyPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }

                Button("Apply Preset") {
                    Task { await viewModel.applyPreset() }
                }
            }

            Section("Story Audience") {
                Picker("Who can view my story", selection: $viewModel.selectedStoryAudience) {
                    ForEach(StoryAudienceScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }

                Button("Apply Story Audience") {
                    Task { await viewModel.applyStoryAudience() }
                }

                if viewModel.blockedHandles.isEmpty {
                    Text("Blocked users: none")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Blocked users excluded: \(viewModel.blockedHandles.joined(separator: ", "))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Emergency") {
                Button("Session Kill-Switch", role: .destructive) {
                    Task { await viewModel.sessionKillSwitch() }
                }
            }

            if let info = viewModel.infoMessage {
                Section("Status") {
                    Text(info)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Safety Center")
    }
}
