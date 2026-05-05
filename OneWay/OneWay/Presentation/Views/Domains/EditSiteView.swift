import SwiftUI
import Combine

struct EditSiteView: View {
    @StateObject private var viewModel: EditSiteViewModel

    init(siteService: SiteService, domainSlug: String) {
        self._viewModel = StateObject(
            wrappedValue: EditSiteViewModel(siteService: siteService, domainSlug: domainSlug)
        )
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    modePicker

                    titleAndDescription

                    Group {
                        switch viewModel.mode {
                        case .nocode: nocodePlaceholder
                        case .code:   htmlEditor
                        case .ai:     aiSection
                        }
                    }

                    if let info = viewModel.infoMessage {
                        Text(info)
                            .font(.footnote)
                            .foregroundStyle(Theme.accentGold)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.85))
                    }

                    actionButtons
                }
                .padding(20)
            }
        }
        .navigationTitle("Edit Site")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.fullDomain)
                .font(.headline)
                .foregroundStyle(Theme.accentGold)
            Text("Pick how you want to build, then save when you're ready.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(SiteMode.allCases) { mode in
                modePill(for: mode)
            }
        }
    }

    @ViewBuilder
    private func modePill(for mode: SiteMode) -> some View {
        let isActive = viewModel.mode == mode
        Button {
            viewModel.mode = mode
        } label: {
            VStack(spacing: 2) {
                Text(mode.label)
                    .font(.subheadline.weight(.semibold))
                Text(mode.hint)
                    .font(.caption2)
                    .opacity(0.85)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.glassSurface)
                    if isActive {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.accentGradient)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? Color.clear : Theme.divider, lineWidth: 1)
            )
            .foregroundStyle(isActive ? Color.white : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var titleAndDescription: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Title")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
            TextField("My OneWay Site", text: $viewModel.title)
                .textInputAutocapitalization(.sentences)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 1)
                )

            Text("Description")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
            TextField("What's this page about?", text: $viewModel.siteDescription, axis: .vertical)
                .lineLimit(2...4)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 1)
                )
        }
    }

    // MARK: - Mode-specific UI

    private var nocodePlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textMuted)
            Text("Block builder coming soon.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("For now, switch to Code or AI to build your site.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var htmlEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HTML")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)

            TextEditor(text: $viewModel.html)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 220)
                .padding(10)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 1)
                )
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe your site")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)

            TextField("A landing page for my photography portfolio…", text: $viewModel.aiPrompt, axis: .vertical)
                .lineLimit(3...6)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 1)
                )

            Button {
                Task { await viewModel.generateWithAI() }
            } label: {
                HStack {
                    if viewModel.isGenerating {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                        Text("Generate with AI")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(viewModel.isGenerating)

            if !viewModel.html.isEmpty {
                htmlEditor
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await viewModel.save(thenPublish: true) }
            } label: {
                HStack {
                    if viewModel.isSaving || viewModel.isPublishing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                        Text("Save & publish")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(viewModel.isSaving || viewModel.isPublishing)

            Button {
                Task { await viewModel.save(thenPublish: false) }
            } label: {
                Text("Save draft")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.glassSurface, in: Capsule())
                    .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)
        }
    }
}
