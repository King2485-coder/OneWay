import Foundation
import Combine

@MainActor
final class RegisterDomainViewModel: ObservableObject {
    enum AvailabilityState: Equatable {
        case idle
        case checking
        case available
        case taken
        case invalid(String)
    }

    @Published var slugInput: String = ""
    @Published private(set) var availability: AvailabilityState = .idle
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?
    @Published var registeredDomain: OneWayDomain?

    private let domainService: DomainService
    private var checkTask: Task<Void, Never>?

    init(domainService: DomainService, initialSlug: String = "") {
        self.domainService = domainService
        self.slugInput = initialSlug
    }

    var canSubmit: Bool {
        if case .available = availability, !isSubmitting { return true }
        return false
    }

    var previewDomain: String {
        let s = slugInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (s.isEmpty ? "name" : s) + ".oneway.app"
    }

    func slugChanged(to raw: String) {
        slugInput = raw.lowercased()
        let validation = SlugValidator.validate(slugInput)
        switch validation {
        case .valid(let normalized):
            availability = .checking
            checkTask?.cancel()
            checkTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                do {
                    let ok = try await self.domainService.isSlugAvailable(normalized)
                    if Task.isCancelled { return }
                    self.availability = ok ? .available : .taken
                } catch {
                    self.availability = .idle
                }
            }
        default:
            checkTask?.cancel()
            availability = .invalid(validation.errorMessage ?? "Invalid name.")
            if validation == .empty { availability = .idle }
        }
    }

    func submit() async {
        guard case .available = availability else { return }
        guard case .valid(let slug) = SlugValidator.validate(slugInput) else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            // TODO: trigger Apple IAP / Stripe purchase flow before insert in production.
            let domain = try await domainService.registerDomain(
                slug: slug,
                paymentMethod: .appleIAP,
                paymentReference: nil
            )
            registeredDomain = domain
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't register that domain."
        }
    }
}
