import Foundation

actor StubCommunityService: CommunityService {
    private let store = CommunityRepository.shared

    func listCommunities() async throws -> [Community] {
        await store.listCommunities(for: currentUserContext())
    }

    func cachedCommunities() async -> [Community] {
        await store.listCommunities(for: currentUserContext())
    }

    func fetchPublicCommunities() async throws -> [Community] {
        await store.fetchPublicCommunities()
    }

    func searchPublicCommunities(query: String) async throws -> [Community] {
        await store.searchPublicCommunities(query: query)
    }

    func cachedJoinedCommunityIDs() async -> Set<UUID> {
        await store.joinedCommunityIDs(for: currentUserContext())
    }

    func fetchMyMembershipIDs() async throws -> Set<UUID> {
        await store.joinedCommunityIDs(for: currentUserContext())
    }

    func community(named name: String) async throws -> Community? {
        await store.community(named: name)
    }

    func createCommunity(_ community: Community) async throws -> Community {
        try await store.createCommunity(community, creator: currentUserContext())
    }

    func updateCommunity(_ community: Community) async throws {
        try await store.updateCommunity(community, actor: currentUserContext())
    }

    func joinCommunity(id: UUID) async throws {
        try await store.joinCommunity(id: id, user: currentUserContext())
    }

    func leaveCommunity(id: UUID) async throws {
        try await store.leaveCommunity(id: id, user: currentUserContext())
    }

    func deleteCommunity(id: UUID) async throws {
        try await store.deleteCommunity(id: id, actor: currentUserContext())
    }

    func updateCommunityVisibility(id: UUID, visibility: CommunityVisibility) async throws {
        try await store.updateVisibility(id: id, visibility: visibility, actor: currentUserContext())
    }

    func blockUser(communityID: UUID, userID: String) async throws {
        try await store.blockUser(communityID: communityID, userID: userID, actor: currentUserContext())
    }

    func unblockUser(communityID: UUID, userID: String) async throws {
        try await store.unblockUser(communityID: communityID, userID: userID, actor: currentUserContext())
    }

    func listGroups(in communityID: UUID) async throws -> [GroupChat] {
        await store.listGroups(in: communityID)
    }

    func createGroup(in communityID: UUID, group: GroupChat) async throws -> GroupChat {
        await store.createGroup(group)
    }

    func updateGroup(_ group: GroupChat) async throws {
        await store.updateGroup(group)
    }

    func members(of communityID: UUID) async throws -> [CommunityMember] {
        await store.members(of: communityID)
    }

    func addMember(communityID: UUID, handle: String, role: GroupRole) async throws -> CommunityMember {
        try await store.addMember(communityID: communityID, handle: handle, role: role, actor: currentUserContext())
    }

    func removeMember(communityID: UUID, memberID: UUID) async throws {
        try await store.removeMember(communityID: communityID, memberID: memberID, actor: currentUserContext())
    }

    func messages(in communityID: UUID) async throws -> [CommunityMessage] {
        await store.fetchMessages(communityId: communityID)
    }

    func fetchMessages(communityId: UUID) async throws -> [CommunityMessage] {
        await store.fetchMessages(communityId: communityId)
    }

    func fetchMessages(communityId: UUID, since: Date) async throws -> [CommunityMessage] {
        await store.fetchMessages(communityId: communityId, since: since)
    }

    func sendMessage(_ text: String, in communityID: UUID) async throws -> CommunityMessage {
        try await store.sendMessage(text, in: communityID, sender: currentUserContext())
    }

    func sendMessage(_ text: String, in communityID: UUID, clientMessageId: UUID) async throws -> CommunityMessage {
        try await store.sendMessage(text, in: communityID, sender: currentUserContext(), clientMessageId: clientMessageId)
    }

    func sendVoiceMessage(_ data: Data, in communityID: UUID, clientMessageId: UUID, disappearing: MessageDisappearingOverride) async throws -> CommunityMessage {
        struct VoiceEnvelope: Encodable {
            let onewayVoice = true
            let payloadBase64: String
            let disappearing: String
            let expirationDurationSeconds: Int?
        }
        let encoded = try JSONEncoder().encode(VoiceEnvelope(
            payloadBase64: data.base64EncodedString(),
            disappearing: disappearing.rawValue,
            expirationDurationSeconds: disappearing == .afterRead ? 60 : nil
        ))
        return try await store.sendMessage(String(decoding: encoded, as: UTF8.self), in: communityID, sender: currentUserContext(), clientMessageId: clientMessageId)
    }

    nonisolated func subscribeToCommunityDiscovery() -> AsyncThrowingStream<Community, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func subscribeToCommunityMessages(communityId: UUID) -> AsyncThrowingStream<CommunityMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func subscribeToCommunityRealtimeState() -> AsyncStream<CommunityRealtimeConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
            continuation.finish()
        }
    }

    nonisolated func subscribeToCommunityTyping(communityId: UUID) -> AsyncStream<CommunityTypingEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func sendCommunityTyping(communityId: UUID, isTyping: Bool) {}

    nonisolated func subscribeToCommunityPresence(communityId: UUID) -> AsyncStream<CommunityPresenceEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func subscribeToCommunityReads(communityId: UUID) -> AsyncStream<CommunityReadEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func markCommunityMessageRead(communityId: UUID, messageId: UUID) {}

    private func currentUserContext() -> SharedCommunityUser {
        SharedCommunityUser.current()
    }
}

