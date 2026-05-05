import SwiftUI

struct ThemeEditorView: View {
    @State var theme = ThemeConfig(primary: "#4F46E5", accent: "#22D3EE", background: "glass", typography: "SF Pro")
    let onAskAI: () -> Void

    var body: some View {
        Form {
            Section("Colors") {
                TextField("Primary", text: $theme.primary)
                TextField("Accent", text: $theme.accent)
            }
            Section("Typography") {
                TextField("Font", text: $theme.typography)
            }
            Section {
                Button("Ask AI for theme") { onAskAI() }
            }
        }
        .navigationTitle("Theme")
    }
}
