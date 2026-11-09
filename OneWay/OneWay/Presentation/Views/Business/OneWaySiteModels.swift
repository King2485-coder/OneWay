import Foundation

struct OneWayBuilderSite: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var domain: SiteDomain
    var status: SitePublishStatus
    var lastEdited: Date
    var pages: [SitePage]
    var theme: SiteTheme
    var seoTitle: String
    var seoDescription: String
    var contactEmail: String
    var socialLinks: [String]
    var designSystem: SiteDesignSystem? = nil
    var qualityReport: SiteQualityReport? = nil
    var mobilePreviewImage: String? = nil
    var desktopPreviewImage: String? = nil
    var previewUpdatedAt: Date? = nil
    var mediaLibrary: [SiteMediaAsset]? = nil
    var publications: [SitePublicationRecord]? = nil
    var publicAddress: String? = nil
    var visibility: SiteVisibility? = nil
    var activePublicationID: UUID? = nil
    var draftVersion: Int? = nil
    var linkedShopSlug: String? = nil
    var linkedShopName: String? = nil
    var shopLinkEnabled: Bool? = nil

    var linkedShopURL: URL? {
        guard shopLinkEnabled == true, let slug = linkedShopSlug,
              slug.range(of: "^[a-zA-Z0-9-]{1,80}$", options: .regularExpression) != nil else { return nil }
        return APIConfig.storefrontPublicURL(for: slug)
    }

    var oneWaySlug: String {
        let preferred = publicAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? publicAddress ?? ""
            : domain.subdomain
        if preferred.lowercased().hasPrefix("oneway://site/") {
            return OneWayBuilderSite.normalizedSlug(String(preferred.dropFirst("oneway://site/".count)))
        }
        if preferred.lowercased().hasPrefix("oneway://") {
            return OneWayBuilderSite.normalizedSlug(String(preferred.dropFirst("oneway://".count)))
        }
        if preferred.lowercased().hasPrefix("https://sites.oneway.app/") {
            return OneWayBuilderSite.normalizedSlug(String(preferred.dropFirst("https://sites.oneway.app/".count)))
        }
        if preferred.lowercased().hasSuffix(".oneway.site") || preferred.lowercased().hasSuffix(".oneway.app") {
            return OneWayBuilderSite.normalizedSlug(preferred.components(separatedBy: ".").first ?? name)
        }
        return OneWayBuilderSite.normalizedSlug(name)
    }

    var oneWayPublicAddress: String {
        "oneway://site/\(oneWaySlug)"
    }

    var quantumPublicURL: URL {
        URL(string: "https://sites.oneway.app/\(oneWaySlug)")!
    }

    var customDomainDisplay: String? {
        let trimmed = domain.customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedSlug(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/")
            .first
            .map(String.init)?
            .replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")) ?? "site"
    }
}

struct SitePage: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var slug: String
    var sections: [SiteSection]
}

struct SiteSection: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var type: SiteSectionType
    var title: String
    var body: String
    var buttonTitle: String?
    var imageAssetIDs: [UUID]? = nil
    var videoAssetIDs: [UUID]? = nil
    var imagePresentation: SiteImagePresentation? = nil
    var components: [SiteComponent]? = nil
    var backgroundMedia: SiteSectionBackgroundMedia? = nil
}

struct SiteComponent: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var sectionID: UUID
    var assetID: UUID?
    var componentType: SiteComponentType
    var sortIndex: Int
    var widthMode: SiteComponentWidthMode = .large
    var customWidth: Double? = nil
    var heightMode: SiteComponentHeightMode = .auto
    var customHeight: Double? = nil
    var alignment: SiteComponentAlignment = .center
    var fitMode: SiteComponentFitMode = .fill
    var cropPosition: SiteComponentCropPosition = .center
    var focalPointX: Double = 0.5
    var focalPointY: Double = 0.5
    var cornerRadius: Double = 22
    var shadowEnabled: Bool = false
    var borderEnabled: Bool = false
    var overlayOpacity: Double = 0
    var opacity: Double = 1
    var spacingAbove: Double = 0
    var spacingBelow: Double = 14
    var caption: String = ""
    var altText: String = ""
    var link: String = ""
    var autoplay: Bool = false
    var muted: Bool = false
    var loop: Bool = false
    var showControls: Bool = true
    var role: SiteComponentRole = .content
    var responsiveSettings: SiteResponsiveMediaSettings = .default
}

enum SiteComponentType: String, CaseIterable, Codable, Hashable {
    case text
    case heading
    case button
    case image
    case video
    case gallery
    case spacer
    case divider
    case form
    case card
    case columns
    case heroMedia
}

enum SiteComponentWidthMode: String, CaseIterable, Identifiable, Codable, Hashable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    case full = "Full Width"
    case custom = "Custom"

    var id: String { rawValue }
}

enum SiteComponentHeightMode: String, CaseIterable, Identifiable, Codable, Hashable {
    case auto = "Auto"
    case short = "Short"
    case medium = "Medium"
    case tall = "Tall"
    case custom = "Custom"

    var id: String { rawValue }
}