actor CommunityRepository {
    static let shared = CommunityRepository()

    private static let communitiesKey = "oneway.global.communities"
    private static let membersKey = "oneway.global.community.members"
    private static let messagesKey = "oneway.global.community.messages"
    private static let groupsKey = "oneway.global.community.groups"
    private static let legacySharedCommunitiesKey = "oneway.shared.communities.v2"
    private static let legacySharedMembersKey = "oneway.shared.communityMembers.v2"
    private static let legacySharedGroupsKey = "oneway.shared.communityGroups.v2"
    private static let legacyCommunitiesKey = "oneway.stub.communityDirectory"
    private static let legacyMembersKey = "oneway.stub.communityMembers"

    private var communities: [Community]
    private var membersByCommunity: [UUID: [CommunityMember]]
    private var messagesByCommunity: [UUID: [CommunityMessage]]
    private var groups: [GroupChat]

    private init() {
        if let saved = Self.load([Community].self, key: Self.communitiesKey) {
            communities = saved
            membersByCommunity = Self.load([UUID: [CommunityMember]].self, key: Self.membersKey) ?? [:]
            messagesByCommunity = Self.load([UUID: [CommunityMessage]].self, key: Self.messagesKey) ?? Self.messages(from: saved)
            groups = Self.load([GroupChat].self, key: Self.groupsKey) ?? []
        } else if let shared = Self.load([Community].self, key: Self.legacySharedCommunitiesKey) {
            communities = Self.dedupePublicCommunities(shared)
            membersByCommunity = Self.load([UUID: [CommunityMember]].self, key: Self.legacySharedMembersKey) ?? [:]
            messagesByCommunity = Self.messages(from: shared)
            groups = Self.load([GroupChat].self, key: Self.legacySharedGroupsKey) ?? []
        } else if let legacy = Self.load([Community].self, key: Self.legacyCommunitiesKey) {
            communities = Self.dedupePublicCommunities(legacy)
            membersByCommunity = Self.load([UUID: [CommunityMember]].self, key: Self.legacyMembersKey) ?? [:]
            messagesByCommunity = Self.messages(from: legacy)
            groups = []
        } else {
            let seed = Self.seedCommunity()
            communities = [seed.community]
            membersByCommunity = [seed.community.id: seed.members]
            messagesByCommunity = [seed.community.id: []]
            groups = [seed.group]
        }
        communities = Self.normalizedLoadedCommunities(communities)
        Self.save(communities, key: Self.communitiesKey)
        Self.save(membersByCommunity, key: Self.membersKey)
        Self.save(messagesByCommunity, key: Self.messagesKey)
        Self.save(groups, key: Self.groupsKey)
    }

    func fetchPublicCommunities() -> [Community] {
        communities
            .filter { $0.deletedAt == nil && $0.visibility == .public }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func searchPublicCommunities(query: String) -> [Community] {
        let normalized = Community.normalizedName(for: query)
        guard !normalized.isEmpty else { return fetchPublicCommunities() }
        return fetchPublicCommunities().filter {
            $0.normalizedName.contains(normalized)
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.creatorHandle.localizedCaseInsensitiveContains(query)
        }
    }

    func listCommunities(for user: SharedCommunityUser) -> [Community] {
        communities
            .filter { isVisible($0, to: user) }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func joinedCommunityIDs(for user: SharedCommunityUser) -> Set<UUID> {
        Set(communities.compactMap { community in
            let isJoined = community.creatorUserId == user.id
                || community.members.contains(user.memberID)
                || (membersByCommunity[community.id] ?? []).contains { $0.handle.caseInsensitiveCompare(user.handle) == .orderedSame }
            return isJoined && community.deletedAt == nil ? community.id : nil
        })
    }

    func community(named name: String) -> Community? {
        let normalized = Community.normalizedName(for: name)
        return communities.first { community in
            community.normalizedName == normalized
                && community.visibility == .public
                && community.deletedAt == nil
        }
    }

    func createCommunity(_ community: Community, creator: SharedCommunityUser) throws -> Community {
        let now = Date()
        let normalized = Community.normalizedName(for: community.name)
        if community.visibility == .public,
           communities.contains(where: { $0.deletedAt == nil && $0.visibility == .public && $0.normalizedName == normalized }) {
            throw SharedCommunityError.duplicateName
        }

        var draft = community
        draft.normalizedName = normalized
        draft.creatorUserId = creator.id
        draft.creatorHandle = creator.handle
        draft.ownerID = creator.memberID
        draft.members = [creator.memberID]
        draft.createdAt = now
        draft.updatedAt = now
        draft.deletedAt = nil
        communities.append(draft)
        membersByCommunity[draft.id] = [
            CommunityMember(id: creator.memberID, displayName: creator.displayName, handle: creator.handle, role: .owner, isMuted: false)
        ]
        messagesByCommunity[draft.id] = []
        persist()
        return draft
    }

    func getOrCreatePublicCommunity(name: String, creator: SharedCommunityUser) throws -> Community {
        let normalized = Community.normalizedName(for: name)
        if let existing = communities
            .filter({ $0.deletedAt == nil && $0.visibility == .public && $0.normalizedName == normalized })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first {
            return existing
        }

        let now = Date()
        return try createCommunity(
            Community(
                id: UUID(),
                name: name,
                description: "",
                creatorUserId: "",
                creatorHandle: "",
                visibility: .public,
                coverImageURL: nil,
                avatarURL: nil,
                ownerID: creator.memberID,
                admins: [],
                moderators: [],
                members: [],
                blockedUserIds: [],
                bannedUserIds: [],
                messages: [],
                linkedGroupIDs: [],
                createdAt: now,
                updatedAt: now,
                deletedAt: nil
            ),
            creator: creator
        )
    }

    @discardableResult
    func ensureMember(communityId: UUID, user: SharedCommunityUser, role: GroupRole = .member) throws -> Community {
        guard let idx = communities.firstIndex(where: { $0.id == communityId }) else {
            throw SharedCommunityError.notAllowed
        }
        guard communities[idx].deletedAt == nil else { throw SharedCommunityError.deleted }
        guard !communities[idx].blockedUserIds.contains(user.id), !communities[idx].bannedUserIds.contains(user.id) else {
            throw SharedCommunityError.blocked
        }

        if !communities[idx].members.contains(user.memberID) {
            communities[idx].members.append(user.memberID)
        }

        var memberList = membersByCommunity[communityId] ?? []
        if !memberList.contains(where: { $0.id == user.memberID || $0.handle.caseInsensitiveCompare(user.handle) == .orderedSame }) {
            let memberRole: GroupRole = communities[idx].creatorUserId == user.id ? .owner : role
            memberList.append(CommunityMember(id: user.memberID, displayName: user.displayName, handle: user.handle, role: memberRole, isMuted: false))
        }

        communities[idx].updatedAt = Date()
        membersByCommunity[communityId] = memberList
        persist()
        return communities[idx]
    }

    func openSharedCommunity(name: String, users: [SharedCommunityUser]) throws -> Community {
        let creator = users.first ?? SharedCommunityUser(handle: "@king")
        let community = try getOrCreatePublicCommunity(name: name, creator: creator)
        for user in users {
            _ = try ensureMember(communityId: community.id, user: user, role: community.creatorUserId == user.id ? .owner : .member)
        }
        return communities.first(where: { $0.id == community.id }) ?? community
    }

    func updateCommunity(_ community: Community, actor: SharedCommunityUser) throws {
        guard let idx = communities.firstIndex(where: { $0.id == community.id }) else { return }
        guard communities[idx].creatorUserId == actor.id else { throw SharedCommunityError.notAllowed }
        var updated = community
        updated.normalizedName = Community.normalizedName(for: updated.name)
        updated.updatedAt = Date()
        communities[idx] = updated
        persist()
    }

    func joinCommunity(id: UUID, user: SharedCommunityUser) throws {
        guard let idx = communities.firstIndex(where: { $0.id == id }) else { return }
        guard communities[idx].visibility == .public || communities[idx].creatorUserId == user.id else { throw SharedCommunityError.notAllowed }
        _ = try ensureMember(communityId: id, user: user)
    }

    func leaveCommunity(id: UUID, user: SharedCommunityUser) throws {
        guard let idx = communities.firstIndex(where: { $0.id == id }) else { return }
        var community = communities[idx]
        guard community.creatorUserId != user.id else { throw SharedCommunityError.notAllowed }
        community.members.removeAll { $0 == user.memberID }
        community.updatedAt = Date()
        communities[idx] = community
        membersByCommunity[id] = membersByCommunity[id]?.filter { $0.id != user.memberID }
        persist()
    }

    func deleteCommunity(id: UUID, actor: SharedCommunityUser) throws {
        guard let idx = communities.firstIndex(where: { $0.id == id }) else { return }
        guard communities[idx].creatorUserId == actor.id else { throw SharedCommunityError.notAllowed }
        communities[idx].deletedAt = Date()
        communities[idx].updatedAt = Date()
        persist()
    }

    func updateVisibility(id: UUID, visibility: CommunityVisibility, actor: SharedCommunityUser) throws {
        guard let idx = communities.firstIndex(where: { $0.id == id }) else { return }
        guard communities[idx].creatorUserId == actor.id else { throw SharedCommunityError.notAllowed }
        if visibility == .public,
           communities.contains(where: { $0.id != id && $0.deletedAt == nil && $0.visibility == .public && $0.normalizedName == communities[idx].normalizedName }) {
            throw SharedCommunityError.duplicateName
        }
        communities[idx].visibility = visibility
        communities[idx].updatedAt = Date()
        persist()
    }

    func blockUser(communityID: UUID, userID: String, actor: SharedCommunityUser) throws {
        guard let idx = communities.firstIndex(where: { $0.id == communityID }) else { return }
        guard communities[idx].creatorUserId == actor.id else { throw SharedCommunityError.notAllowed }
        let blockedID = SharedCommunityUser.devUserID(for: userID)
        if !communities[idx].blockedUserIds.contains(blockedID) {
            communities[idx].blockedUserIds.append(blockedID)
        }
        if let memberID = SharedCommunityUser.memberID(for: blockedID) {
            communities[idx].members.removeAll { $0 == memberID }
            membersByCommunity[communityID] = membersByCommunity[communityID]?.filter { $0.id != memberID }
        }
        communities[idx].updatedAt = Date()
        persist()
    }

    func unblockUser(communityID: UUID, userID: String, actor: SharedCommunityUser) throws {
        guard let idx = communities.firstIndex(where: { $0.id == communityID }) else { return }
        guard communities[idx].creatorUserId == actor.id else { throw SharedCommunityError.notAllowed }
        let blockedID = SharedCommunityUser.devUserID(for: userID)
        communities[idx].blockedUserIds.removeAll { $0 == blockedID }
        communities[idx].updatedAt = Date()
        persist()
    }

    func listGroups(in communityID: UUID) -> [GroupChat] {
        groups.filter { $0.communityID == communityID }
    }

    func createGroup(_ group: GroupChat) -> GroupChat {
        groups.append(group)
        persist()
        return group
    }

    func updateGroup(_ group: GroupChat) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
        persist()
    }

    func members(of communityID: UUID) -> [CommunityMember] {
        guard let idx = communities.firstIndex(where: { $0.id == communityID }) else {
            return membersByCommunity[communityID] ?? []
        }
        repairCreatorMembershipIfNeeded(for: idx)
        return membersByCommunity[communityID] ?? []
    }

    func addMember(communityID: UUID, handle: String, role: GroupRole, actor: SharedCommunityUser) throws -> CommunityMember {
        guard let idx = communities.firstIndex(where: { $0.id == communityID }) else { throw SharedCommunityError.notAllowed }
        guard communities[idx].creatorUserId == actor.id else { throw SharedCommunityError.notAllowed }
        let user = SharedCommunityUser(handle: SharedCommunityUser.normalizedHandle(handle))
        if communities[idx].blockedUserIds.contains(user.id) || communities[idx].bannedUserIds.contains(user.id) {
            throw SharedCommunityError.blocked
        }
        let member = CommunityMember(id: user.memberID, displayName: user.displayName, handle: user.handle, role: role, isMuted: false)
        if !communities[idx].members.contains(user.memberID) {
            communities[idx].members.append(user.memberID)
        }
        var list = membersByCommunity[communityID] ?? []
        if !list.contains(where: { $0.id == user.memberID || $0.handle.caseInsensitiveCompare(user.handle) == .orderedSame }) {
            list.append(member)
        }
        communities[idx].updatedAt = Date()
        membersByCommunity[communityID] = list
        persist()
        return member
    }

    func removeMember(communityID: UUID, memberID: UUID, actor: SharedCommunityUser) throws {
        guard let idx = communities.firstIndex(where: { $0.id == communityID }) else { return }
        guard communities[idx].creatorUserId == actor.id || actor.memberID == memberID else { throw SharedCommunityError.notAllowed }
        communities[idx].members.removeAll { $0 == memberID }
        communities[idx].updatedAt = Date()
        membersByCommunity[communityID] = membersByCommunity[communityID]?.filter { $0.id != memberID }
        persist()
    }

    func fetchMessages(communityId: UUID) -> [CommunityMessage] {
        (messagesByCommunity[communityId] ?? communities.first(where: { $0.id == communityId })?.messages ?? [])
            .sorted { $0.sentAt < $1.sentAt }
    }

    func fetchMessages(communityId: UUID, since: Date) -> [CommunityMessage] {
        fetchMessages(communityId: communityId)
            .filter { $0.sentAt > since }
    }

    func sendMessage(_ text: String, in communityID: UUID, sender: SharedCommunityUser, clientMessageId: UUID? = nil) throws -> CommunityMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SharedCommunityError.emptyMessage }
        if let clientMessageId,
           let existing = messagesByCommunity[communityID]?.first(where: { $0.clientMessageId == clientMessageId }) {
            return existing
        }
        guard let idx = communities.firstIndex(where: { $0.id == communityID }) else { throw SharedCommunityError.notAllowed }
        repairMembershipIfNeeded(for: idx, user: sender)
        let community = communities[idx]
        let memberList = membersByCommunity[communityID] ?? []
        let canSend = community.members.contains(sender.memberID)
            || memberList.contains { $0.id == sender.memberID || $0.handle.caseInsensitiveCompare(sender.handle) == .orderedSame }
            || community.creatorUserId == sender.id
            || community.creatorHandle.caseInsensitiveCompare(sender.handle) == .orderedSame

        guard community.deletedAt == nil,
              canSend,
              !community.blockedUserIds.contains(sender.id),
              !community.bannedUserIds.contains(sender.id) else {
            throw SharedCommunityError.notAllowed
        }

        let now = Date()
        let message = CommunityMessage(
            id: UUID(),
            clientMessageId: clientMessageId,
            communityID: communityID,
            senderID: sender.memberID,
            senderName: sender.displayName,
            senderHandle: sender.handle,
            body: trimmed,
            sentAt: now,
            deliveryStatus: .delivered
        )
        messagesByCommunity[communityID, default: []].append(message)
        communities[idx].messages = messagesByCommunity[communityID] ?? []
        communities[idx].updatedAt = now
        persist()
        return message
    }

    func repairOneWayClan() throws -> CommunityRepairReport {
        try repairPublicCommunity(named: "OneWay Clan", requiredUsers: [
            SharedCommunityUser(handle: "@king"),
            SharedCommunityUser(handle: "@twinblixx")
        ])
    }

    func repairPublicCommunity(named name: String, requiredUsers: [SharedCommunityUser]) throws -> CommunityRepairReport {
        let normalized = Community.normalizedName(for: name)
        let duplicateIndexes = communities.indices
            .filter { idx in
                communities[idx].deletedAt == nil
                    && communities[idx].visibility == .public
                    && communities[idx].normalizedName == normalized
            }
            .sorted { communities[$0].createdAt < communities[$1].createdAt }

        let canonical: Community
        if let canonicalIndex = duplicateIndexes.first {
            canonical = communities[canonicalIndex]
        } else {
            canonical = try getOrCreatePublicCommunity(name: name, creator: requiredUsers.first ?? SharedCommunityUser(handle: "@king"))
        }

        guard let canonicalIndex = communities.firstIndex(where: { $0.id == canonical.id }) else {
            throw SharedCommunityError.notAllowed
        }

        let duplicateIDs = duplicateIndexes
            .map { communities[$0].id }
            .filter { $0 != canonical.id }

        var mergedMemberIDs = Set(communities[canonicalIndex].members)
        var mergedMembersByHandle: [String: CommunityMember] = [:]
        for member in membersByCommunity[canonical.id] ?? [] {
            mergedMembersByHandle[member.handle.lowercased()] = member
        }
        var mergedMessages = messagesByCommunity[canonical.id] ?? communities[canonicalIndex].messages

        for duplicateID in duplicateIDs {
            guard let duplicateIndex = communities.firstIndex(where: { $0.id == duplicateID }) else { continue }
            mergedMemberIDs.formUnion(communities[duplicateIndex].members)
            for member in membersByCommunity[duplicateID] ?? [] {
                mergedMembersByHandle[member.handle.lowercased()] = member
                mergedMemberIDs.insert(member.id)
            }
            mergedMessages.append(contentsOf: messagesByCommunity[duplicateID] ?? communities[duplicateIndex].messages)
            communities[duplicateIndex].deletedAt = Date()
            communities[duplicateIndex].updatedAt = Date()
            membersByCommunity.removeValue(forKey: duplicateID)
            messagesByCommunity.removeValue(forKey: duplicateID)
        }

        communities[canonicalIndex].members = Array(mergedMemberIDs)
        membersByCommunity[canonical.id] = Array(mergedMembersByHandle.values).sorted { $0.displayName < $1.displayName }
        messagesByCommunity[canonical.id] = dedupeMessages(mergedMessages)
        communities[canonicalIndex].messages = messagesByCommunity[canonical.id] ?? []
        communities[canonicalIndex].updatedAt = Date()

        for user in requiredUsers {
            _ = try ensureMember(communityId: canonical.id, user: user, role: communities[canonicalIndex].creatorUserId == user.id ? .owner : .member)
        }

        let repaired = communities.first(where: { $0.id == canonical.id }) ?? canonical
        persist()
        print("COMMUNITY_REPAIR canonical community.id:", repaired.id.uuidString)
        print("COMMUNITY_REPAIR merged duplicate ids:", duplicateIDs.map(\.uuidString).joined(separator: ", "))
        return CommunityRepairReport(
            canonicalCommunityID: repaired.id,
            canonicalName: repaired.name,
            mergedDuplicateIDs: duplicateIDs,
            memberCount: repaired.members.count,
            messageCount: fetchMessages(communityId: repaired.id).count
        )
    }

    func runTwoAccountSharedStateTest(clearExisting: Bool = true) throws -> CommunityTwoAccountTestReport {
        var steps: [CommunityTwoAccountTestStep] = []
        func pass(_ title: String, _ detail: String) {
            steps.append(CommunityTwoAccountTestStep(title: title, detail: detail, passed: true))
            print("COMMUNITY_TWO_ACCOUNT_TEST PASS:", title, "-", detail)
        }
        func fail(_ title: String, _ detail: String) throws -> Never {
            steps.append(CommunityTwoAccountTestStep(title: title, detail: detail, passed: false))
            print("COMMUNITY_TWO_ACCOUNT_TEST FAIL:", title, "-", detail)
            throw SharedCommunityError.qaFailed(detail)
        }

        let name = "OneWay Test Clan"
        let normalized = Community.normalizedName(for: name)
        let king = SharedCommunityUser(handle: "@king")
        let twinblixx = SharedCommunityUser(handle: "@twinblixx")

        if clearExisting {
            let removed = removeCommunities(named: normalized)
            pass("Clear duplicates", "Removed \(removed) existing '\(name)' record(s).")
        }

        guard community(named: name) == nil else {
            try fail("Preflight duplicate check", "'\(name)' still exists before create.")
        }
        pass("Preflight duplicate check", "No existing '\(name)' public community.")

        let created = try openSharedCommunity(name: name, users: [king, twinblixx])
        pass("Create as @king", "Created \(created.name) with id \(created.id).")

        _ = try sendMessage("King is here.", in: created.id, sender: king)
        pass("King sends message", "Stored 'King is here.' in global messages.")

        let twinSearch = searchPublicCommunities(query: name)
        guard twinSearch.contains(where: { $0.id == created.id }) else {
            try fail("Twinblixx search", "@twinblixx could not find \(name) in public search.")
        }
        pass("Twinblixx search", "@twinblixx can find the same public community.")

        _ = try ensureMember(communityId: created.id, user: twinblixx)
        pass("Twinblixx joins", "@twinblixx joined the same community id.")

        let messagesAfterJoin = fetchMessages(communityId: created.id)
        guard messagesAfterJoin.contains(where: { $0.senderHandle == "@king" && $0.body == "King is here." }) else {
            try fail("Twinblixx sees King message", "King's message was not visible after join.")
        }
        pass("Twinblixx sees King message", "King's message is visible from the shared message store.")

        _ = try sendMessage("Twinblixx joined.", in: created.id, sender: twinblixx)
        pass("Twinblixx sends message", "Stored 'Twinblixx joined.' in global messages.")

        let kingMessages = fetchMessages(communityId: created.id)
        guard kingMessages.contains(where: { $0.senderHandle == "@king" && $0.body == "King is here." }),
              kingMessages.contains(where: { $0.senderHandle == "@twinblixx" && $0.body == "Twinblixx joined." }) else {
            try fail("King sees both messages", "Both messages were not visible from @king's read path.")
        }
        pass("King sees both messages", "@king sees both shared messages.")

        let memberCount = members(of: created.id).count
        guard memberCount == 2 else {
            try fail("Member count", "Expected 2 members, found \(memberCount).")
        }
        pass("Member count", "Member count is 2.")

        do {
            _ = try createCommunity(
                Community(
                    id: UUID(),
                    name: name,
                    description: "Duplicate should be blocked.",
                    creatorUserId: "",
                    creatorHandle: "",
                    visibility: .public,
                    coverImageURL: nil,
                    avatarURL: nil,
                    ownerID: twinblixx.memberID,
                    admins: [],
                    moderators: [],
                    members: [],
                    blockedUserIds: [],
                    bannedUserIds: [],
                    messages: [],
                    linkedGroupIDs: [],
                    createdAt: Date(),
                    updatedAt: Date(),
                    deletedAt: nil
                ),
                creator: twinblixx
            )
            try fail("Duplicate blocked", "Duplicate public community creation unexpectedly succeeded.")
        } catch SharedCommunityError.duplicateName {
            pass("Duplicate blocked", "Duplicate public name was blocked.")
        }

        persist()
        return CommunityTwoAccountTestReport(communityID: created.id, steps: steps)
    }

    private func repairCreatorMembershipIfNeeded(for idx: Int) {
        let community = communities[idx]
        let creator = SharedCommunityUser(handle: community.creatorHandle.isEmpty ? "@king" : community.creatorHandle)
        repairMembershipIfNeeded(for: idx, user: creator, role: .owner)
    }

    private func repairMembershipIfNeeded(for idx: Int, user: SharedCommunityUser, role: GroupRole = .member) {
        let communityID = communities[idx].id
        var didChange = false

        if communities[idx].creatorUserId == user.id || communities[idx].creatorHandle.caseInsensitiveCompare(user.handle) == .orderedSame {
            if !communities[idx].members.contains(user.memberID) {
                communities[idx].members.append(user.memberID)
                didChange = true
            }
        }

        var list = membersByCommunity[communityID] ?? []
        let hasHandle = list.contains { $0.handle.caseInsensitiveCompare(user.handle) == .orderedSame }
        let hasID = list.contains { $0.id == user.memberID }
        if communities[idx].members.contains(user.memberID), !hasHandle, !hasID {
            let memberRole: GroupRole = (communities[idx].creatorUserId == user.id || role == .owner) ? .owner : role
            list.append(CommunityMember(id: user.memberID, displayName: user.displayName, handle: user.handle, role: memberRole, isMuted: false))
            membersByCommunity[communityID] = list
            didChange = true
        }

        if didChange {
            communities[idx].updatedAt = Date()
            persist()
        }
    }

    private func isVisible(_ community: Community, to user: SharedCommunityUser) -> Bool {
        guard community.deletedAt == nil else { return false }
        guard !community.blockedUserIds.contains(user.id), !community.bannedUserIds.contains(user.id) else { return false }
        if community.creatorUserId == user.id || community.members.contains(user.memberID) {
            return true
        }
        return community.visibility == .public
    }

    private static func normalizedLoadedCommunities(_ communities: [Community]) -> [Community] {
        dedupePublicCommunities(communities.map { community in
            var normalized = community
            normalized.normalizedName = Community.normalizedName(for: community.name)
            if normalized.creatorUserId.isEmpty {
                normalized.creatorUserId = SharedCommunityUser.devUserID(for: normalized.creatorHandle)
            }
            return normalized
        })
    }

    private static func dedupePublicCommunities(_ communities: [Community]) -> [Community] {
        var seenPublicNames = Set<String>()
        var result: [Community] = []
        for community in communities.sorted(by: { $0.createdAt < $1.createdAt }) {
            var normalized = community
            normalized.normalizedName = Community.normalizedName(for: community.name)
            if normalized.deletedAt == nil && normalized.visibility == .public {
                guard !seenPublicNames.contains(normalized.normalizedName) else { continue }
                seenPublicNames.insert(normalized.normalizedName)
            }
            result.append(normalized)
        }
        return result
    }

    @discardableResult
    private func removeCommunities(named normalizedName: String) -> Int {
        let ids = communities
            .filter { $0.normalizedName == normalizedName || Community.normalizedName(for: $0.name) == normalizedName }
            .map(\.id)
        guard !ids.isEmpty else { return 0 }
        communities.removeAll { ids.contains($0.id) }
        for id in ids {
            membersByCommunity.removeValue(forKey: id)
            messagesByCommunity.removeValue(forKey: id)
            groups.removeAll { $0.communityID == id }
        }
        persist()
        return ids.count
    }

    private static func messages(from communities: [Community]) -> [UUID: [CommunityMessage]] {
        Dictionary(uniqueKeysWithValues: communities.map { ($0.id, $0.messages) })
    }

    private func dedupeMessages(_ messages: [CommunityMessage]) -> [CommunityMessage] {
        var seen = Set<UUID>()
        return messages
            .sorted { $0.sentAt < $1.sentAt }
            .filter { message in
                if seen.contains(message.id) { return false }
                seen.insert(message.id)
                return true
            }
    }

    private static func seedCommunity() -> (community: Community, members: [CommunityMember], group: GroupChat) {
        let now = Date()
        let owner = SharedCommunityUser(handle: "@king")
        let communityID = UUID()
        let groupID = UUID()
        let alexID = UUID()
        let priyaID = UUID()
        let members = [
            CommunityMember(id: owner.memberID, displayName: owner.displayName, handle: owner.handle, role: .owner, isMuted: false),
            CommunityMember(id: alexID, displayName: "Alex", handle: "@alex", role: .admin, isMuted: false),
            CommunityMember(id: priyaID, displayName: "Priya", handle: "@priya", role: .member, isMuted: false)
        ]
        let community = Community(
            id: communityID,
            name: "Core Builders",
            normalizedName: Community.normalizedName(for: "Core Builders"),
            description: "Internal coordination community",
            creatorUserId: owner.id,
            creatorHandle: owner.handle,
            visibility: .public,
            coverImageURL: nil,
            avatarURL: nil,
            ownerID: owner.memberID,
            admins: [alexID],
            moderators: [],
            members: members.map(\.id),
            blockedUserIds: [],
            bannedUserIds: [],
            messages: [],
            linkedGroupIDs: [groupID],
            createdAt: now.addingTimeInterval(-3600),
            updatedAt: now.addingTimeInterval(-600),
            deletedAt: nil
        )
        let group = GroupChat(
            id: groupID,
            communityID: communityID,
            name: "Announcements",
            topic: "Core updates",
            memberIDs: members.map(\.id),
            lastMessageAt: now.addingTimeInterval(-600),
            lastMessagePreview: "Welcome to the community!",
            isMuted: false,
            isArchived: false,
            disappearingAfterSeconds: nil
        )
        return (community, members, group)
    }

    private func persist() {
        Self.save(communities, key: Self.communitiesKey)
        Self.save(membersByCommunity, key: Self.membersKey)
        Self.save(messagesByCommunity, key: Self.messagesKey)
        Self.save(groups, key: Self.groupsKey)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct SharedCommunityUser {
    private static let lastLoginIdentifierKey = "OneWay.LastLoginIdentifier"

    let id: String
    let handle: String
    let displayName: String
    let memberID: UUID

    static func current() -> SharedCommunityUser {
        let candidates = [
            UserDefaults.standard.string(forKey: lastLoginIdentifierKey),
            UserDefaults.standard.string(forKey: "OneWay.DebugLoginIdentifierOverride"),
            UserDefaults.standard.string(forKey: "OneWay.DebugLoginIdentifier"),
            ProcessInfo.processInfo.environment["ONEWAY_DEBUG_LOGIN_IDENTIFIER"]
        ]
        let raw = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return SharedCommunityUser(handle: raw ?? "king")
    }

    init(handle rawHandle: String) {
        handle = Self.normalizedHandle(rawHandle)
        id = Self.devUserID(for: handle)
        displayName = handle.dropFirst().capitalized
        memberID = Self.memberID(for: id) ?? UUID(uuidString: Self.stableUUIDString(for: id)) ?? UUID()
    }

    static func normalizedHandle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        return "@\(trimmed)"
    }

    static func devUserID(for value: String) -> String {
        let normalized = normalizedHandle(value)
        switch normalized {
        case "@king":
            return "dev-user-king"
        case "@twinblixx":
            return "dev-user-twinblixx"
        default:
            if value.hasPrefix("dev-user-") { return value }
            return "dev-user-\(normalized.dropFirst())"
        }
    }

    static func memberID(for userID: String) -> UUID? {
        switch userID {
        case "dev-user-king":
            return UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        case "dev-user-twinblixx":
            return UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        default:
            return UUID(uuidString: stableUUIDString(for: userID))
        }
    }

    private static func stableUUIDString(for value: String) -> String {
        let hash = abs(value.hashValue)
        return String(format: "00000000-0000-0000-0000-%012lld", hash % 1_000_000_000_000)
    }
}

enum SharedCommunityError: LocalizedError {
    case duplicateName
    case emptyMessage
    case notAllowed
    case blocked
    case deleted
    case qaFailed(String)

    var errorDescription: String? {
        switch self {
        case .duplicateName:
            return "A community with this name already exists."
        case .emptyMessage:
            return "Enter a message."
        case .notAllowed:
            return "You do not have permission for that community action."
        case .blocked:
            return "You cannot join this community."
        case .deleted:
            return "This community was deleted."
        case .qaFailed(let message):
            return message
        }
    }
}

struct CommunityTwoAccountTestReport {
    let communityID: UUID
    let steps: [CommunityTwoAccountTestStep]

    var passed: Bool {
        steps.allSatisfy(\.passed)
    }
}

struct CommunityTwoAccountTestStep {
    let title: String
    let detail: String
    let passed: Bool
}

struct CommunityRepairReport {
    let canonicalCommunityID: UUID
    let canonicalName: String
    let mergedDuplicateIDs: [UUID]
    let memberCount: Int
    let messageCount: Int
}
