import Foundation
protocol GroupService {
    func fetchMembers(chatID: UUID) async throws -> [GroupMember]
    func createInviteLink(chatID: UUID) async throws -> URL
    func addMember(chatID: UUID, handle: String, role: GroupRole) async throws -> GroupMember
    func removeMember(chatID: UUID, memberID: UUID) async throws
}
