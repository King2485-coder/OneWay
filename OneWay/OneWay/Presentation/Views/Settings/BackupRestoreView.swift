import SwiftUI
import Combine

struct BackupRestoreView: View {
    @StateObject private var viewModel: BackupRestoreViewModel

    init(service: BackupService) {
        _viewModel = StateObject(wrappedValue: BackupRestoreViewModel(service: service))
    }

    var body: some View {
        Form {
            Section("Encrypted Backup") {
                Toggle("Opt-in backup", isOn: Binding(
                    get: { viewModel.optedIn },
                    set: { newValue in
                        Task { await viewModel.setOptIn(newValue) }
                    }
                ))

                Button("Create Backup") {
                    Task { await viewModel.createBackup() }
                }
                .disabled(!viewModel.optedIn)

                Button("Restore Latest Backup") {
                    Task { await viewModel.restoreBackup() }
                }
                .disabled(!viewModel.optedIn)
            }

            if let message = viewModel.statusMessage {
                Section("Status") {
                    Text(message)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Backup & Restore")
        .task {
            await viewModel.load()
        }
    }
}
