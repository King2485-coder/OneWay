import Foundation

actor StubGroupService: GroupService {
    private var membersByChat: [UUID: [GroupMember]] = [:]

    func fetchMembers(chatID: UUID) async throws -> [GroupMember] {
        membersByChat[chatID] ?? seed(chatID: chatID)
    }

    func createInviteLink(chatID: UUID) async throws -> URL {
        URL(string: "https://cipherchat.app/group/\(chatID.uuidString.lowercased())/invite")!
    }

    func addMember(chatID: UUID, handle: String, role: GroupRole) async throws -> GroupMember {
        var members = membersByChat[chatID] ?? seed(chatID: chatID)
        let member = GroupMember(id: UUID(), name: handle.replacingOccurrences(of: "@", with: "").capitalized, handle: handle, role: role)
        members.append(member)
        membersByChat[chatID] = members
        return member
    }

    func removeMember(chatID: UUID, memberID: UUID) async throws {
        var members = membersByChat[chatID] ?? seed(chatID: chatID)
        members.removeAll { $0.id == memberID }
        membersByChat[chatID] = members
    }

    private func seed(chatID: UUID) -> [GroupMember] {
        let list = [
            GroupMember(id: UUID(), name: "You", handle: "@you", role: .owner),
            GroupMember(id: UUID(), name: "Alex", handle: "@alex", role: .admin),
            GroupMember(id: UUID(), name: "Priya", handle: "@priya", role: .member)
        ]
        membersByChat[chatID] = list
        return list
    }
}
