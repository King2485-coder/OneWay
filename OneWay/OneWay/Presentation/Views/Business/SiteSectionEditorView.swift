import SwiftUI

struct SiteSectionEditorView: View {
    @Binding var section: SiteSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.type.rawValue)
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
            TextField("Section title", text: $section.title)
                .siteEditorField()
            TextEditor(text: $section.body)
                .frame(minHeight: 100)
                .scrollContentBackground(.hidden)
                .siteEditorField()
                .foregroundStyle(OneWayDesignSystem.Colors.text)
            TextField("Button title", text: Binding(
                get: { section.buttonTitle ?? "" },
                set: { section.buttonTitle = $0.isEmpty ? nil : $0 }
            ))
            .siteEditorField()
        }
    }
}

private extension View {
    func siteEditorField() -> some View {
        oneWayLightFieldStyle()
    }
}
