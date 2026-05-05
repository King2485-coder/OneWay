import SwiftUI
import Combine

struct RegisterDomainView: View {
    @StateObject private var viewModel: RegisterDomainViewModel
    @Environment(\.dismiss) private var dismiss

    init(domainService: DomainService, initialSlug: String = "") {
        self._viewModel = StateObject(
            wrappedValue: RegisterDomainViewModel(
                domainService: domainService,
                initialSlug: initialSlug
            )
        )
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    slugField

                    pricingCard

                    submitButton

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Register Domain")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.registeredDomain) { _, newValue in
            if newValue != nil {
                // Pop back to MyDomains so the new domain appears in the list.
                dismiss()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claim a name on OneWay")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
            Text("Pick a slug — it becomes \(viewModel.previewDomain). One year, $3.99, renewable.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var slugField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                TextField("name", text: Binding(
                    get: { viewModel.slugInput },
                    set: { viewModel.slugChanged(to: $0) }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .foregroundStyle(Theme.textPrimary)
                .padding(.vertical, 14)
                .padding(.leading, 14)

                Text(".oneway.app")
                    .foregroundStyle(Theme.textMuted)
                    .padding(.trailing, 14)
            }
            .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )

            availabilityRow
        }
    }

    private var borderColor: Color {
        switch viewModel.availability {
        case .available: return Color.green.opacity(0.6)
        case .taken, .invalid: return Color.red.opacity(0.55)
        default: return Theme.divider
        }
    }

    @ViewBuilder
    private var availabilityRow: some View {
        switch viewModel.availability {
        case .idle:
            Text("Letters, numbers, and dashes. 2–32 characters.")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7).tint(Theme.textMuted)
                Text("Checking availability…")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        case .available:
            Label {
                Text("\(viewModel.previewDomain) is yours.")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.green)
        case .taken:
            Label {
                Text("\(viewModel.previewDomain) is already taken.")
            } icon: {
                Image(systemName: "xmark.octagon.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.red.opacity(0.85))
        case .invalid(let message):
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.orange)
        }
    }

    private var pricingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Annual registration")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("$3.99")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Theme.accentGold)
            }
            Text("You own \(viewModel.previewDomain) for 12 months. We'll remind you before it expires — no auto-renew unless you opt in.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var submitButton: some View {
        Button {
            Task { await viewModel.submit() }
        } label: {
            HStack {
                if viewModel.isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checkmark.seal.fill")
                    Text("Register for $3.99 / year")
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .disabled(!viewModel.canSubmit)
        .opacity(viewModel.canSubmit ? 1.0 : 0.55)
    }
}
