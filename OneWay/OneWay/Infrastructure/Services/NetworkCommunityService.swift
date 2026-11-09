import Foundation

@MainActor
final class NetworkCommunityService: CommunityService {
    private struct CommunitiesResponse: Decodable {
        let communities: [CommunityDTO]
    }

    private struct MembershipsResponse: Decodable {
        let memberships: [CommunityMembershipDTO]
    }

    private struct CommunityMembershipDTO: Decodable {
        let communityId: String
        let memberId: String
        let role: String
        let joinedAt: String
        let community: CommunityDTO?
    }

    private struct CommunityEnvelope: Decodable {
        let community: CommunityDTO
    }

    private struct MembersResponse: Decodable {
        let members: [CommunityMemberDTO]
    }

    private struct MemberEnvelope: Decodable {
        let member: CommunityMemberDTO
    }

    private struct MessagesResponse: Decodable {
        let messages: [CommunityMessageDTO]
    }

    private struct MessageEnvelope: Decodable {
        let message: CommunityMessageDTO
    }

    private struct RealtimeEnvelope: Decodable {
        let type: String
        let payload: RealtimePayload?
    }

    private struct RealtimePayload: Decodable {
        let message: CommunityMessageDTO?
        let community: CommunityDTO?
        let code: String?
        let error: String?
        let communityId: String?
    }

    private struct WireMessage: Encodable {
        let type: String
        let payload: [String: String]
    }

    private struct EmptyRequest: Encodable {}

    private struct CreateCommunityRequest: Encodable {
        let name: String
        let description: String
        let visibility: String
    }

    private struct UpdateCommunityRequest: Encodable {
        let name: String?
        let description: String?
        let visibility: String?
    }

    private struct AddMemberRequest: Encodable {
        let userId: String?
        let handle: String?
        let role: String
    }

    private struct BlockMemberRequest: Encodable {
        let userId: String
    }

    private struct SendMessageRequest: Encodable {
        let body: String
        let clientMessageId: String?
    }

    private struct CommunityDTO: Decodable {
        let id: String
        let name: String
        let normalizedName: String?
        let description: String
        let creatorUserId: String
        let creatorHandle: String
        let visibility: String
        let blockedUserIds: [String]?
        let bannedUserIds: [String]?
        let members: [CommunityMemberDTO]?
        let createdAt: String
        let updatedAt: String
        let deletedAt: String?
    }

    private struct CommunityMemberDTO: Decodable {
        let id: String
        let userId: String?
        let displayName: String
        let handle: String
        let role: String
    }

    private struct CommunityMessageDTO: Decodable {
        let id: String
        let clientMessageId: String?
        let communityId: String
        let senderId: String
        let senderHandle: String
        let senderDisplayName: String
        let body: String
        let status: String
        let createdAt: String
    }

    private let client: APIClient
    private nonisolated var cacheNamespace: String {
        AuthTokenStore.shared.diagnosticsCacheNamespace
    }
    private nonisolated var communitiesCacheKey: String {
        "oneway.communities.cache.\(cacheNamespace).public"
    }
    private nonisolated var membershipCacheKey: String {
        "oneway.communities.cache.\(cacheNamespace).joinedIds"
    }

    init(client: APIClient = .shared) {
        self.client = client
    }

    func listCommunities() async throws -> [Community] {
        try await fetchPublicCommunities()
    }

    func cachedCommunities() async -> [Community] {
        let startedAt = CommunityPerformanceLogger.mark("community cache load")
        defer { CommunityPerformanceLogger.finish("community cache load", startedAt: startedAt) }
        let key = communitiesCacheKey
        guard let data = UserDefaults.standard.data(forKey: key),
              let communities = try? JSONDecoder().decode([Community].self, from: data) else {
            return []
        }
        return communities.filter { $0.deletedAt == nil }
    }

    func fetchPublicCommunities() async throws -> [Community] {
        let startedAt = CommunityPerformanceLogger.mark("fetchPublicCommunities")
        defer { CommunityPerformanceLogger.finish("fetchPublicCommunities", startedAt: startedAt) }
        let response: CommunitiesResponse = try await client.get("api/communities")
        let communities = response.communities.compactMap(mapCommunity)
        await persistCommunities(communities)
        return communities
    }

