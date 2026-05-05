import SwiftUI
import Combine

struct DeviceSessionsView: View {
    @StateObject private var viewModel: DeviceSessionsViewModel

    init(service: DeviceSessionService) {
        _viewModel = StateObject(wrappedValue: DeviceSessionsViewModel(service: service))
    }

    var body: some View {
        List {
            Section("Linked Devices") {
                ForEach(viewModel.sessions) { session in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.deviceName)
                            Text(session.lastSeenAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.isCurrent {
                            Text("Current")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Actions") {
                Button("Link Dummy Device") {
                    Task { await viewModel.linkDummyDevice() }
                }
                Button("Revoke Other Sessions", role: .destructive) {
                    Task { await viewModel.revokeOtherSessions() }
                }
            }

            if let info = viewModel.infoMessage {
                Section("Status") {
                    Text(info)
                }
            }
        }
        .navigationTitle("Device Sessions")
        .task {
            await viewModel.load()
        }
    }
}
