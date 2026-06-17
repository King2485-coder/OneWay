import Foundation

enum PresenceState: String, CaseIterable, Codable {
    case online
    case offline
}

enum CallType: String, CaseIterable {
    case voice
    case video
}

enum CallConnectionState: String, Codable, CaseIterable {
    case ringing
    case connecting
    case connected
    case reconnecting
    case ended
    case failed
    case missed
}

enum MessageDirection {
    case incoming
    case outgoing
}

enum MessageDeliveryStatus: String {
    case sending
    case sent
    case delivered
    case read
    case failed
}

enum MediaType: String, Codable {
    case photo
    case video
    case file
}

struct MessageAttachment: Equatable, Codable {
    let id: UUID
    let mediaType: MediaType
    let fileName: String
    let byteCount: Int
    let payload: Data
    let mimeType: String?

    init(id: UUID = UUID(), mediaType: MediaType, fileName: String, byteCount: Int, payload: Data, mimeType: String? = nil) {
        self.id = id
        self.mediaType = mediaType
        self.fileName = fileName
        self.byteCount = byteCount
        self.payload = payload
        self.mimeType = mimeType
    }
}

struct ChatSummary: Identifiable, Equatable {
    let id: UUID
    let participantName: String
    let participantHandle: String
    let lastMessagePreview: String
    let lastMessageAt: Date
    let unreadCount: Int
    let presence: PresenceState
    let isPinned: Bool
    let isMuted: Bool
    let isArchived: Bool
    let isGroup: Bool
    let disappearingAfterSeconds: TimeInterval?
    let draft: ChatDraft?

    init(
        id: UUID,
        participantName: String,
        participantHandle: String,
        lastMessagePreview: String,
        lastMessageAt: Date,
        unreadCount: Int,
        presence: PresenceState,
        isPinned: Bool,
        isMuted: Bool,
        isArchived: Bool,
        isGroup: Bool,
        disappearingAfterSeconds: TimeInterval? = nil,
        draft: ChatDraft? = nil
    ) {
        self.id = id
        self.participantName = participantName
        self.participantHandle = participantHandle
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.presence = presence
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isArchived = isArchived
        self.isGroup = isGroup
        self.disappearingAfterSeconds = disappearingAfterSeconds
        self.draft = draft
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let chatID: UUID
    let body: String
    let sentAt: Date
    let direction: MessageDirection
    let deliveryStatus: MessageDeliveryStatus
    let readAt: Date?
    let attachment: MessageAttachment?
    let expiresAt: Date?
    let replyToMessageID: UUID?
    let reactions: [MessageReaction]
    var isPinned: Bool
    var isStarred: Bool
    let editedAt: Date?
    let linkPreview: LinkPreview?
    let forwardedCount: Int

    init(
        id: UUID,
        chatID: UUID,
        body: String,
        sentAt: Date,
        direction: MessageDirection,
        deliveryStatus: MessageDeliveryStatus,
        readAt: Date?,
        attachment: MessageAttachment?,
        expiresAt: Date? = nil,
        replyToMessageID: UUID? = nil,
        reactions: [MessageReaction] = [],
        isPinned: Bool = false,
        isStarred: Bool = false,
        editedAt: Date? = nil,
        linkPreview: LinkPreview? = nil,
        forwardedCount: Int = 0
    ) {
        self.id = id
        self.chatID = chatID
        self.body = body
        self.sentAt = sentAt
        self.direction = direction
        self.deliveryStatus = deliveryStatus
        self.readAt = readAt
        self.attachment = attachment
        self.expiresAt = expiresAt
        self.replyToMessageID = replyToMessageID
        self.reactions = reactions
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.editedAt = editedAt
        self.linkPreview = linkPreview
        self.forwardedCount = forwardedCount
    }
}

struct UserProfile: Equatable {
    let userID: UUID
    let displayName: String
    var handle: String? = nil
    var avatarURL: URL? = nil
    var about: String? = nil
    var phoneNumber: String? = nil
    var email: String? = nil
}

struct ContactProfile: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var handle: String
    var about: String?
    var avatarURL: URL?
    var sharedGroupsCount: Int
    var isBlocked: Bool
}

struct ChatDraft: Equatable {
    let chatID: UUID
    var text: String
    var updatedAt: Date
}

struct MessageReaction: Identifiable, Equatable, Codable {
    let id: UUID
    let emoji: String
    let userID: UUID
    let createdAt: Date
}

struct LinkPreview: Equatable, Codable {
    let title: String
    let description: String
    let url: URL
    let imageURL: URL?
}

struct SharedStorefrontReference: Equatable, Codable {
    let storefrontID: UUID
    let name: String
    let url: URL?
}

