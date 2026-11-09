import Foundation

enum OneWayCapabilityStatus: String, Codable, CaseIterable {
    case live
    case beta
    case planned
    case needsProvider

    var label: String {
        switch self {
        case .live: return "Live"
        case .beta: return "Beta"
        case .planned: return "Planned"
        case .needsProvider: return "Provider"
        }
    }
}

struct OneWayPlatformCapability: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let group: String
    let title: String
    let summary: String
    let status: OneWayCapabilityStatus
    let privacyLevel: String
    let routeHint: String?
}

struct OneWayPlatformCapabilityGroup: Identifiable, Codable, Equatable, Hashable {
    var id: String { title }
    let title: String
    let icon: String
    let promise: String
    let capabilities: [OneWayPlatformCapability]

    var completedCount: Int {
        capabilities.filter { $0.status == .live || $0.status == .beta }.count
    }

    var totalCount: Int {
        capabilities.count
    }
}

struct OneWayPlatformReadiness: Codable, Equatable {
    let updatedAt: Date
    let headline: String
    let summary: String
    let groups: [OneWayPlatformCapabilityGroup]

    var completedCount: Int {
        groups.reduce(0) { $0 + $1.completedCount }
    }

    var totalCount: Int {
        groups.reduce(0) { $0 + $1.totalCount }
    }

    var readinessRatio: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}

struct PlatformPrivacySettings: Codable, Equatable {
    var endToEndEncryptionEnabled: Bool
    var chatLockEnabled: Bool
    var hideOnlineStatus: Bool
    var hideLastSeen: Bool
    var hideReadReceipts: Bool
    var hideTypingIndicators: Bool
    var hidePhoneNumber: Bool
    var disappearingMessageTimer: String

    static let defaults = PlatformPrivacySettings(
        endToEndEncryptionEnabled: true,
        chatLockEnabled: false,
        hideOnlineStatus: false,
        hideLastSeen: true,
        hideReadReceipts: false,
        hideTypingIndicators: false,
        hidePhoneNumber: true,
        disappearingMessageTimer: "Off"
    )
}

struct PlatformAILogEntry: Identifiable, Codable, Equatable {
    let id: String
    let action: String
    let contentScope: String
    let requiresDecryptedContent: Bool
    let createdAt: String
}

struct PlatformCloudFile: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let mimeType: String?
    let byteCount: Int
    let storageKey: String
    let encrypted: Bool
    let createdAt: String
    let updatedAt: String
}

struct PlatformWorkspaceItem: Identifiable, Codable, Equatable {
    let id: String
    let workspaceId: String
    let type: String
    let title: String
    let status: String
    let metadataJson: String?
    let createdAt: String
    let updatedAt: String
}

struct PlatformChannelPost: Identifiable, Codable, Equatable {
    let id: String
    let channelId: String
    let authorId: String
    let body: String
    let reactionCount: Int
    let createdAt: String
    let updatedAt: String
}

struct PlatformScheduledMessage: Identifiable, Codable, Equatable {
    let id: String
    let conversationId: String
    let senderId: String
    let body: String
    let scheduledFor: String
    let status: String
    let createdAt: String
}

