import SwiftUI

struct SiteThemeEditorView: View {
    @Binding var theme: SiteTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
            TextField("Primary color", text: $theme.primaryHex)
                .siteThemeField()
            TextField("Accent color", text: $theme.accentHex)
                .siteThemeField()
            TextField("Font", text: $theme.fontName)
                .siteThemeField()
            Toggle("Dark website theme", isOn: $theme.isDark)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .tint(OneWayDesignSystem.Colors.purple)
        }
        .padding(14)
        .oneWayCardStyle(cornerRadius: 18)
    }
}

private extension View {
    func siteThemeField() -> some View {
        oneWayLightFieldStyle()
    }
}