struct SharedProductReference: Equatable, Codable {
    let productID: UUID
    let name: String
    let price: String
    let url: URL?
}

struct MessageReceipt: Identifiable, Equatable {
    let id: UUID
    let messageID: UUID
    let recipientID: UUID
    let status: MessageDeliveryStatus
    let occurredAt: Date
}

struct Conversation: Identifiable, Equatable {
    let id: UUID
    let participants: [UserProfile]
    let isGroup: Bool
    var title: String
    var topic: String?
    var lastUpdated: Date
    var settings: ConversationSettings
}

struct ConversationSettings: Equatable {
    var disappearingAfterSeconds: TimeInterval?
    var isPinned: Bool
    var isMuted: Bool
    var isArchived: Bool
}

struct EncryptedPayload: Equatable {
    let ciphertext: Data
    let nonce: Data
    let associatedData: Data?
}

struct EncryptedMessage: Identifiable, Equatable {
    let id: UUID
    let chatID: UUID
    let senderID: UUID
    let encryptedBody: EncryptedPayload
    let attachment: MessageAttachment?
    let sentAt: Date
    let expiresAt: Date?
}

struct CallParticipant: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let isMuted: Bool
    let isVideoEnabled: Bool
}

enum CallNetworkType: String, Equatable {
    case oneWayNative
    case pstnBridge

    var statusLabel: String {
        switch self {
        case .oneWayNative: return "Using OneWay Signal"
        case .pstnBridge: return "Using External Network"
        }
    }
}

struct CallSession: Identifiable, Equatable {
    let id: UUID
    let chatID: UUID
    let type: CallType
    var networkType: CallNetworkType
    var state: CallConnectionState
    var startedAt: Date
    var participants: [CallParticipant]
    var muted: Bool
    var speakerOn: Bool
    var cameraOn: Bool
    var isLocal: Bool
}

struct ServiceHealthStatus: Identifiable, Equatable {
    let id = UUID()
    let serviceName: String
    let isActive: Bool
    let lastCheckedAt: Date
    let lastSyncAt: Date?
    let lastError: String?
    let dependencies: [String]
}

struct PrivacySettings: Equatable, Codable {
    var lastSeenVisibility: StatusAudience
    var profilePhotoVisibility: StatusAudience
    var aboutVisibility: StatusAudience
    var readReceiptsEnabled: Bool
    var statusAudience: StatusAudience
    var blockedUserIDs: [UUID]
}

struct UserPresence: Equatable, Codable {
    let userID: UUID
    let state: PresenceState
    let lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case userID
        case state
        case lastSeen
    }
}

struct PinnedMessage: Identifiable, Equatable {
    let id: UUID
    let messageID: UUID
    let chatID: UUID
    let pinnedAt: Date
}

struct SavedMessage: Identifiable, Equatable {
    let id: UUID
    let messageID: UUID
    let chatID: UUID
    let savedAt: Date
}

// MARK: - Service protocols (co-located for visibility)

protocol CryptoService {
    func ensureIdentity() async throws -> CryptoIdentity
    func encrypt(message: PlaintextMessage, for recipient: UserProfile, context: MessageContext) async throws -> EncryptedMessage
    func decrypt(_ message: EncryptedMessage) async throws -> PlaintextMessage
    func groupSession(for groupID: UUID) async throws -> GroupCryptoSession
}

protocol NotificationService {
    func registerForPushIfNeeded() async
    func handleIncomingSilentPush(payload: [String: Any]) async
}

protocol StorageService {
    func storeCiphertext(_ message: EncryptedMessage)
    func loadCiphertext(chatID: UUID) -> [EncryptedMessage]
    func deleteCiphertext(messageID: UUID)
}

protocol CommunityService {
    func listCommunities() async throws -> [Community]
    func createCommunity(_ community: Community) async throws -> Community
    func updateCommunity(_ community: Community) async throws
    func joinCommunity(id: UUID) async throws
    func leaveCommunity(id: UUID) async throws
    func listGroups(in communityID: UUID) async throws -> [GroupChat]
    func createGroup(in communityID: UUID, group: GroupChat) async throws -> GroupChat
    func updateGroup(_ group: GroupChat) async throws
    func members(of communityID: UUID) async throws -> [CommunityMember]
    func addMember(communityID: UUID, handle: String, role: GroupRole) async throws -> CommunityMember
    func removeMember(communityID: UUID, memberID: UUID) async throws
}

@MainActor
protocol CallService {
    func startCall(chatID: UUID, type: CallType) async throws -> CallSession
    func answerCall(sessionID: UUID) async throws
    func declineCall(sessionID: UUID) async throws
    func endCall(sessionID: UUID) async throws
    func toggleMute(sessionID: UUID, isMuted: Bool) async throws
    func toggleSpeaker(sessionID: UUID, isOn: Bool) async throws
    func toggleCamera(sessionID: UUID, isOn: Bool) async throws
    func switchCamera(sessionID: UUID) async throws
    func observeActiveCalls() -> AsyncStream<CallSession>