enum SiteComponentAlignment: String, CaseIterable, Identifiable, Codable, Hashable {
    case left = "Left"
    case center = "Center"
    case right = "Right"
    case stretch = "Stretch"

    var id: String { rawValue }
}

enum SiteComponentFitMode: String, CaseIterable, Identifiable, Codable, Hashable {
    case fit = "Fit"
    case fill = "Fill"
    case crop = "Crop"

    var id: String { rawValue }
}

enum SiteComponentCropPosition: String, CaseIterable, Identifiable, Codable, Hashable {
    case topLeft = "Top Left"
    case topCenter = "Top Center"
    case topRight = "Top Right"
    case centerLeft = "Center Left"
    case center = "Center"
    case centerRight = "Center Right"
    case bottomLeft = "Bottom Left"
    case bottomCenter = "Bottom Center"
    case bottomRight = "Bottom Right"

    var id: String { rawValue }
}

enum SiteComponentRole: String, CaseIterable, Identifiable, Codable, Hashable {
    case content = "Content"
    case heroMedia = "Hero Media"
    case sectionBackground = "Section Background"
    case galleryItem = "Gallery Item"

    var id: String { rawValue }
}

struct SiteResponsiveMediaSettings: Codable, Equatable, Hashable {
    var mobileWidthMode: SiteComponentWidthMode? = nil
    var tabletWidthMode: SiteComponentWidthMode? = nil
    var desktopWidthMode: SiteComponentWidthMode? = nil
    var mobileHeightMode: SiteComponentHeightMode? = nil
    var tabletHeightMode: SiteComponentHeightMode? = nil
    var desktopHeightMode: SiteComponentHeightMode? = nil

    static let `default` = SiteResponsiveMediaSettings()
}

struct SiteSectionBackgroundMedia: Codable, Equatable, Hashable {
    var assetID: UUID
    var fitMode: SiteComponentFitMode = .fill
    var opacity: Double = 0.26
    var overlayOpacity: Double = 0.38
    var focalPointX: Double = 0.5
    var focalPointY: Double = 0.5
}

struct SiteMediaInsertionTarget: Codable, Equatable, Hashable {
    var siteId: UUID
    var pageId: UUID
    var sectionId: UUID
    var insertionIndex: Int
    var columnId: UUID? = nil
    var componentBeforeId: UUID? = nil
    var componentAfterId: UUID? = nil
    var defaultWidth: SiteComponentWidthMode = .large
    var defaultAlignment: SiteComponentAlignment = .center
}

struct SiteMediaAsset: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var siteID: UUID
    var mediaType: SiteMediaType = .image
    var originalFileName: String
    var mimeType: String
    var sourceMimeType: String? = nil
    var outputMimeType: String? = nil
    var width: Int?
    var height: Int?
    var durationMilliseconds: Int? = nil
    var fileSizeBytes: Int
    var uploadStatus: SiteMediaUploadStatus = .uploaded
    var processingStatus: SiteMediaProcessingStatus = .ready
    var publicStatus: SiteMediaPublicStatus = .privateAsset
    var failureCode: String? = nil
    var failureMessage: String? = nil
    var altText: String
    var caption: String
    var focalPointX: Double = 0.5
    var focalPointY: Double = 0.5
    var variants: [String: String]
    var usageCount: Int = 0
    var createdAt = Date()
    var updatedAt = Date()

    var previewURLString: String? {
        variants["thumbnail"] ?? variants["medium"] ?? variants["original"]
    }
}

enum SiteMediaType: String, CaseIterable, Codable, Hashable {
    case image = "IMAGE"
    case video = "VIDEO"
}

enum SiteMediaUploadStatus: String, Codable, Hashable {
    case uploading = "UPLOADING"
    case uploaded = "UPLOADED"
    case failed = "FAILED"
}

enum SiteMediaProcessingStatus: String, Codable, Hashable {
    case uploading = "UPLOADING"
    case processing = "PROCESSING"
    case ready = "READY"
    case failed = "FAILED"
    case deleted = "DELETED"
}

enum SiteMediaPublicStatus: String, Codable, Hashable {
    case privateAsset = "PRIVATE"
    case published = "PUBLISHED"
    case unpublished = "UNPUBLISHED"
}

struct SiteImagePresentation: Codable, Equatable, Hashable {
    var cropMode: SiteImageCropMode = .fill
    var aspectRatio: String = "16:9"
    var cornerRadius: Double = 24
    var opacity: Double = 1
    var alignment: String = "center"
    var width: Double? = nil
    var height: Double? = nil
    var overlayOpacity: Double = 0
    var decorative: Bool = false
}

enum SiteImageCropMode: String, CaseIterable, Codable, Hashable {
    case fit = "Fit"
    case fill = "Fill"
}

struct SitePublicationRecord: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var siteID: UUID
    var versionNumber: Int
    var status: String
    var publicAddress: String
    var publishedAt: Date
}

enum SiteVisibility: String, CaseIterable, Identifiable, Codable, Hashable {
    case `public` = "Public"
    case unlisted = "Unlisted"
    case `private` = "Private"

    var id: String { rawValue }
}

