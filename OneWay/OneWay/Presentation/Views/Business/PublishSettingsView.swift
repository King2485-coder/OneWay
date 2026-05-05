import SwiftUI

struct PublishSettingsView: View {
    @State var isPublished: Bool
    let onToggle: (Bool) -> Void
    let onAskAI: () -> Void

    var body: some View {
        Form {
            Section("Status") {
                Toggle("Published", isOn: $isPublished)
                    .onChange(of: isPublished) { _, newValue in
                        onToggle(newValue)
                    }
            }
            Section {
                Button("Ask AI for launch checklist") { onAskAI() }
            }
        }
        .navigationTitle("Publish")
    }
}