    /// Pre-create a session for an incoming call surfaced by a VoIP push.
    /// The push handler MUST call this synchronously before reporting to
    /// CallKit; otherwise a subsequent answer would have no session to
    /// resume. Default implementation is a no-op for stubs.
    func prepareIncomingCall(callID: UUID, callerID: String, hasVideo: Bool, roomName: String?)

    /// Drop a pending incoming session if CallKit refused it.
    func cancelPendingIncomingCall(callID: UUID)
}

extension CallService {
    func prepareIncomingCall(callID: UUID, callerID: String, hasVideo: Bool, roomName: String?) {}
    func cancelPendingIncomingCall(callID: UUID) {}
}

@MainActor
protocol BusinessService {
    func listStorefronts() async throws -> [Storefront]
    func createStorefront(name: String, category: String, tagline: String?) async throws -> Storefront
    @discardableResult
    func save(storefront: Storefront) async throws -> Storefront
    func publish(storefrontID: UUID, isPublished: Bool) async throws
    func delete(storefrontID: UUID) async throws
}

@MainActor
protocol AIStorefrontService {
    func generate(from request: AIStorefrontRequest) async throws -> AIStorefrontResult
    func regenerateSection(storefront: Storefront, section: StorefrontSectionType) async throws -> StorefrontSection
    /// Improve an existing storefront draft/published record using a prompt.
    /// Implementations should be non-destructive by default (merge/append),
    /// unless the user explicitly requests a full overwrite.
    func improve(storefrontID: UUID, prompt: String) async throws -> AIStorefrontResult
}

extension AIStorefrontService {
    func improve(storefrontID: UUID, prompt: String) async throws -> AIStorefrontResult {
        throw NSError(
            domain: "AIStorefrontService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Improve is not supported by this AI service."]
        )
    }
}

protocol SystemHealthManager {
    func runStartupChecks() async -> [ServiceHealthStatus]
    func latestStatuses() -> [ServiceHealthStatus]
}

struct PlaintextMessage: Equatable {
    let id: UUID
    let chatID: UUID
    let senderID: UUID
    let body: String
    let attachment: MessageAttachment?
    let expiresAt: Date?
}

struct MessageContext: Equatable {
    let isGroup: Bool
    let communityID: UUID?
}

struct CryptoIdentity: Equatable {
    let fingerprint: String
}

struct GroupCryptoSession: Equatable {
    let groupID: UUID
    let epoch: Int
}

// MARK: - Business + Storefront

struct BusinessProfile: Identifiable, Equatable, Codable {
    let id: UUID
    let ownerID: UUID
    var name: String
    var category: String
    var tagline: String
    var description: String
    var logoURL: URL?
    var coverImageURL: URL?
    var contactEmail: String?
    var phone: String?
    var website: String?
    var socialLinks: [String: URL]
    var address: String?
    var hours: String?
    var products: [ProductOrService]
    var theme: StorefrontTheme
    var layout: StorefrontLayout
    var sections: [StorefrontSection]
    var isPublished: Bool
}

struct Storefront: Identifiable, Equatable, Codable {
    let id: UUID
    var business: BusinessProfile
    var sections: [StorefrontSection]
    var theme: StorefrontTheme
    var layout: StorefrontLayout
    var slug: String
    var isPublished: Bool
    var publishedState: StorefrontPublishedState
}

struct StorefrontTheme: Equatable, Codable {
    var primaryColorHex: String
    var accentColorHex: String
    var backgroundStyle: String
    var fontName: String
}

struct StorefrontLayout: Equatable, Codable {
    var heroStyle: String
    var gridStyle: String
    var spacing: Double
}

enum StorefrontSectionType: String, Codable, CaseIterable {
    case hero
    case about
    case products
    case services
    case featured
    case gallery
    case testimonials
    case hoursAndContact
    case cta
    case map
    case social
    case faq
    case richText
    case collections
}

struct StorefrontSection: Identifiable, Equatable, Codable {
    let id: UUID
    let type: StorefrontSectionType
    var title: String
    var body: String?
    var items: [ProductOrService]
    var mediaURLs: [URL]
    var ctaLabel: String?
    var ctaLink: URL?
    var layoutHint: String?

