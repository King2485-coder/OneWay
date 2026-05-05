import Foundation

actor StubCommunityService: CommunityService {
    private var communities: [Community]
    private var groups: [GroupChat]
    private var members: [UUID: [CommunityMember]]

    init() {
        let owner = UUID()
        let communityID = UUID()
        let groupID = UUID()
        let memberList = [
            CommunityMember(id: owner, displayName: "You", handle: "@you", role: .owner),
            CommunityMember(id: UUID(), displayName: "Alex", handle: "@alex", role: .admin),
            CommunityMember(id: UUID(), displayName: "Priya", handle: "@priya", role: .member)
        ]
        let community = Community(
            id: communityID,
            name: "Core Builders",
            description: "Internal coordination community",
            coverImageURL: nil,
            avatarURL: nil,
            ownerID: owner,
            admins: [memberList[1].id],
            moderators: [],
            members: memberList.map(\.id),
            linkedGroupIDs: [groupID]
        )
        let group = GroupChat(
            id: groupID,
            communityID: communityID,
            name: "Announcements",
            topic: "Core updates",
            memberIDs: memberList.map(\.id),
            lastMessageAt: Date().addingTimeInterval(-600),
            lastMessagePreview: "Welcome to the community!",
            isMuted: false,
            isArchived: false,
            disappearingAfterSeconds: nil
        )
        self.communities = [community]
        self.groups = [group]
        self.members = [communityID: memberList]
    }

    func listCommunities() async throws -> [Community] {
        communities
    }

    func createCommunity(_ community: Community) async throws -> Community {
        communities.append(community)
        members[community.id] = []
        return community
    }

    func updateCommunity(_ community: Community) async throws {
        guard let idx = communities.firstIndex(where: { $0.id == community.id }) else { return }
        communities[idx] = community
    }

    func joinCommunity(id: UUID) async throws {
        guard let idx = communities.firstIndex(where: { $0.id == id }) else { return }
        var community = communities[idx]
        let newMember = UUID()
        community.members.append(newMember)
        communities[idx] = community
        members[id, default: []].append(
            CommunityMember(id: newMember, displayName: "Member \(community.members.count)", handle: "@member\(community.members.count)", role: .member)
        )
    }

    func leaveCommunity(id: UUID) async throws {
        members[id] = members[id]?.filter { $0.handle != "@you" }
    }

    func listGroups(in communityID: UUID) async throws -> [GroupChat] {
        groups.filter { $0.communityID == communityID }
    }

    func createGroup(in communityID: UUID, group: GroupChat) async throws -> GroupChat {
        groups.append(group)
        return group
    }

    func updateGroup(_ group: GroupChat) async throws {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
    }

    func members(of communityID: UUID) async throws -> [CommunityMember] {
        members[communityID] ?? []
    }

    func addMember(communityID: UUID, handle: String, role: GroupRole) async throws -> CommunityMember {
        var list = members[communityID] ?? []
        let member = CommunityMember(id: UUID(), displayName: handle.replacingOccurrences(of: "@", with: "").capitalized, handle: handle, role: role, isMuted: false)
        list.append(member)
        members[communityID] = list
        if let idx = communities.firstIndex(where: { $0.id == communityID }) {
            var community = communities[idx]
            community.members.append(member.id)
            communities[idx] = community
        }
        return member
    }

    func removeMember(communityID: UUID, memberID: UUID) async throws {
        members[communityID] = members[communityID]?.filter { $0.id != memberID }
        if let idx = communities.firstIndex(where: { $0.id == communityID }) {
            var community = communities[idx]
            community.members.removeAll { $0 == memberID }
            communities[idx] = community
        }
    }
}
