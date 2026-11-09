import Foundation
import Combine

@MainActor
final class MyNumbersViewModel: ObservableObject {
    @Published var numbers: [OneWayNumber] = []
    @Published var billing: OneWayNumbersResponse.Billing?
    @Published var isLoading = false
    @Published var isAddingNumber = false
    @Published var mutatingNumberID: String?
    @Published var showPaywall = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await OneWayNumberService.shared.fetchMyNumbers()
            numbers = response.numbers.sorted {
                if $0.isPrimary != $1.isPrimary {
                    return $0.isPrimary && !$1.isPrimary
                }
                return $0.createdAt < $1.createdAt
            }
            billing = response.billing
        } catch {
            errorMessage = "Could not load numbers."
        }
    }

    func addNumber() async {
        guard !isAddingNumber else { return }
        isAddingNumber = true
        defer { isAddingNumber = false }

        do {
            let newNumber = try await OneWayNumberService.shared.createNumber()
            numbers.append(newNumber)
            await load()
        } catch OneWayNumberError.subscriptionRequired {
            showPaywall = true
        } catch {
            errorMessage = "Could not create number."
        }
    }

    func finishExtraNumbersPurchaseAndAddNumber() async {
        showPaywall = false
        await load()
        await addNumber()
    }

    func makePrimary(_ number: OneWayNumber) async {
        guard mutatingNumberID == nil, !number.isPrimary else { return }
        mutatingNumberID = number.id
        defer { mutatingNumberID = nil }
        do {
            _ = try await OneWayNumberService.shared.setPrimary(id: number.id)
            await load()
        } catch {
            errorMessage = "Could not set primary number."
        }
    }

    func delete(_ number: OneWayNumber) async {
        guard mutatingNumberID == nil, !number.isPrimary else { return }
        mutatingNumberID = number.id
        defer { mutatingNumberID = nil }
        do {
            try await OneWayNumberService.shared.deleteNumber(id: number.id)
            await load()
        } catch {
            errorMessage = "Could not delete number."
        }
    }
}