    init(
        id: UUID = UUID(),
        type: StorefrontSectionType,
        title: String,
        body: String? = nil,
        items: [ProductOrService] = [],
        mediaURLs: [URL] = [],
        ctaLabel: String? = nil,
        ctaLink: URL? = nil,
        layoutHint: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
        self.items = items
        self.mediaURLs = mediaURLs
        self.ctaLabel = ctaLabel
        self.ctaLink = ctaLink
        self.layoutHint = layoutHint
    }
}

struct ProductOrService: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var description: String
    var price: String
    var isSubscription: Bool
    var mediaURL: URL?

    init(id: UUID = UUID(), name: String, description: String, price: String, isSubscription: Bool = false, mediaURL: URL? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.price = price
        self.isSubscription = isSubscription
        self.mediaURL = mediaURL
    }
}

struct AIStorefrontRequest: Equatable, Codable {
    /// Freeform prompt text (ChatGPT-style). If missing when decoding older data, defaults to `businessName`.
    let prompt: String
    let businessName: String
    let category: String
    let tone: String
    let goals: [String]
    let preferredColors: [String]
    let includeSections: [StorefrontSectionType]

    init(prompt: String, businessName: String, category: String, tone: String, goals: [String], preferredColors: [String], includeSections: [StorefrontSectionType]) {
        self.prompt = prompt
        self.businessName = businessName
        self.category = category
        self.tone = tone
        self.goals = goals
        self.preferredColors = preferredColors
        self.includeSections = includeSections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        businessName = try c.decode(String.self, forKey: .businessName)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? businessName
        category = try c.decode(String.self, forKey: .category)
        tone = try c.decode(String.self, forKey: .tone)
        goals = try c.decode([String].self, forKey: .goals)
        preferredColors = try c.decode([String].self, forKey: .preferredColors)
        includeSections = try c.decode([StorefrontSectionType].self, forKey: .includeSections)
    }
}

struct AIStorefrontResult: Equatable, Codable {
    let storefront: Storefront
    let generatedCopy: [StorefrontSectionType: String]
}

// MARK: Storefront draft/publish + AI suggestions

struct StorefrontDraft: Identifiable, Equatable, Codable {
    let id: UUID
    var storefront: Storefront
    var lastEditedAt: Date
}

enum StorefrontPublishedState: String, Codable, Equatable {
    case draft
    case published
    case paused
}

struct AIStoreEditSuggestion: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let description: String
    let suggestedAt: Date
    let affectedSectionIDs: [UUID]
    let action: AIStoreAction
    let applied: Bool
}

enum AIStoreAction: String, Codable, Equatable {
    case generateStorefront
    case regenerateSection
    case rewriteCopy
    case promoteBanner
    case layoutSuggestion
    case themeChange
    case categorySuggestion
    case productCopy
    case servicePackage
    case seasonalCampaign
    case faq
    case ctaImprove
}

struct SellerStudioSection: Identifiable, Equatable {
    let id: UUID
    let title: String
    let type: StorefrontSectionType
}

struct StoreCollection: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var description: String
    var productIDs: [UUID]
    var isFeatured: Bool
}

struct Product: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var summary: String
    var price: String
    var images: [URL]
    var tags: [String]
    var isFeatured: Bool
    var collectionIDs: [UUID]
}

struct ServiceOffering: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var summary: String
    var price: String
    var durationMinutes: Int?
    var tags: [String]
}

struct ThemeConfig: Equatable, Codable {
    var primary: String
    var accent: String
    var background: String
    var typography: String
}

struct LayoutConfig: Equatable, Codable {
    var heroLayout: String
    var gridLayout: String
    var spacing: Double
    var showCollections: Bool
    var showServices: Bool
}

// MARK: - Status / Updates

enum StatusAudience: String, Codable, CaseIterable {
    case everyone
    case contactsOnly
    case excluded
}

struct StatusPost: Identifiable, Equatable, Codable {
    let id: UUID
    let authorID: UUID
    let media: MessageAttachment?
    let caption: String
    let createdAt: Date
    let expiresAt: Date
    let audience: StatusAudience
    let replyThreadID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case authorID
        case media
        case caption
        case createdAt
        case expiresAt
        case audience
        case replyThreadID
    }
}

// MARK: - Call history

struct CallHistoryItem: Identifiable, Equatable {
    let id: UUID
    let peerName: String
    let type: CallType
    let startedAt: Date
    let durationSeconds: Int
    let wasMissed: Bool
}

// MARK: - Business search

enum SearchResultKind: String, Codable {
    case product
    case storefront
    case category
    case collection
}

struct SearchResult: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let subtitle: String?
    let kind: SearchResultKind
    let storefront: Storefront?
    let product: ProductOrService?
    let category: String?
}

@MainActor
protocol BusinessSearchService {
    func search(query: String, mode: BusinessSearchMode) async throws -> [SearchResult]
}

enum BusinessSearchMode {
    case shop
    case manage
}
