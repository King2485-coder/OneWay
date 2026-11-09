import SwiftUI

struct DomainSettingsView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    @State private var draft: OneWayBuilderSite
    @Environment(\.dismiss) private var dismiss

    init(viewModel: OneWaySitesViewModel, site: OneWayBuilderSite) {
        self.viewModel = viewModel
        self._draft = State(initialValue: site)
    }

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MarketplaceBackBar(title: "Domain Settings") { dismiss() } trailing: { EmptyView() }
                    domainField("Free OneWay subdomain", text: $draft.domain.subdomain)
                    domainField("Custom domain", text: $draft.domain.customDomain)
                    statusRow("DNS Settings", "Manage DNS records", "server.rack")
                    statusRow("SSL Certificate", draft.domain.sslStatus, "lock.shield.fill", tint: .green)
                    statusRow("Site Status", draft.domain.publishStatus, "checkmark.seal.fill", tint: .green)
                    Button {
                        viewModel.upsert(draft)
                    } label: {
                        Text("Save Domain")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(OneWayCallTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .padding(18)
                .padding(.bottom, 120)
            }
        }
        .navigationBarHidden(true)
    }

    private func domainField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.black)).oneWayReadableText(.title)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(13)
                .oneWayReadableText(.body)
                .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .padding(14)
        .oneWayCallGlass(cornerRadius: 18)
    }

    private func statusRow(_ title: String, _ subtitle: String, _ icon: String, tint: Color = OneWayCallTheme.purple) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: icon).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline.weight(.black)).oneWayReadableText(.title)
                Text(subtitle).font(.caption.weight(.semibold)).oneWayReadableText(.subtitle)
            }
            Spacer()
            OneWayResolvedIcon(systemName: "chevron.right").oneWayReadableText(.muted)
        }
        .padding(16)
        .oneWayCallGlass(cornerRadius: 18)
    }
}