extension OneWayPlatformReadiness {
    static let localFallback = OneWayPlatformReadiness(
        updatedAt: Date(),
        headline: "OneWay does WhatsApp, plus private business infrastructure.",
        summary: "Messaging, calls, Chirp, Sites, Shops, AI, storage, and privacy controls are tracked as one connected platform so unfinished capabilities have clear owners instead of becoming hidden gaps.",
        groups: [
            .init(
                title: "Messaging",
                icon: "bubble.left.and.bubble.right.fill",
                promise: "Private chats with modern collaboration controls.",
                capabilities: [
                    .init(id: "messages.direct", group: "Messaging", title: "One-on-one chats", summary: "Direct messaging through the existing messages service.", status: .live, privacyLevel: "E2EE planned", routeHint: "Chats"),
                    .init(id: "messages.groups", group: "Messaging", title: "Group chats", summary: "Shared conversations, replies, mentions, reactions, and receipts.", status: .beta, privacyLevel: "Encrypted metadata-minimized", routeHint: "Communities"),
                    .init(id: "messages.channels", group: "Messaging", title: "Channels and broadcasts", summary: "One-to-many posting, follower controls, and broadcast lists.", status: .planned, privacyLevel: "Sender controlled", routeHint: "Communities"),
                    .init(id: "messages.rich", group: "Messaging", title: "Rich messages", summary: "Editing, delete for everyone, forwarding, stars, pins, drafts, polls, events, link previews, voice notes, documents, and location.", status: .beta, privacyLevel: "Local-first drafts", routeHint: "Chats")
                ]
            ),
            .init(
                title: "Voice and Video",
                icon: "phone.connection.fill",
                promise: "LiveKit, PSTN, voicemail, and Chirp in one calling layer.",
                capabilities: [
                    .init(id: "calls.oneway", group: "Voice and Video", title: "HD voice and video", summary: "OneWay-to-OneWay calling through LiveKit with CallKit handoff.", status: .live, privacyLevel: "Call metadata protected", routeHint: "Calls"),
                    .init(id: "calls.pstn", group: "Voice and Video", title: "PSTN and SIP", summary: "Phone-network calling with provider preflight and SIP bridge support.", status: .beta, privacyLevel: "Number privacy supported", routeHint: "Calls"),
                    .init(id: "calls.walkie", group: "Voice and Video", title: "Chirp", summary: "Push-to-talk mode with channels, activity, and privacy indicators.", status: .live, privacyLevel: "Private channels", routeHint: "Chirp"),
                    .init(id: "calls.ai", group: "Voice and Video", title: "Call intelligence", summary: "Captions, transcription, summaries, and meeting notes behind AI permissions.", status: .planned, privacyLevel: "Explicit AI consent", routeHint: "AI")
                ]
            ),
            .init(
                title: "Privacy and Identity",
                icon: "lock.shield.fill",
                promise: "Privacy-first defaults with user-owned identity.",
                capabilities: [
                    .init(id: "privacy.defaults", group: "Privacy and Identity", title: "Privacy controls", summary: "Hide phone number, usernames, read receipts, typing indicators, online status, and profile visibility.", status: .live, privacyLevel: "User controlled", routeHint: "Privacy"),
                    .init(id: "privacy.lock", group: "Privacy and Identity", title: "Chat Lock and devices", summary: "Face ID/PIN unlock, linked devices, session management, and hidden chats.", status: .beta, privacyLevel: "Device protected", routeHint: "Settings"),
                    .init(id: "privacy.safety", group: "Privacy and Identity", title: "Safety actions", summary: "Block, report, spam detection, audit logs, and security verification.", status: .live, privacyLevel: "Auditable", routeHint: "Safety")
                ]
            ),
            .init(
                title: "Business, Sites, and Shops",
                icon: "briefcase.fill",
                promise: "The WhatsApp business surface plus real storefronts and websites.",
                capabilities: [
                    .init(id: "business.inbox", group: "Business, Sites, and Shops", title: "Business inbox", summary: "Quick replies, greeting/away messages, customer notes, labels, roles, and AI support.", status: .planned, privacyLevel: "Team scoped", routeHint: "Business"),
                    .init(id: "sites.builder", group: "Business, Sites, and Shops", title: "OneWay Sites", summary: "AI builder, templates, editor, domains, analytics, forms, and publish checks.", status: .beta, privacyLevel: "Private pages supported", routeHint: "Sites"),
                    .init(id: "shops.marketplace", group: "Business, Sites, and Shops", title: "Shops marketplace", summary: "Buyer-facing marketplace, shop management, products, orders, carts, favorites, and payments abstraction.", status: .beta, privacyLevel: "Private by default", routeHint: "Business")
                ]
            ),
            .init(
                title: "Cloud, AI, and Workspace",
                icon: "sparkles",
                promise: "A private productivity layer that WhatsApp does not offer.",
                capabilities: [
                    .init(id: "cloud.vault", group: "Cloud, AI, and Workspace", title: "Encrypted OneWay Cloud", summary: "Files, photos, shared folders, family/business vaults, secure links, and storage usage.", status: .planned, privacyLevel: "Encrypted storage", routeHint: "Storage"),
                    .init(id: "ai.layer", group: "Cloud, AI, and Workspace", title: "OneWay AI", summary: "Summaries, suggested replies, translation, transcription, writing, image help, and cross-OneWay search.", status: .planned, privacyLevel: "Explicit decrypted-content warning", routeHint: "AI"),
                    .init(id: "workspace.team", group: "Cloud, AI, and Workspace", title: "Workspace", summary: "Team chat, tasks, projects, calendar, notes, whiteboard placeholder, roles, and activity feed.", status: .planned, privacyLevel: "Role based", routeHint: "Workspace")
                ]
            )
        ]
    )
}