enum SiteSectionType: String, CaseIterable, Codable, Hashable {
    case hero = "Hero"
    case about = "About"
    case services = "Services"
    case productGrid = "Product Grid"
    case testimonials = "Testimonials"
    case gallery = "Gallery"
    case contactForm = "Contact Form"
    case faq = "FAQ"
    case pricing = "Pricing"
    case blogPreview = "Blog Preview"
    case booking = "Booking"
    case leadMagnet = "Lead Magnet"
    case team = "Team"
    case serviceArea = "Service Area"
    case process = "Process"
    case trustBadges = "Trust Badges"
    case cta = "Call To Action"
    case mapLocation = "Map / Location"
    case newsletter = "Newsletter"
    case footer = "Footer"
}

enum AISiteIndustry: String, CaseIterable, Codable, Hashable {
    case service = "Service Business"
    case trucking = "Trucking / Logistics"
    case restaurant = "Restaurant"
    case ecommerce = "Online Store"
    case creator = "Creator / Portfolio"
    case photography = "Photography"
    case realEstate = "Real Estate"
    case construction = "Construction"
    case technology = "Technology"
    case personalBrand = "Personal Brand"
    case nonprofit = "Nonprofit"
    case appointment = "Appointments"

    var recommendedPages: Set<String> {
        switch self {
        case .trucking:
            return ["Home", "About", "Services", "Fleet", "Service Areas", "Quote Request", "Contact", "Privacy Policy", "Terms"]
        case .restaurant:
            return ["Home", "Menu", "Reservations", "Catering", "Gallery", "Contact", "Privacy Policy", "Terms"]
        case .ecommerce:
            return ["Home", "Shop", "About", "FAQ", "Contact", "Privacy Policy", "Terms", "Returns"]
        case .creator:
            return ["Home", "Portfolio", "Services", "About", "Contact", "Privacy Policy", "Terms"]
        case .photography:
            return ["Home", "Portfolio", "Packages", "Booking", "About", "Contact", "Privacy Policy", "Terms"]
        case .realEstate:
            return ["Home", "Listings", "Neighborhoods", "Agent", "Contact", "Privacy Policy", "Terms"]
        case .construction:
            return ["Home", "Projects", "Services", "Service Areas", "Estimate Request", "Contact", "Privacy Policy", "Terms"]
        case .technology:
            return ["Home", "Platform", "Solutions", "Case Studies", "Contact", "Privacy Policy", "Terms"]
        case .personalBrand:
            return ["Home", "About", "Speaking", "Media", "Contact", "Privacy Policy", "Terms"]
        case .nonprofit:
            return ["Home", "Mission", "Programs", "Donate", "Volunteer", "Contact", "Privacy Policy", "Terms"]
        case .appointment:
            return ["Home", "Services", "Book Online", "About", "Reviews", "Contact", "Privacy Policy", "Terms"]
        case .service:
            return ["Home", "About", "Services", "Pricing", "FAQ", "Contact", "Privacy Policy", "Terms"]
        }
    }
}

struct SiteDesignSystem: Codable, Equatable, Hashable {
    var foundation: String
    var colorPalette: [String]
    var typographyPair: String
    var spacingScale: [Int]
    var buttonStyle: String
    var cardStyle: String
    var imageTreatment: String
    var sectionWidth: String
    var borderRadius: Int
    var shadow: String
    var animationRules: String
    var responsiveBreakpoints: [Int]
}

struct SiteQualityReport: Codable, Equatable, Hashable {
    var visualDesign: Int
    var content: Int
    var responsiveness: Int
    var accessibility: Int
    var performance: Int
    var seo: Int
    var completeness: Int
    var conversionReadiness: Int
    var criticalIssues: [String]

    var overallScore: Int {
        (visualDesign + content + responsiveness + accessibility + performance + seo + completeness + conversionReadiness) / 8
    }

    var isReady: Bool {
        overallScore >= 90 && criticalIssues.isEmpty
    }
}

struct AISiteInterviewQuestion: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var placeholder: String
}

struct SiteTheme: Codable, Equatable, Hashable {
    var primaryHex: String
    var accentHex: String
    var fontName: String
    var isDark: Bool
}

struct SiteDomain: Codable, Equatable, Hashable {
    var subdomain: String
    var customDomain: String
    var sslStatus: String
    var publishStatus: String
}

struct SiteSubmission: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var siteID: UUID
    var name: String
    var email: String
    var phone: String
    var message: String
    var date: Date
    var sourcePage: String
    var isRead: Bool
}

struct OneWaySiteTemplate: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var category: String
    var description: String
    var primaryHex: String
    var accentHex: String
}

enum SitePublishStatus: String, Codable, Hashable {
    case draft = "Draft"
    case publishing = "Publishing"
    case published = "Published"
    case publishFailed = "Publish Failed"
    case paused = "Paused"
    case unpublished = "Unpublished"
    case archived = "Archived"
    case `private` = "Private"
}

enum SitePreviewMode: String, CaseIterable, Identifiable {
    case mobile = "Mobile"
    case tablet = "Tablet"
    case desktop = "Desktop"

    var id: String { rawValue }
}
