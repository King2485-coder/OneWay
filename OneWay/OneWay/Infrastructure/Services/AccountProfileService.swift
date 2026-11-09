import Foundation

struct AccountProfileStatus: Codable, Hashable {
    let complete: Bool
    let hasIdentity: Bool
    let hasNumber: Bool?
    let hasTwoFreeNumbers: Bool
    let hasDisplayName: Bool?
    let hasOneWayId: Bool?
    let hasEmailAlias: Bool?
}

final class AccountProfileService {
    static let shared = AccountProfileService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchProfileStatus() async throws -> AccountProfileStatus {
        try await client.get("api/account/profile-status")
    }

    func resetProfile(deleteImportedContacts: Bool = false) async throws {
        struct Request: Encodable {
            let deleteImportedContacts: Bool
        }

        let _: EmptyAPIResponse = try await client.post(
            "api/account/reset-profile",
            body: Request(deleteImportedContacts: deleteImportedContacts)
        )
    }
}
