import SwiftUI

struct SiteTemplatePickerView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    let onSelected: (OneWayBuilderSite) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MarketplaceBackBar(title: "Choose a Template") { dismiss() } trailing: { EmptyView() }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(SiteTemplates.all) { template in
                            Button {
                                onSelected(viewModel.createFromTemplate(template))
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    templatePreview(template)
                                    Text(template.name)
                                        .font(.headline.weight(.black))
                                        .oneWayReadableText(.title)
                                    Text(template.category)
                                        .font(.caption.weight(.black))
                                        .foregroundStyle(OneWayCallTheme.purple)
                                    Text(template.description)
                                        .font(.caption.weight(.semibold))
                                        .oneWayReadableText(.subtitle)
                                        .lineLimit(3)
                                }
                                .padding(12)
                                .oneWayCallGlass(cornerRadius: 20)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 120)
            }
        }
        .navigationBarHidden(true)
    }

    private func templatePreview(_ template: OneWaySiteTemplate) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(hexString: template.primaryHex) ?? .black, Color(hexString: template.accentHex) ?? OneWayCallTheme.purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 74, height: 7)
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.7)).frame(width: 112, height: 5)
                HStack {
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.85)).frame(width: 42, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.25)).frame(width: 36, height: 14)
                }
            }
            .padding(12)
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension Color {
    init?(hexString: String) {
        let raw = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = Int(raw, radix: 16) else { return nil }
        self = Color(hex: UInt32(value))
    }
}