    func searchPublicCommunities(query: String) async throws -> [Community] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await fetchPublicCommunities() }
        let response: CommunitiesResponse = try await client.get(
            "api/communities",
            queryItems: [URLQueryItem(name: "q", value: trimmed)]
        )
        let communities = response.communities.compactMap(mapCommunity)
        await persistCommunities(communities)
        return communities
    }

    func cachedJoinedCommunityIDs() async -> Set<UUID> {
        let startedAt = CommunityPerformanceLogger.mark("membership cache load")
        defer { CommunityPerformanceLogger.finish("membership cache load", startedAt: startedAt) }
        let key = membershipCacheKey
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    func fetchMyMembershipIDs() async throws -> Set<UUID> {
        let startedAt = CommunityPerformanceLogger.mark("backend membership fetch")
        defer { CommunityPerformanceLogger.finish("backend membership fetch", startedAt: startedAt) }
        let response: MembershipsResponse = try await client.get("api/communities/me/memberships")
        let ids = Set(response.memberships.compactMap { UUID(uuidString: $0.communityId) })
        await persistMembershipIDs(ids)
        let communities = response.memberships.compactMap(\.community).compactMap(mapCommunity)
        if !communities.isEmpty {
            await mergeCachedCommunities(communities)
        }
        return ids
    }

    func community(named name: String) async throws -> Community? {
        let normalized = Community.normalizedName(for: name)
        return try await searchPublicCommunities(query: name)
            .first { $0.normalizedName == normalized && $0.deletedAt == nil }
    }

    func createCommunity(_ community: Community) async throws -> Community {
        let startedAt = CommunityPerformanceLogger.mark("createCommunity")
        defer { CommunityPerformanceLogger.finish("createCommunity", startedAt: startedAt) }
        let response: CommunityEnvelope = try await client.post(
            "api/communities",
            body: CreateCommunityRequest(
                name: community.name,
                description: community.description,
                visibility: community.visibility.rawValue
            )
        )
        guard let mapped = mapCommunity(response.community) else { throw APIClientError.invalidResponse }
        OneWayGrowthEventReporter.shared.recordFirst(.communityCreated, anonymousUserKey: AuthTokenStore.shared.currentUserID().lowercased(), metadata: ["success": "true"])
        return mapped
    }

    func updateCommunity(_ community: Community) async throws {
        let _: CommunityEnvelope = try await client.patch(
            "api/communities/\(community.id.uuidString.lowercased())",
            body: UpdateCommunityRequest(
                name: community.name,
                description: community.description,
                visibility: community.visibility.rawValue
            )
        )
    }

    func joinCommunity(id: UUID) async throws {
        let startedAt = CommunityPerformanceLogger.mark("joinCommunity")
        defer {
            _ = OneWayPerformanceLogger.finish(
                "community.join.visibleUpdate",
                startedAt: startedAt,
                target: .communityJoinVisibleUpdate,
                metadata: "communityId=\(id.uuidString.lowercased())"
            )
        }
        CommunityPerformanceLogger.profile("client.communityJoin.request", clientMessageId: nil, communityId: id)
        let response: CommunityEnvelope = try await client.post(
            "api/communities/\(id.uuidString.lowercased())/join",
            body: EmptyRequest()
        )
        await insertMembershipID(id)
        if let community = mapCommunity(response.community) {
            await mergeCachedCommunities([community])
        }
        OneWayGrowthEventReporter.shared.recordFirst(.communityJoined, anonymousUserKey: AuthTokenStore.shared.currentUserID().lowercased(), metadata: ["success": "true"])
    }

    func leaveCommunity(id: UUID) async throws {
        let startedAt = CommunityPerformanceLogger.mark("leaveCommunity")
        defer { CommunityPerformanceLogger.finish("leaveCommunity", startedAt: startedAt, metadata: id.uuidString.lowercased()) }
        CommunityPerformanceLogger.profile("client.communityLeave.request", clientMessageId: nil, communityId: id)
        let _: EmptyAPIResponse = try await client.delete("api/communities/\(id.uuidString.lowercased())/leave")
        await removeMembershipID(id)
    }

    func deleteCommunity(id: UUID) async throws {
        let _: EmptyAPIResponse = try await client.delete("api/communities/\(id.uuidString.lowercased())")
    }

    func updateCommunityVisibility(id: UUID, visibility: CommunityVisibility) async throws {
        let _: CommunityEnvelope = try await client.patch(
            "api/communities/\(id.uuidString.lowercased())",
            body: UpdateCommunityRequest(name: nil, description: nil, visibility: visibility.rawValue)
        )
    }

    func blockUser(communityID: UUID, userID: String) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "api/communities/\(communityID.uuidString.lowercased())/blocks",
            body: BlockMemberRequest(userId: userID)
        )
    }

    func unblockUser(communityID: UUID, userID: String) async throws {
        let target = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        let _: EmptyAPIResponse = try await client.delete(
            "api/communities/\(communityID.uuidString.lowercased())/blocks/\(target)"
        )
    }

    func listGroups(in communityID: UUID) async throws -> [GroupChat] {
        _ = communityID
        return []
    }

    func createGroup(in communityID: UUID, group: GroupChat) async throws -> GroupChat {
        _ = communityID
        return group
    }

    func updateGroup(_ group: GroupChat) async throws {
        _ = group
    }

    func members(of communityID: UUID) async throws -> [CommunityMember] {
        let response: MembersResponse = try await client.get("api/communities/\(communityID.uuidString.lowercased())/members")
        return response.members.compactMap(mapMember)
    }

    func addMember(communityID: UUID, handle: String, role: GroupRole) async throws -> CommunityMember {
        let response: MemberEnvelope = try await client.post(
            "api/communities/\(communityID.uuidString.lowercased())/members",
            body: AddMemberRequest(userId: nil, handle: handle, role: role.rawValue)
        )
        guard let member = mapMember(response.member) else { throw APIClientError.invalidResponse }
        return member
    }

    func removeMember(communityID: UUID, memberID: UUID) async throws {
        let _: EmptyAPIResponse = try await client.delete(
            "api/communities/\(communityID.uuidString.lowercased())/members/\(memberID.uuidString.lowercased())"
        )
    }

    func fetchMessages(communityId: UUID) async throws -> [CommunityMessage] {
        try await messages(in: communityId)
    }

    func fetchMessages(communityId: UUID, since: Date) async throws -> [CommunityMessage] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let response: MessagesResponse = try await client.get(
            "api/communities/\(communityId.uuidString.lowercased())/messages",
            queryItems: [URLQueryItem(name: "since", value: formatter.string(from: since))]
        )
        return response.messages.compactMap(mapMessage)
    }

    func messages(in communityID: UUID) async throws -> [CommunityMessage] {
        let response: MessagesResponse = try await client.get("api/communities/\(communityID.uuidString.lowercased())/messages")
        return response.messages.compactMap(mapMessage)
    }

    func sendMessage(_ text: String, in communityID: UUID) async throws -> CommunityMessage {
        try await sendMessage(text, in: communityID, clientMessageId: UUID())
    }

    func sendMessage(_ text: String, in communityID: UUID, clientMessageId: UUID) async throws -> CommunityMessage {
        let socketStartedAt = CommunityPerformanceLogger.mark("sendMessage socket")
        do {
            let message = try await CommunityRealtimeClient.shared.sendMessage(
                body: text,
                communityId: communityID,
                clientMessageId: clientMessageId,
                baseURL: client.baseURL
            )
            CommunityPerformanceLogger.finish("sendMessage socket", startedAt: socketStartedAt, metadata: clientMessageId.uuidString.lowercased())
            return message
        } catch {
            CommunityPerformanceLogger.finish("sendMessage socket fallback", startedAt: socketStartedAt, metadata: clientMessageId.uuidString.lowercased())
        }

        let startedAt = CommunityPerformanceLogger.mark("sendMessage API")
        defer { CommunityPerformanceLogger.finish("sendMessage API", startedAt: startedAt, metadata: clientMessageId.uuidString.lowercased()) }
        let response: MessageEnvelope = try await client.post(
            "api/communities/\(communityID.uuidString.lowercased())/messages",
            body: SendMessageRequest(body: text, clientMessageId: clientMessageId.uuidString.lowercased())
        )
        guard let message = mapMessage(response.message) else { throw APIClientError.invalidResponse }
        return message
    }

    func sendVoiceMessage(_ data: Data, in communityID: UUID, clientMessageId: UUID, disappearing: MessageDisappearingOverride) async throws -> CommunityMessage {
        struct VoiceEnvelope: Encodable {
            let onewayVoice = true
            let payloadBase64: String
            let disappearing: String
            let expirationDurationSeconds: Int?
        }
        let envelope = VoiceEnvelope(
            payloadBase64: data.base64EncodedString(),
            disappearing: disappearing.rawValue,
            expirationDurationSeconds: disappearing == .afterRead ? 60 : nil
        )
        let encoded = try JSONEncoder().encode(envelope)
        guard let body = String(data: encoded, encoding: .utf8) else { throw APIClientError.invalidResponse }
        let response: MessageEnvelope = try await client.post(
            "api/communities/\(communityID.uuidString.lowercased())/messages",
            body: SendMessageRequest(body: body, clientMessageId: clientMessageId.uuidString.lowercased())
        )
        guard let message = mapMessage(response.message) else { throw APIClientError.invalidResponse }
        return message
    }

    nonisolated func subscribeToCommunityMessages(communityId: UUID) -> AsyncThrowingStream<CommunityMessage, Error> {
        CommunityRealtimeClient.shared.subscribeToMessages(communityId: communityId, baseURL: APIClient.shared.baseURL)
    }

    nonisolated func subscribeToCommunityRealtimeState() -> AsyncStream<CommunityRealtimeConnectionState> {
        CommunityRealtimeClient.shared.subscribeToConnectionState()
    }

    nonisolated func subscribeToCommunityDiscovery() -> AsyncThrowingStream<Community, Error> {
        CommunityRealtimeClient.shared.subscribeToDiscovery(baseURL: APIClient.shared.baseURL)
    }

    nonisolated func subscribeToCommunityTyping(communityId: UUID) -> AsyncStream<CommunityTypingEvent> {
        CommunityRealtimeClient.shared.subscribeToTyping(communityId: communityId, baseURL: APIClient.shared.baseURL)
    }

    nonisolated func sendCommunityTyping(communityId: UUID, isTyping: Bool) {
        CommunityRealtimeClient.shared.sendTyping(communityId: communityId, isTyping: isTyping, baseURL: APIClient.shared.baseURL)
    }

    nonisolated func subscribeToCommunityPresence(communityId: UUID) -> AsyncStream<CommunityPresenceEvent> {
        CommunityRealtimeClient.shared.subscribeToPresence(communityId: communityId, baseURL: APIClient.shared.baseURL)
    }

    nonisolated func subscribeToCommunityReads(communityId: UUID) -> AsyncStream<CommunityReadEvent> {
        CommunityRealtimeClient.shared.subscribeToReads(communityId: communityId, baseURL: APIClient.shared.baseURL)
    }

    nonisolated func markCommunityMessageRead(communityId: UUID, messageId: UUID) {
        CommunityRealtimeClient.shared.sendRead(communityId: communityId, messageId: messageId, baseURL: APIClient.shared.baseURL)
    }

    nonisolated func preconnectRealtime() {
        CommunityRealtimeClient.shared.preconnect(baseURL: APIClient.shared.baseURL)
    }

    nonisolated func realtimeHealthSnapshot() -> String {
        CommunityRealtimeClient.shared.healthSnapshot()
    }

    private nonisolated func mapCommunity(_ dto: CommunityDTO) -> Community? {
        Self.mapRealtimeCommunity(dto)
    }

    private nonisolated static func mapRealtimeCommunity(_ dto: CommunityDTO) -> Community? {
        guard let id = UUID(uuidString: dto.id) else { return nil }
        let members = dto.members?.compactMap(Self.memberUUID) ?? []
        let createdAt = Self.parseDate(dto.createdAt)
        let updatedAt = Self.parseDate(dto.updatedAt)
        let creatorUUID = UUID(uuidString: dto.creatorUserId) ?? id
        return Community(
            id: id,
            name: dto.name,
            normalizedName: dto.normalizedName ?? Community.normalizedName(for: dto.name),
            description: dto.description,
            creatorUserId: dto.creatorUserId,
            creatorHandle: dto.creatorHandle,
            visibility: CommunityVisibility(rawValue: dto.visibility) ?? .public,
            coverImageURL: nil,
            avatarURL: nil,
            ownerID: creatorUUID,
            admins: [creatorUUID],
            moderators: [],
            members: members,
            blockedUserIds: dto.blockedUserIds ?? [],
            bannedUserIds: dto.bannedUserIds ?? [],
            messages: [],
            linkedGroupIDs: [],
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: dto.deletedAt.map(Self.parseDate)
        )
    }

    private nonisolated func mapMember(_ dto: CommunityMemberDTO) -> CommunityMember? {
        guard let id = UUID(uuidString: dto.id) else { return nil }
        return CommunityMember(
            id: id,
            displayName: dto.displayName,
            handle: dto.handle,
            role: GroupRole(rawValue: dto.role) ?? .member,
            isMuted: false
        )
    }

    private nonisolated func mapMessage(_ dto: CommunityMessageDTO) -> CommunityMessage? {
        Self.mapRealtimeMessage(dto)
    }

    private nonisolated static func mapRealtimeMessage(_ dto: CommunityMessageDTO) -> CommunityMessage? {
        guard let id = UUID(uuidString: dto.id),
              let communityID = UUID(uuidString: dto.communityId) else {
            return nil
        }
        let senderID = UUID(uuidString: dto.senderId) ?? id
        return CommunityMessage(
            id: id,
            clientMessageId: dto.clientMessageId.flatMap(UUID.init(uuidString:)),
            communityID: communityID,
            senderID: senderID,
            senderName: dto.senderDisplayName,
            senderHandle: dto.senderHandle,
            body: dto.body,
            sentAt: Self.parseDate(dto.createdAt),
            deliveryStatus: MessageDeliveryStatus(rawValue: dto.status) ?? .sent
        )
    }

    private nonisolated static func webSocketURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "ws/communities"
        if DevAuth.authorizationHeader(forPath: "ws/communities", baseURL: baseURL) != nil {
            components.queryItems = [URLQueryItem(
                name: "token",
                value: AuthTokenStore.shared.authorizationHeader().replacingOccurrences(of: "Bearer ", with: "")
            )]
        }
        return components.url
    }

    private nonisolated static func memberUUID(_ dto: CommunityMemberDTO) -> UUID? {
        if let userId = dto.userId, let uuid = UUID(uuidString: userId) {
            return uuid
        }
        return UUID(uuidString: dto.id)
    }

    private nonisolated static func parseDate(_ value: String) -> Date {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: value) {
            return date
        }
        let relaxedISO8601 = ISO8601DateFormatter()
        relaxedISO8601.formatOptions = [.withInternetDateTime]
        if let date = relaxedISO8601.date(from: value) {
            return date
        }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return fallback.date(from: value) ?? Date()
    }

    private func persistCommunities(_ communities: [Community]) {
        guard let data = try? JSONEncoder().encode(communities) else { return }
        UserDefaults.standard.set(data, forKey: communitiesCacheKey)
    }

    private func mergeCachedCommunities(_ communities: [Community]) {
        var existing = Dictionary(uniqueKeysWithValues: (try? JSONDecoder().decode([Community].self, from: UserDefaults.standard.data(forKey: communitiesCacheKey) ?? Data()))?.map { ($0.id, $0) } ?? [])
        for community in communities {
            existing[community.id] = community
        }
        persistCommunities(existing.values.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.createdAt > $1.createdAt }
            return $0.updatedAt > $1.updatedAt
        })
    }

    private func persistMembershipIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map { $0.uuidString.lowercased() }.sorted(), forKey: membershipCacheKey)
    }

    private func insertMembershipID(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: membershipCacheKey) ?? []
        let value = id.uuidString.lowercased()
        if !ids.contains(value) {
            ids.append(value)
            UserDefaults.standard.set(ids.sorted(), forKey: membershipCacheKey)
        }
    }

    private func removeMembershipID(_ id: UUID) {
        let value = id.uuidString.lowercased()
        let ids = (UserDefaults.standard.stringArray(forKey: membershipCacheKey) ?? []).filter { $0 != value }
        UserDefaults.standard.set(ids, forKey: membershipCacheKey)
    }
}
