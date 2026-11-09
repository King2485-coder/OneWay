import Foundation
import Combine

@MainActor
final class OneWaySitesViewModel: ObservableObject {
    @Published var sites: [OneWayBuilderSite] = []
    @Published var submissions: [SiteSubmission] = []
    @Published var publishChecklist: [String] = []
    @Published var publishWarnings: [String] = []
    @Published var publishMessage: String?
    @Published private(set) var accountContactEmail = ""

    func loadAccountContact() async {
        guard accountContactEmail.isEmpty else { return }
        if let identity = try? await OneWayIdentityService.shared.fetchMyIdentity() {
            accountContactEmail = identity.emailAlias.contains("@") ? identity.emailAlias : identity.emailAlias + "@oneway.app"
        }
    }

    private let sitesKey = "oneway.sites.localSites.v1"
    private let submissionsKey = "oneway.sites.localSubmissions.v1"
    private let backendSiteService: SiteService

    init(backendSiteService: SiteService = NetworkSiteService(client: .shared)) {
        self.backendSiteService = backendSiteService
        load()
    }

    func site(_ id: UUID) -> OneWayBuilderSite? {
        sites.first { $0.id == id }
    }

    func upsert(_ site: OneWayBuilderSite) {
        var next = site
        next.lastEdited = Date()
        next.draftVersion = (next.draftVersion ?? 1) + 1
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            sites[index] = next
        } else {
            sites.insert(next, at: 0)
        }
        save()
    }

    func generateSite(name: String, type: String, description: String, colors: String, contact: String, domainPreference: String, pages: Set<String>) -> OneWayBuilderSite {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New OneWay Site" : name
        let slug = Self.slug(for: cleanName)
        let industry = inferIndustry(from: "\(type) \(description) \(cleanName)")
        let palette = Self.palette(for: industry, requested: colors)
        let designSystem = Self.designSystem(for: industry, palette: palette)
        let theme = SiteTheme(primaryHex: palette.primary, accentHex: palette.accent, fontName: designSystem.typographyPair, isDark: false)
        let selectedPages = Array((pages.isEmpty ? industry.recommendedPages : pages).union(["Home", "Contact", "Privacy Policy", "Terms", "404"]))
            .sorted { lhs, rhs in pageSortRank(lhs) < pageSortRank(rhs) }
        let sections = homeSections(name: cleanName, industry: industry, description: description, contact: contact)
        let sitePages = selectedPages.map { page -> SitePage in
            SitePage(title: page, slug: Self.slug(for: page, separator: "-"), sections: page == "Home" ? sections : pageSections(page, name: cleanName, industry: industry, contact: contact))
        }
        var site = OneWayBuilderSite(
            name: cleanName,
            domain: SiteDomain(subdomain: "\(slug.isEmpty ? "site" : slug).oneway.site", customDomain: domainPreference, sslStatus: "SSL ready", publishStatus: "Draft"),
            status: .draft,
            lastEdited: Date(),
            pages: sitePages,
            theme: theme,
            seoTitle: seoTitle(name: cleanName, industry: industry),
            seoDescription: description.isEmpty ? seoDescription(name: cleanName, industry: industry) : description,
            contactEmail: contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? accountContactEmail : contact,
            socialLinks: []
        )
        site.designSystem = designSystem
        site.qualityReport = SiteQualityValidator.validate(site)
        site.previewUpdatedAt = Date()
        // TODO: Replace local generation with OneWay AI generation API, file/image storage, moderation, structured site block persistence, and WKWebView snapshot caching.
        upsert(site)
        return site
    }

    func generateSiteFromPrompt(_ prompt: String, answers: [String: String]) -> OneWayBuilderSite {
        let industry = inferIndustry(from: prompt + " " + answers.values.joined(separator: " "))
        let name = answers["Business name"]?.nilIfBlank
            ?? Self.nameGuess(from: prompt)
            ?? Self.defaultName(for: industry)
        let description = answers["What should customers know first?"]?.nilIfBlank
            ?? prompt
        let contact = answers["Best contact, phone, or email"]?.nilIfBlank ?? ""
        let color = answers["Brand colors or style"]?.nilIfBlank ?? ""
        let domain = answers["Preferred domain"]?.nilIfBlank ?? ""
        return generateSite(
            name: name,
            type: industry.rawValue,
            description: description,
            colors: color,
            contact: contact,
            domainPreference: domain,
            pages: industry.recommendedPages
        )
    }

    func interviewQuestions(for prompt: String) -> [AISiteInterviewQuestion] {
        let industry = inferIndustry(from: prompt)
        var questions = [
            AISiteInterviewQuestion(title: "Business name", placeholder: Self.defaultName(for: industry)),
            AISiteInterviewQuestion(title: "What should customers know first?", placeholder: "Tell customers what you do, who you help, and why they should trust you."),
            AISiteInterviewQuestion(title: "Best contact, phone, or email", placeholder: "dispatch@example.com, (555) 123-4567, or both"),
            AISiteInterviewQuestion(title: "Brand colors or style", placeholder: "Clean black and gold, blue and white, earthy green, etc."),
            AISiteInterviewQuestion(title: "Preferred domain", placeholder: "\(Self.slug(for: Self.defaultName(for: industry))).oneway.site")
        ]
        switch industry {
        case .trucking:
            questions.insert(.init(title: "Main services", placeholder: "Freight, hotshot, last mile, warehousing, dispatching"), at: 2)
            questions.insert(.init(title: "Service areas", placeholder: "Arizona, Texas, nationwide, local routes"), at: 3)
        case .restaurant:
            questions.insert(.init(title: "Food and ordering", placeholder: "Dine-in, pickup, catering, delivery, reservations"), at: 2)
        case .ecommerce:
            questions.insert(.init(title: "Products to feature", placeholder: "Best sellers, bundles, subscriptions, digital downloads"), at: 2)
        case .appointment:
            questions.insert(.init(title: "Booking rules", placeholder: "Free consultation, paid appointments, location, hours"), at: 2)
        case .nonprofit:
            questions.insert(.init(title: "Primary action", placeholder: "Donate, volunteer, attend an event, request help"), at: 2)
        case .creator:
            questions.insert(.init(title: "Portfolio focus", placeholder: "Photography, music, design, coaching, speaking"), at: 2)
        case .photography:
            questions.insert(.init(title: "Photography focus", placeholder: "Weddings, portraits, events, brands, editorial, family sessions"), at: 2)
        case .realEstate:
            questions.insert(.init(title: "Market focus", placeholder: "Buyers, sellers, luxury listings, rentals, neighborhoods"), at: 2)
        case .construction:
            questions.insert(.init(title: "Project types", placeholder: "Renovations, repairs, build-outs, residential, commercial"), at: 2)
        case .technology:
            questions.insert(.init(title: "Product or solution", placeholder: "SaaS, app, IT service, automation, consulting"), at: 2)
        case .personalBrand:
            questions.insert(.init(title: "Brand focus", placeholder: "Speaking, coaching, consulting, media, courses"), at: 2)
        case .service:
            questions.insert(.init(title: "Top services", placeholder: "List the 3-5 services customers ask for most"), at: 2)
        }
        return questions
    }

    func createFromTemplate(_ template: OneWaySiteTemplate) -> OneWayBuilderSite {
        generateSite(
            name: template.name,
            type: template.category,
            description: template.description,
            colors: template.primaryHex,
            contact: "",
            domainPreference: "",
            pages: ["Home", "About", "Services", "Contact", "Privacy Policy", "Terms"]
        )
    }

    func createBlank() -> OneWayBuilderSite {
        generateSite(name: "New Professional Site", type: "Business", description: "A polished website for a professional business with services, trust indicators, FAQs, and contact forms.", colors: "#111827", contact: "", domainPreference: "", pages: ["Home", "About", "Services", "FAQ", "Contact", "Privacy Policy", "Terms", "404"])
    }

    func publish(_ site: OneWayBuilderSite) -> Bool {
        let report = SiteQualityValidator.validate(site)
        publishChecklist = validationIssues(for: site) + imagePublishIssues(for: site) + report.criticalIssues
        publishWarnings = imageAccessibilityWarnings(for: site)
        guard publishChecklist.isEmpty else { return false }
        var next = site
        next.qualityReport = report
        next.status = .publishing
        next.domain.publishStatus = "Publishing"
        upsert(next)
        publishMessage = "Publishing \(site.name): saving draft and verifying Quantum access..."
        Task { await publishBackendAndActivate(next) }
        return true
    }

    func unpublish(_ site: OneWayBuilderSite) {
        var next = site
        next.status = .unpublished
        next.domain.publishStatus = "Unpublished"
        next.activePublicationID = nil
        next.mediaLibrary = (next.mediaLibrary ?? []).map { asset in
            var copy = asset
            copy.publicStatus = .unpublished
            return copy
        }
        upsert(next)
    }

    func pause(_ site: OneWayBuilderSite) {
        var next = site
        next.status = .paused
        next.domain.publishStatus = "Paused"
        upsert(next)
    }

    func restorePublication(_ publication: SitePublicationRecord, for site: OneWayBuilderSite) {
        var next = site
        let restored = SitePublicationRecord(siteID: site.id, versionNumber: ((site.publications ?? []).map(\.versionNumber).max() ?? 0) + 1, status: "ACTIVE", publicAddress: publication.publicAddress, publishedAt: Date())
        next.publications = [restored] + (site.publications ?? [])
        next.activePublicationID = restored.id
        next.publicAddress = restored.publicAddress
        next.status = .published
        next.domain.publishStatus = "Published"
        upsert(next)
    }

    func addMediaAsset(to site: OneWayBuilderSite, data: Data, fileName: String, mimeType: String, altText: String, caption: String = "", mediaType: SiteMediaType? = nil) -> SiteMediaAsset? {
        let resolvedType = mediaType ?? (isSupportedVideoMimeType(mimeType) ? .video : .image)
        let maxBytes = resolvedType == .video ? 250 * 1024 * 1024 : 12 * 1024 * 1024
        guard (resolvedType == .video ? isSupportedVideoMimeType(mimeType) : isSupportedImageMimeType(mimeType)), data.count <= maxBytes, !data.isEmpty else {
            publishMessage = resolvedType == .video
                ? "Video upload failed. Use MP4, MOV, or M4V under 250 MB."
                : "Image upload failed. Use JPEG, PNG, HEIC, WebP, or GIF under 12 MB."
            return nil
        }
        let encoded = data.base64EncodedString()
        let url = "data:\(mimeType);base64,\(encoded)"
        let asset = SiteMediaAsset(
            siteID: site.id,
            mediaType: resolvedType,
            originalFileName: fileName,
            mimeType: mimeType,
            sourceMimeType: mimeType,
            outputMimeType: resolvedType == .video ? "video/mp4" : mimeType,
            width: nil,
            height: nil,
            durationMilliseconds: nil,
            fileSizeBytes: data.count,
            uploadStatus: .uploaded,
            processingStatus: .ready,
            altText: altText,
            caption: caption,
            variants: resolvedType == .video
                ? ["original": url, "playback": url, "poster": url, "thumbnail": url]
                : ["original": url, "large": url, "medium": url, "small": url, "thumbnail": url]
        )
        var next = site
        var media = next.mediaLibrary ?? []
        media.insert(asset, at: 0)
        next.mediaLibrary = media
        publishMessage = resolvedType == .video ? "Video uploaded and saved to this Site media library." : "Image uploaded and saved to this Site media library."
        upsert(next)
        return asset
    }

    func saveUploadedMediaAsset(_ asset: SiteMediaAsset, to site: OneWayBuilderSite) -> OneWayBuilderSite {
        var next = site
        var media = next.mediaLibrary ?? []
        media.removeAll { $0.id == asset.id }
        media.insert(asset, at: 0)
        next.mediaLibrary = media
        publishMessage = asset.mediaType == .video ? "Video uploaded and saved to this Site media library." : "Image uploaded and saved to this Site media library."
        print("SITE_MEDIA_ASSET_CREATED siteId=\(site.id.uuidString) assetId=\(asset.id.uuidString) mediaType=\(asset.mediaType.rawValue) processingStatus=\(asset.processingStatus.rawValue) byteCount=\(asset.fileSizeBytes)")
        upsert(next)
        return next
    }

    func insertImage(_ asset: SiteMediaAsset, into site: OneWayBuilderSite, pageIndex: Int, sectionIndex: Int) -> OneWayBuilderSite {
        guard site.pages.indices.contains(pageIndex), site.pages[pageIndex].sections.indices.contains(sectionIndex) else { return site }
        let section = site.pages[pageIndex].sections[sectionIndex]
        let target = SiteMediaInsertionTarget(
            siteId: site.id,
            pageId: site.pages[pageIndex].id,
            sectionId: section.id,
            insertionIndex: section.components?.count ?? section.imageAssetIDs?.count ?? 0
        )
        return insertMediaComponent(asset, into: site, target: target)
    }

    func removeImage(_ assetID: UUID, from site: OneWayBuilderSite, pageIndex: Int, sectionIndex: Int) -> OneWayBuilderSite {
        var next = site
        guard next.pages.indices.contains(pageIndex), next.pages[pageIndex].sections.indices.contains(sectionIndex) else { return site }
        next.pages[pageIndex].sections[sectionIndex].imageAssetIDs = (next.pages[pageIndex].sections[sectionIndex].imageAssetIDs ?? []).filter { $0 != assetID }
        upsert(next)
        return next
    }

    func insertVideo(_ asset: SiteMediaAsset, into site: OneWayBuilderSite, pageIndex: Int, sectionIndex: Int) -> OneWayBuilderSite {
        guard site.pages.indices.contains(pageIndex), site.pages[pageIndex].sections.indices.contains(sectionIndex) else { return site }
        let section = site.pages[pageIndex].sections[sectionIndex]
        let target = SiteMediaInsertionTarget(
            siteId: site.id,
            pageId: site.pages[pageIndex].id,
            sectionId: section.id,
            insertionIndex: section.components?.count ?? section.videoAssetIDs?.count ?? 0
        )
        return insertMediaComponent(asset, into: site, target: target)
    }

    func removeVideo(_ assetID: UUID, from site: OneWayBuilderSite, pageIndex: Int, sectionIndex: Int) -> OneWayBuilderSite {
        var next = site
        guard next.pages.indices.contains(pageIndex), next.pages[pageIndex].sections.indices.contains(sectionIndex) else { return site }
        next.pages[pageIndex].sections[sectionIndex].videoAssetIDs = (next.pages[pageIndex].sections[sectionIndex].videoAssetIDs ?? []).filter { $0 != assetID }
        upsert(next)
        return next
    }

    func delete(_ site: OneWayBuilderSite) {
        sites.removeAll { $0.id == site.id }
        save()
    }

    func insertionTarget(for site: OneWayBuilderSite, pageIndex: Int, sectionIndex: Int, insertionIndex: Int? = nil) -> SiteMediaInsertionTarget? {
        guard site.pages.indices.contains(pageIndex),
              site.pages[pageIndex].sections.indices.contains(sectionIndex) else { return nil }
        let page = site.pages[pageIndex]
        let section = page.sections[sectionIndex]
        return SiteMediaInsertionTarget(
            siteId: site.id,
            pageId: page.id,
            sectionId: section.id,
            insertionIndex: insertionIndex ?? (section.components?.count ?? 0)
        )
    }

    func insertMediaComponent(_ asset: SiteMediaAsset, into site: OneWayBuilderSite, target: SiteMediaInsertionTarget) -> OneWayBuilderSite {
        var next = site
        guard let location = sectionLocation(in: next, pageID: target.pageId, sectionID: target.sectionId) else { return site }
        let pageIndex = location.pageIndex
        let sectionIndex = location.sectionIndex
        var components = normalizedComponents(for: next.pages[pageIndex].sections[sectionIndex])
        let insertIndex = min(max(target.insertionIndex, 0), components.count)
        let component = SiteComponent(
            sectionID: target.sectionId,
            assetID: asset.id,
            componentType: asset.mediaType == .video ? .video : (next.pages[pageIndex].sections[sectionIndex].type == .hero ? .heroMedia : .image),
            sortIndex: insertIndex,
            widthMode: target.defaultWidth,
            alignment: target.defaultAlignment,
            fitMode: .fill,
            caption: asset.caption,
            altText: asset.altText,
            muted: asset.mediaType == .video,
            showControls: asset.mediaType == .video
        )
        components.insert(component, at: insertIndex)
        next.pages[pageIndex].sections[sectionIndex].components = reindexed(components)
        syncLegacyMediaIDs(in: &next.pages[pageIndex].sections[sectionIndex], asset: asset)
        print("SITE_MEDIA_BLOCK_CREATED siteId=\(site.id.uuidString) pageId=\(target.pageId.uuidString) sectionId=\(target.sectionId.uuidString) assetId=\(asset.id.uuidString) componentId=\(component.id.uuidString) mediaType=\(asset.mediaType.rawValue) insertionIndex=\(insertIndex)")
        print("SITE_MEDIA_BLOCK_INSERTED siteId=\(site.id.uuidString) pageId=\(target.pageId.uuidString) sectionId=\(target.sectionId.uuidString) assetId=\(asset.id.uuidString) componentId=\(component.id.uuidString) mediaType=\(asset.mediaType.rawValue) insertionIndex=\(insertIndex)")
        autosave(next, reason: "media_inserted")
        return next
    }

    func updateComponent(_ component: SiteComponent, in site: OneWayBuilderSite) -> OneWayBuilderSite {
        var next = site
        guard let location = sectionLocation(in: next, sectionID: component.sectionID) else { return site }
        var components = normalizedComponents(for: next.pages[location.pageIndex].sections[location.sectionIndex])
        guard let index = components.firstIndex(where: { $0.id == component.id }) else { return site }
        components[index] = component
        next.pages[location.pageIndex].sections[location.sectionIndex].components = reindexed(components)
        print("SITE_MEDIA_DRAFT_SAVE_STARTED siteId=\(site.id.uuidString) sectionId=\(component.sectionID.uuidString) componentId=\(component.id.uuidString) reason=component_update")
        autosave(next, reason: "component_update")
        return next
    }

    func moveComponent(_ componentID: UUID, in site: OneWayBuilderSite, to target: SiteMediaInsertionTarget) -> OneWayBuilderSite {
        var next = site
        var moving: SiteComponent?
        for pageIndex in next.pages.indices {
            for sectionIndex in next.pages[pageIndex].sections.indices {
                var components = normalizedComponents(for: next.pages[pageIndex].sections[sectionIndex])
                if let index = components.firstIndex(where: { $0.id == componentID }) {
                    moving = components.remove(at: index)
                    next.pages[pageIndex].sections[sectionIndex].components = reindexed(components)
                    rebuildLegacyMediaIDs(in: &next.pages[pageIndex].sections[sectionIndex], site: next)
                    break
                }
            }
            if moving != nil { break }
        }
        guard var component = moving,
              let destination = sectionLocation(in: next, pageID: target.pageId, sectionID: target.sectionId) else { return site }
        component.sectionID = target.sectionId
        var destinationComponents = normalizedComponents(for: next.pages[destination.pageIndex].sections[destination.sectionIndex])
        let insertIndex = min(max(target.insertionIndex, 0), destinationComponents.count)
        destinationComponents.insert(component, at: insertIndex)
        next.pages[destination.pageIndex].sections[destination.sectionIndex].components = reindexed(destinationComponents)
        rebuildLegacyMediaIDs(in: &next.pages[destination.pageIndex].sections[destination.sectionIndex], site: next)
        print("SITE_MEDIA_COMPONENT_MOVED siteId=\(site.id.uuidString) componentId=\(componentID.uuidString) pageId=\(target.pageId.uuidString) sectionId=\(target.sectionId.uuidString) insertionIndex=\(insertIndex)")
        autosave(next, reason: "component_moved")
        return next
    }

    func duplicateComponent(_ componentID: UUID, in site: OneWayBuilderSite, to target: SiteMediaInsertionTarget? = nil) -> OneWayBuilderSite {
        var next = site
        guard let source = componentLocation(in: next, componentID: componentID) else { return site }
        let destinationTarget = target ?? SiteMediaInsertionTarget(
            siteId: site.id,
            pageId: next.pages[source.pageIndex].id,
            sectionId: next.pages[source.pageIndex].sections[source.sectionIndex].id,
            insertionIndex: source.component.sortIndex + 1
        )
        guard let destination = sectionLocation(in: next, pageID: destinationTarget.pageId, sectionID: destinationTarget.sectionId) else { return site }
        var duplicate = source.component
        duplicate.id = UUID()
        duplicate.sectionID = destinationTarget.sectionId
        var components = normalizedComponents(for: next.pages[destination.pageIndex].sections[destination.sectionIndex])
        let insertIndex = min(max(destinationTarget.insertionIndex, 0), components.count)
        components.insert(duplicate, at: insertIndex)
        next.pages[destination.pageIndex].sections[destination.sectionIndex].components = reindexed(components)
        rebuildLegacyMediaIDs(in: &next.pages[destination.pageIndex].sections[destination.sectionIndex], site: next)
        print("SITE_MEDIA_COMPONENT_DUPLICATED siteId=\(site.id.uuidString) sourceComponentId=\(componentID.uuidString) componentId=\(duplicate.id.uuidString) assetId=\(duplicate.assetID?.uuidString ?? "nil")")
        autosave(next, reason: "component_duplicated")
        return next
    }

    func deleteComponent(_ componentID: UUID, in site: OneWayBuilderSite) -> OneWayBuilderSite {
        var next = site
        for pageIndex in next.pages.indices {
            for sectionIndex in next.pages[pageIndex].sections.indices {
                var components = normalizedComponents(for: next.pages[pageIndex].sections[sectionIndex])
                if components.contains(where: { $0.id == componentID }) {
                    components.removeAll { $0.id == componentID }
                    next.pages[pageIndex].sections[sectionIndex].components = reindexed(components)
                    rebuildLegacyMediaIDs(in: &next.pages[pageIndex].sections[sectionIndex], site: next)
                    autosave(next, reason: "component_deleted")
                    return next
                }
            }
        }
        return site
    }

    func setSectionBackground(asset: SiteMediaAsset, in site: OneWayBuilderSite, pageIndex: Int, sectionIndex: Int) -> OneWayBuilderSite {
        var next = site
        guard next.pages.indices.contains(pageIndex), next.pages[pageIndex].sections.indices.contains(sectionIndex) else { return site }
        next.pages[pageIndex].sections[sectionIndex].backgroundMedia = SiteSectionBackgroundMedia(assetID: asset.id)
        print("SITE_SECTION_BACKGROUND_MEDIA_SET siteId=\(site.id.uuidString) sectionId=\(next.pages[pageIndex].sections[sectionIndex].id.uuidString) assetId=\(asset.id.uuidString)")
        autosave(next, reason: "section_background_media")
        return next
    }

    func components(in site: OneWayBuilderSite, pageIndex: Int, sectionIndex: Int) -> [SiteComponent] {
        guard site.pages.indices.contains(pageIndex), site.pages[pageIndex].sections.indices.contains(sectionIndex) else { return [] }
        return normalizedComponents(for: site.pages[pageIndex].sections[sectionIndex])
    }

    func submissions(for site: OneWayBuilderSite) -> [SiteSubmission] {
        submissions.filter { $0.siteID == site.id }
    }

    func validationIssues(for site: OneWayBuilderSite) -> [String] {
        var issues: [String] = []
        if site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Site name") }
        if site.pages.isEmpty { issues.append("At least one page") }
        if site.pages.first?.sections.isEmpty != false { issues.append("Home sections") }
        if site.seoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("SEO title") }
        if site.domain.subdomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("OneWay subdomain") }
        if site.status == .publishing { issues.append("Publishing is already in progress.") }
        let report = SiteQualityValidator.validate(site)
        if report.overallScore < 90 { issues.append("Quality score must be 90 or higher. Current score: \(report.overallScore).") }
        return issues
    }

    func imagePublishIssues(for site: OneWayBuilderSite) -> [String] {
        let media = site.mediaLibrary ?? []
        let ids = referencedAssetIDs(in: site)
        var issues: [String] = []
        for id in ids {
            guard let asset = media.first(where: { $0.id == id }) else {
                issues.append("A referenced media asset is missing from the Site media library.")
                continue
            }
            if asset.uploadStatus != .uploaded {
                issues.append("\(asset.originalFileName) has not finished uploading.")
            }
            if asset.processingStatus != .ready {
                issues.append("\(asset.originalFileName) is not ready yet.")
            }
            if asset.processingStatus == .failed || asset.uploadStatus == .failed {
                issues.append("\(asset.originalFileName) failed. Retry or remove it before publishing.")
            }
        }
        return issues
    }

    func imageAccessibilityWarnings(for site: OneWayBuilderSite) -> [String] {
        let media = site.mediaLibrary ?? []
        let ids = referencedAssetIDs(in: site)
        return media
            .filter { ids.contains($0.id) && $0.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.originalFileName) is missing alt text or a decorative designation." }
    }

    func mediaAssets(for site: OneWayBuilderSite) -> [SiteMediaAsset] {
        site.mediaLibrary ?? []
    }

    func asset(_ id: UUID, in site: OneWayBuilderSite) -> SiteMediaAsset? {
        (site.mediaLibrary ?? []).first { $0.id == id }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: sitesKey),
           let decoded = try? JSONDecoder().decode([OneWayBuilderSite].self, from: data) {
            sites = decoded
        }
        if let data = UserDefaults.standard.data(forKey: submissionsKey),
           let decoded = try? JSONDecoder().decode([SiteSubmission].self, from: data) {
            submissions = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sites) {
            UserDefaults.standard.set(data, forKey: sitesKey)
        }
        if let data = try? JSONEncoder().encode(submissions) {
            UserDefaults.standard.set(data, forKey: submissionsKey)
        }
    }

    private func autosave(_ site: OneWayBuilderSite, reason: String) {
        print("SITE_MEDIA_DRAFT_SAVE_STARTED siteId=\(site.id.uuidString) reason=\(reason)")
        upsert(site)
        print("SITE_MEDIA_DRAFT_SAVE_SUCCEEDED siteId=\(site.id.uuidString) reason=\(reason) draftVersion=\(site.draftVersion ?? 0)")
    }

    private func normalizedComponents(for section: SiteSection) -> [SiteComponent] {
        (section.components ?? [])
            .sorted { lhs, rhs in
                if lhs.sortIndex == rhs.sortIndex { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.sortIndex < rhs.sortIndex
            }
    }

    private func reindexed(_ components: [SiteComponent]) -> [SiteComponent] {
        components.enumerated().map { index, component in
            var copy = component
            copy.sortIndex = index
            return copy
        }
    }

    private func sectionLocation(in site: OneWayBuilderSite, pageID: UUID? = nil, sectionID: UUID) -> (pageIndex: Int, sectionIndex: Int)? {
        for pageIndex in site.pages.indices where pageID == nil || site.pages[pageIndex].id == pageID {
            if let sectionIndex = site.pages[pageIndex].sections.firstIndex(where: { $0.id == sectionID }) {
                return (pageIndex, sectionIndex)
            }
        }
        return nil
    }

    private func componentLocation(in site: OneWayBuilderSite, componentID: UUID) -> (pageIndex: Int, sectionIndex: Int, component: SiteComponent)? {
        for pageIndex in site.pages.indices {
            for sectionIndex in site.pages[pageIndex].sections.indices {
                if let component = normalizedComponents(for: site.pages[pageIndex].sections[sectionIndex]).first(where: { $0.id == componentID }) {
                    return (pageIndex, sectionIndex, component)
                }
            }
        }
        return nil
    }

    private func syncLegacyMediaIDs(in section: inout SiteSection, asset: SiteMediaAsset) {
        if asset.mediaType == .video {
            var ids = section.videoAssetIDs ?? []
            if !ids.contains(asset.id) { ids.append(asset.id) }
            section.videoAssetIDs = ids
        } else {
            var ids = section.imageAssetIDs ?? []
            if !ids.contains(asset.id) { ids.append(asset.id) }
            section.imageAssetIDs = ids
            section.imagePresentation = section.imagePresentation ?? SiteImagePresentation()
        }
    }

    private func publishBackendAndActivate(_ site: OneWayBuilderSite) async {
        let startedAt = Date()
        let slug = site.oneWaySlug
        print("SITE_PUBLISH_BUTTON_TAPPED siteId=\(site.id.uuidString) slug=\(slug) draftVersion=\(site.draftVersion ?? 1)")
        print("SITE_PUBLISH_CURRENT_STATE siteId=\(site.id.uuidString) slug=\(slug) localStatus=\(site.status.rawValue) backendHost=\(APIConfig.baseURL)")
        do {
            print("SITE_PUBLISH_DRAFT_SAVE_REQUESTED siteId=\(site.id.uuidString) slug=\(slug)")
            let draft = SiteDraft(
                domainSlug: slug,
                title: site.name,
                description: site.seoDescription.isEmpty ? site.pages.first?.sections.first?.body ?? site.name : site.seoDescription,
                mode: .nocode,
                htmlContent: "",
                blocks: backendBlocks(for: site),
                aiPrompt: "Published from OneWay Sites"
            )
            let saved = try await backendSiteService.upsert(site: draft)
            print("SITE_PUBLISH_DRAFT_SAVE_SUCCEEDED siteId=\(saved.id.uuidString) slug=\(slug) draftVersion=\(site.draftVersion ?? 1)")
            print("SITE_PUBLISH_REQUEST_SENT siteId=\(saved.id.uuidString) slug=\(slug)")
            let published = try await backendSiteService.publish(site: saved)
            print("SITE_PUBLIC_ROUTE_VERIFICATION_SUCCEEDED siteId=\(published.id.uuidString) slug=\(slug) duration=\(Date().timeIntervalSince(startedAt))")

            guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
            var next = sites[index]
            let publication = SitePublicationRecord(
                siteID: next.id,
                versionNumber: ((next.publications ?? []).map(\.versionNumber).max() ?? 0) + 1,
                status: "ACTIVE",
                publicAddress: "oneway://\(slug)",
                publishedAt: Date()
            )
            next.publications = [publication] + (next.publications ?? [])
            next.activePublicationID = publication.id
            next.publicAddress = publication.publicAddress
            next.visibility = next.visibility ?? .public
            next.status = .published
            next.domain.publishStatus = "Published"
            next.domain.sslStatus = "Active and secured"
            next.mediaLibrary = (next.mediaLibrary ?? []).map { asset in
                var copy = asset
                if referencedAssetIDs(in: next).contains(copy.id) {
                    copy.publicStatus = .published
                    copy.usageCount += 1
                }
                return copy
            }
            sites[index] = next
            save()
            publishMessage = "Your Site is live and verified in Quantum."
            print("SITE_PUBLISH_LOCAL_STATE_UPDATED siteId=\(published.id.uuidString) slug=\(slug) localSiteId=\(site.id.uuidString)")
            print("SITE_PUBLISH_COMPLETED siteId=\(published.id.uuidString) slug=\(slug) duration=\(Date().timeIntervalSince(startedAt))")
        } catch {
            guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
            var failed = sites[index]
            failed.status = .publishFailed
            failed.domain.publishStatus = "Publish Failed"
            sites[index] = failed
            save()
            publishMessage = "Your Site was saved, but its public version could not be activated: \(error.localizedDescription)"
            print("SITE_PUBLISH_FAILED siteId=\(site.id.uuidString) slug=\(slug) failureStage=backend_publish failureCode=\(error.localizedDescription)")
        }
    }

    private func backendBlocks(for site: OneWayBuilderSite) -> [SiteBlock] {
        var blocks: [SiteBlock] = []
        for section in site.pages.flatMap(\.sections) {
            switch section.type {
            case .hero:
                blocks.append(.hero(eyebrow: site.domain.subdomain, title: section.title, subtitle: section.body))
                if let button = section.buttonTitle, !button.isEmpty {
                    blocks.append(.button(label: button, url: "#contact"))
                }
            case .services, .productGrid:
                blocks.append(.services(title: section.title, items: [
                    SiteServiceItem(title: section.title, detail: section.body)
                ]))
                if let button = section.buttonTitle, !button.isEmpty {
                    blocks.append(.button(label: button, url: "#contact"))
                }
            case .contactForm:
                blocks.append(.contact(name: site.name, email: site.contactEmail, phone: ""))
            case .faq:
                blocks.append(.faq(title: section.title, items: [
                    SiteFAQItem(question: section.title, answer: section.body)
                ]))
            case .footer:
                blocks.append(.text(text: "\(section.title)\n\(section.body)"))
            default:
                blocks.append(.heading(level: 2, text: section.title))
                blocks.append(.paragraph(text: section.body))
                if let button = section.buttonTitle, !button.isEmpty {
                    blocks.append(.button(label: button, url: "#contact"))
                }
            }
        }
        if !site.contactEmail.isEmpty && !blocks.contains(where: { block in
            if case .contact = block { return true }
            return false
        }) {
            blocks.append(.contact(name: site.name, email: site.contactEmail, phone: ""))
        }
        if let shopURL = site.linkedShopURL {
            blocks.append(.button(label: "Visit " + (site.linkedShopName ?? "our shop"), url: shopURL.absoluteString))
        }
        return blocks.isEmpty ? [.hero(eyebrow: site.domain.subdomain, title: site.name, subtitle: site.seoDescription)] : blocks
    }

    private func rebuildLegacyMediaIDs(in section: inout SiteSection, site: OneWayBuilderSite) {
        let media = site.mediaLibrary ?? []
        let components = normalizedComponents(for: section)
        section.imageAssetIDs = components.compactMap { component in
            guard let id = component.assetID, media.first(where: { $0.id == id })?.mediaType == .image else { return nil }
            return id
        }
        section.videoAssetIDs = components.compactMap { component in
            guard let id = component.assetID, media.first(where: { $0.id == id })?.mediaType == .video else { return nil }
            return id
        }
    }

    private static func sampleSite() -> OneWayBuilderSite {
        OneWayBuilderSite(
            name: "King Logistics",
            domain: .init(subdomain: "kinglogistics.oneway.site", customDomain: "kinglogistics.com", sslStatus: "Active and secured", publishStatus: "Published"),
            status: .published,
            lastEdited: Date().addingTimeInterval(-7200),
            pages: [
                .init(title: "Home", slug: "home", sections: [
                    .init(type: .hero, title: "Delivering Freight Across the Country", body: "Reliable logistics solutions. On time. Every time.", buttonTitle: "Get a Quote"),
                    .init(type: .services, title: "Our Services", body: "Freight shipping, warehousing, and supply chain support.", buttonTitle: "Our Services"),
                    .init(type: .contactForm, title: "Request a Quote", body: "Tell us what you need moved.", buttonTitle: "Send Request"),
                    .init(type: .footer, title: "King Logistics", body: "Privacy Policy • Terms • Support", buttonTitle: nil)
                ])
            ],
            theme: .init(primaryHex: "#111827", accentHex: "#7B3FF2", fontName: "Inter", isDark: false),
            seoTitle: "King Logistics | Freight Across the Country",
            seoDescription: "Reliable logistics solutions across the country.",
            contactEmail: "dispatch@kinglogistics.com",
            socialLinks: []
        )
    }

    static var previewSite: OneWayBuilderSite {
        sampleSite()
    }

    private func inferIndustry(from text: String) -> AISiteIndustry {
        let raw = text.lowercased()
        if raw.contains("truck") || raw.contains("freight") || raw.contains("logistics") || raw.contains("dispatch") || raw.contains("delivery") { return .trucking }
        if raw.contains("restaurant") || raw.contains("food") || raw.contains("menu") || raw.contains("catering") || raw.contains("reservation") { return .restaurant }
        if raw.contains("photo") || raw.contains("photography") || raw.contains("wedding") || raw.contains("portrait") || raw.contains("gallery") { return .photography }
        if raw.contains("real estate") || raw.contains("property") || raw.contains("listing") || raw.contains("realtor") { return .realEstate }
        if raw.contains("construction") || raw.contains("contractor") || raw.contains("renovation") || raw.contains("estimate") { return .construction }
        if raw.contains("software") || raw.contains("saas") || raw.contains("technology") || raw.contains("platform") { return .technology }
        if raw.contains("speaker") || raw.contains("coach") || raw.contains("personal brand") || raw.contains("consultant") { return .personalBrand }
        if raw.contains("shop") || raw.contains("store") || raw.contains("product") || raw.contains("commerce") || raw.contains("merch") { return .ecommerce }
        if raw.contains("nonprofit") || raw.contains("donate") || raw.contains("volunteer") || raw.contains("charity") { return .nonprofit }
        if raw.contains("portfolio") || raw.contains("creator") || raw.contains("artist") || raw.contains("photography") { return .creator }
        if raw.contains("appointment") || raw.contains("booking") || raw.contains("salon") || raw.contains("clinic") || raw.contains("consult") { return .appointment }
        return .service
    }

    private func homeSections(name: String, industry: AISiteIndustry, description: String, contact: String) -> [SiteSection] {
        let body = description.isEmpty ? seoDescription(name: name, industry: industry) : description
        switch industry {
        case .trucking:
            return [
                .init(type: .hero, title: "\(name) moves freight with speed and care", body: body, buttonTitle: "Request a Quote"),
                .init(type: .about, title: "Logistics built around clear communication", body: "\(name) helps customers plan freight, coordinate timing, and keep shipments moving with practical updates at every step.", buttonTitle: nil),
                .init(type: .trustBadges, title: "Built for dependable shipping", body: "Licensed dispatch, clear communication, fast quotes, insured carrier partners, and shipment updates from pickup to delivery.", buttonTitle: nil),
                .init(type: .services, title: "Freight services", body: "Full truckload, hotshot, regional delivery, warehousing support, last-mile logistics, and dedicated lanes.", buttonTitle: "View Services"),
                .init(type: .serviceArea, title: "Service areas", body: "Local, regional, and nationwide routes with flexible scheduling for urgent and recurring shipments.", buttonTitle: nil),
                .init(type: .process, title: "How shipping works", body: "Tell us the load, get a fast quote, confirm dispatch, track the route, and receive proof of delivery.", buttonTitle: nil),
                .init(type: .testimonials, title: "Trusted for time-sensitive freight", body: "Customers choose \(name) for responsive planning, honest timelines, and clear handoffs from quote to delivery.", buttonTitle: nil),
                .init(type: .faq, title: "Freight questions", body: "Answer common questions about shipment details, timing, service areas, cargo requirements, and quote turnaround.", buttonTitle: nil),
                .init(type: .contactForm, title: "Request a freight quote", body: contact.isEmpty ? "Send pickup, drop-off, cargo, date, and contact details." : contact, buttonTitle: "Send Quote Request"),
                .init(type: .footer, title: name, body: "Privacy Policy • Terms • Support", buttonTitle: nil)
            ]
        case .restaurant:
            return [
                .init(type: .hero, title: "\(name) serves fresh food made for gathering", body: body, buttonTitle: "View Menu"),
                .init(type: .about, title: "A warm place to eat well", body: "\(name) presents fresh dishes, clear ordering options, hours, location details, and simple ways to reserve or request catering.", buttonTitle: nil),
                .init(type: .productGrid, title: "Featured favorites", body: "Signature plates, family bundles, drinks, desserts, and seasonal specials.", buttonTitle: "Order Now"),
                .init(type: .trustBadges, title: "Easy plans for every meal", body: "Menu highlights, hours, pickup details, catering options, and reservation requests are easy to find on every device.", buttonTitle: nil),
                .init(type: .booking, title: "Reserve or cater", body: "Book a table, request catering, or plan a private event with our team.", buttonTitle: "Make a Reservation"),
                .init(type: .gallery, title: "Inside the kitchen", body: "Fresh ingredients, warm service, and a space made for good meals.", buttonTitle: nil),
                .init(type: .testimonials, title: "Local favorites", body: "Feature reviews that speak to the food, service, atmosphere, and reliable catering experience.", buttonTitle: nil),
                .init(type: .faq, title: "Hours, ordering, and events", body: "Answer questions about reservations, pickup, catering timelines, dietary notes, and location details.", buttonTitle: nil),
                .init(type: .contactForm, title: "Ask about catering", body: contact.isEmpty ? "Tell us your date, guest count, and event details." : contact, buttonTitle: "Send Request"),
                .init(type: .footer, title: name, body: "Menu • Catering • Reservations • Contact", buttonTitle: nil)
            ]
        case .ecommerce:
            return [
                .init(type: .hero, title: "\(name) brings the shop online", body: body, buttonTitle: "Shop Now"),
                .init(type: .about, title: "A store built for confident buying", body: "\(name) organizes products, benefits, support, returns, and secure checkout details into a clean shopping experience.", buttonTitle: nil),
                .init(type: .productGrid, title: "Featured products", body: "Best sellers, new arrivals, bundles, and limited drops.", buttonTitle: "Browse Products"),
                .init(type: .trustBadges, title: "Easy checkout", body: "Secure payments, order updates, returns, inventory tracking, and customer support.", buttonTitle: nil),
                .init(type: .testimonials, title: "Customers come back", body: "Highlight product quality, shipping experience, helpful support, and repeat purchase moments.", buttonTitle: nil),
                .init(type: .faq, title: "Shopping questions", body: "Cover shipping, returns, sizing, order tracking, payment security, and product care.", buttonTitle: nil),
                .init(type: .newsletter, title: "Get launch drops first", body: "Collect emails for restocks, sales, and new releases.", buttonTitle: "Join List"),
                .init(type: .footer, title: name, body: "Shop • Returns • Privacy • Support", buttonTitle: nil)
            ]
        case .photography:
            return [
                .init(type: .hero, title: "\(name) creates image-led stories with care", body: body, buttonTitle: "View Portfolio"),
                .init(type: .gallery, title: "Featured work", body: "A cinematic portfolio section for portraits, events, weddings, brand shoots, and editorial sessions.", buttonTitle: nil),
                .init(type: .about, title: "Calm direction, polished results", body: "\(name) helps clients feel prepared before the shoot and confident when the final gallery arrives.", buttonTitle: nil),
                .init(type: .pricing, title: "Packages", body: "Session options, editing details, delivery timelines, and booking next steps are presented clearly.", buttonTitle: "View Packages"),
                .init(type: .testimonials, title: "Client words", body: "Use concise client feedback about direction, comfort, turnaround, and final image quality.", buttonTitle: nil),
                .init(type: .trustBadges, title: "Professional delivery", body: "Private galleries, edited selections, clear usage rights, and secure contact forms.", buttonTitle: nil),
                .init(type: .faq, title: "Before you book", body: "Explain shoot length, location planning, editing timelines, galleries, and rescheduling.", buttonTitle: nil),
                .init(type: .booking, title: "Book a session", body: contact.isEmpty ? "Share the date, location, session type, and contact details." : contact, buttonTitle: "Request Booking"),
                .init(type: .footer, title: name, body: "Portfolio • Packages • Booking • Contact", buttonTitle: nil)
            ]
        case .realEstate:
            return [
                .init(type: .hero, title: "\(name) helps clients move with confidence", body: body, buttonTitle: "View Listings"),
                .init(type: .productGrid, title: "Featured listings", body: "Spotlight available properties, neighborhoods, price ranges, and buyer or seller next steps.", buttonTitle: "Explore Properties"),
                .init(type: .about, title: "Local guidance with clear next steps", body: "\(name) presents market guidance, property preparation, showings, offers, and closing support in plain language.", buttonTitle: nil),
                .init(type: .serviceArea, title: "Neighborhood focus", body: "Show key neighborhoods, commute notes, lifestyle highlights, and market context.", buttonTitle: nil),
                .init(type: .testimonials, title: "Client confidence", body: "Feature real estate feedback around responsiveness, clarity, preparation, and negotiation support.", buttonTitle: nil),
                .init(type: .trustBadges, title: "Built for buyers and sellers", body: "Listing alerts, consultation forms, valuation requests, and neighborhood resources.", buttonTitle: nil),
                .init(type: .faq, title: "Buying and selling questions", body: "Answer financing, showings, valuation, offer, inspection, and timeline questions.", buttonTitle: nil),
                .init(type: .contactForm, title: "Request a consultation", body: contact.isEmpty ? "Tell us what you are buying, selling, or researching." : contact, buttonTitle: "Send Request"),
                .init(type: .footer, title: name, body: "Listings • Neighborhoods • Contact • Privacy", buttonTitle: nil)
            ]
        case .construction:
            return [
                .init(type: .hero, title: "\(name) builds with precision and practical planning", body: body, buttonTitle: "Request Estimate"),
                .init(type: .gallery, title: "Project gallery", body: "Show finished work, before-and-after transformations, materials, and job site details.", buttonTitle: nil),
                .init(type: .services, title: "Construction services", body: "Renovations, repairs, build-outs, project planning, service areas, and estimate requests.", buttonTitle: "View Services"),
                .init(type: .trustBadges, title: "Professional project standards", body: "Clear scopes, scheduling, site communication, safety practices, and documented estimates.", buttonTitle: nil),
                .init(type: .process, title: "From estimate to completion", body: "Consult, scope, schedule, build, review, and complete with clear updates.", buttonTitle: nil),
                .init(type: .testimonials, title: "Built on trust", body: "Highlight feedback about communication, craftsmanship, punctuality, and cleanup.", buttonTitle: nil),
                .init(type: .faq, title: "Project questions", body: "Explain estimates, timelines, deposits, materials, permits, and service areas.", buttonTitle: nil),
                .init(type: .contactForm, title: "Request an estimate", body: contact.isEmpty ? "Share project type, location, timeline, and contact details." : contact, buttonTitle: "Send Estimate Request"),
                .init(type: .footer, title: name, body: "Projects • Services • Estimates • Contact", buttonTitle: nil)
            ]
        case .nonprofit:
            return [
                .init(type: .hero, title: "\(name) turns support into action", body: body, buttonTitle: "Donate"),
                .init(type: .about, title: "Our mission", body: "A clear mission section for the people, place, and problem your work serves.", buttonTitle: nil),
                .init(type: .trustBadges, title: "Transparent community work", body: "Give visitors clear ways to donate, volunteer, partner, attend events, and understand impact.", buttonTitle: nil),
                .init(type: .services, title: "Programs", body: "Community programs, resources, events, volunteer opportunities, and impact reports.", buttonTitle: "Explore Programs"),
                .init(type: .cta, title: "Help today", body: "Invite donors, volunteers, partners, and families to take the next step.", buttonTitle: "Get Involved"),
                .init(type: .testimonials, title: "Community impact", body: "Share participant, volunteer, or partner stories without inventing unsupported results.", buttonTitle: nil),
                .init(type: .faq, title: "How to help", body: "Explain donations, volunteering, program access, partnerships, and event participation.", buttonTitle: nil),
                .init(type: .contactForm, title: "Contact the team", body: contact.isEmpty ? "Reach out for partnerships, support, or volunteer questions." : contact, buttonTitle: "Send Message"),
                .init(type: .footer, title: name, body: "Donate • Volunteer • Impact • Contact", buttonTitle: nil)
            ]
        default:
            return [
                .init(type: .hero, title: "\(name) is ready for your next customer", body: body, buttonTitle: industry == .appointment ? "Book Now" : "Get Started"),
                .init(type: .about, title: "About \(name)", body: "Explain your story, promise, credentials, and why customers choose you.", buttonTitle: nil),
                .init(type: .trustBadges, title: "Why customers choose \(name)", body: "Clear communication, focused service, simple next steps, and a website designed around conversion.", buttonTitle: nil),
                .init(type: .services, title: "Services", body: "Highlight your most profitable services with simple descriptions and clear calls to action.", buttonTitle: "View Services"),
                .init(type: industry == .appointment ? .booking : .pricing, title: industry == .appointment ? "Online booking" : "Simple options", body: "Make it easy for visitors to choose a package, request a quote, or schedule a consultation.", buttonTitle: industry == .appointment ? "Book Appointment" : "Request Pricing"),
                .init(type: .testimonials, title: "Customers trust \(name)", body: "Show reviews, proof, guarantees, and results that make visitors comfortable taking action.", buttonTitle: nil),
                .init(type: .faq, title: "Common questions", body: "Answer the practical questions visitors ask before contacting a business like \(name).", buttonTitle: nil),
                .init(type: .contactForm, title: "Contact us", body: contact.isEmpty ? "Send a message and the team will respond quickly." : contact, buttonTitle: "Send Message"),
                .init(type: .footer, title: name, body: "Privacy Policy • Terms • Support", buttonTitle: nil)
            ]
        }
    }

    private func pageSections(_ page: String, name: String, industry: AISiteIndustry, contact: String) -> [SiteSection] {
        let lower = page.lowercased()
        let type: SiteSectionType
        if lower.contains("contact") || lower.contains("quote") { type = .contactForm }
        else if lower.contains("book") || lower.contains("reservation") { type = .booking }
        else if lower.contains("shop") || lower.contains("product") || lower.contains("menu") { type = .productGrid }
        else if lower.contains("area") || lower.contains("fleet") { type = .serviceArea }
        else if lower.contains("faq") { type = .faq }
        else if lower.contains("privacy") || lower.contains("terms") || lower == "404" { type = .about }
        else { type = .services }
        return [
            .init(type: .hero, title: page, body: pageBody(page, name: name, industry: industry), buttonTitle: lower.contains("contact") ? "Contact Us" : nil),
            .init(type: type, title: page, body: contact.isEmpty ? pageDetail(page, name: name, industry: industry) : contact, buttonTitle: lower.contains("contact") || lower.contains("quote") ? "Send Request" : nil),
            .init(type: .footer, title: name, body: "Privacy Policy • Terms • Support", buttonTitle: nil)
        ]
    }

    private func pageBody(_ page: String, name: String, industry: AISiteIndustry) -> String {
        if page == "404" { return "This page is not available, but visitors can return home or contact \(name) for help." }
        return "\(page) details for \(name), organized for a polished \(industry.rawValue.lowercased()) website with clear next steps."
    }

    private func pageDetail(_ page: String, name: String, industry: AISiteIndustry) -> String {
        if page == "404" { return "Offer a clear route back to the home page, services, contact form, or support details." }
        return "A complete \(page.lowercased()) page with concise content, helpful calls to action, and structure that matches \(name)'s \(industry.rawValue.lowercased()) audience."
    }

    private func seoTitle(name: String, industry: AISiteIndustry) -> String {
        switch industry {
        case .trucking: return "\(name) | Freight, Logistics & Delivery"
        case .restaurant: return "\(name) | Menu, Catering & Reservations"
        case .ecommerce: return "\(name) | Shop Online"
        case .photography: return "\(name) | Photography Portfolio & Booking"
        case .realEstate: return "\(name) | Listings, Neighborhoods & Real Estate Guidance"
        case .construction: return "\(name) | Construction Services & Estimates"
        case .technology: return "\(name) | Technology Solutions"
        case .personalBrand: return "\(name) | Speaking, Media & Consulting"
        case .nonprofit: return "\(name) | Donate, Volunteer & Community Impact"
        case .creator: return "\(name) | Portfolio & Creative Services"
        case .appointment: return "\(name) | Book Online"
        case .service: return "\(name) | Professional Services"
        }
    }

    private func seoDescription(name: String, industry: AISiteIndustry) -> String {
        switch industry {
        case .trucking: return "Request fast freight quotes, logistics support, dispatch updates, and dependable delivery from \(name)."
        case .restaurant: return "Explore the menu, catering, reservations, and fresh favorites from \(name)."
        case .ecommerce: return "Shop products, bundles, and new arrivals from \(name) with secure checkout."
        case .photography: return "Explore \(name)'s photography portfolio, packages, booking options, client notes, and contact details."
        case .realEstate: return "Browse property guidance, featured listings, neighborhoods, consultations, and market support from \(name)."
        case .construction: return "Request estimates, review construction services, project galleries, and service areas from \(name)."
        case .technology: return "Explore technology solutions, platform benefits, implementation steps, and contact options from \(name)."
        case .personalBrand: return "Learn about \(name), speaking, media, consulting, resources, and ways to connect."
        case .nonprofit: return "Support \(name)'s mission through donations, volunteering, programs, and community action."
        case .creator: return "View portfolio work, services, projects, and booking details for \(name)."
        case .appointment: return "Book services, consultations, and appointments online with \(name)."
        case .service: return "Discover services, pricing, reviews, and contact options from \(name)."
        }
    }

    private func pageSortRank(_ page: String) -> Int {
        ["Home", "About", "Services", "Fleet", "Projects", "Portfolio", "Listings", "Neighborhoods", "Service Areas", "Products", "Shop", "Menu", "Reservations", "Book Online", "Pricing", "Packages", "FAQ", "Blog", "Quote Request", "Estimate Request", "Contact", "Privacy Policy", "Terms", "Returns", "404"].firstIndex(of: page) ?? 100
    }

    private static func slug(for value: String, separator: String = "") -> String {
        value.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : ($0 == " " ? separator : "") }
            .joined()
            .replacingOccurrences(of: "\(separator)\(separator)", with: separator)
            .trimmingCharacters(in: CharacterSet(charactersIn: separator))
    }

    private static func palette(for industry: AISiteIndustry, requested: String) -> (primary: String, accent: String) {
        let clean = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#"), clean.count == 7 { return (clean, "#7B3FF2") }
        switch industry {
        case .trucking: return ("#111827", "#F59E0B")
        case .restaurant: return ("#7C2D12", "#EF4444")
        case .ecommerce: return ("#0F172A", "#22C55E")
        case .creator: return ("#1E1B4B", "#EC4899")
        case .photography: return ("#18181B", "#D4A373")
        case .realEstate: return ("#0F172A", "#C8A45D")
        case .construction: return ("#1F2937", "#F97316")
        case .technology: return ("#0B1020", "#38BDF8")
        case .personalBrand: return ("#312E81", "#F472B6")
        case .nonprofit: return ("#064E3B", "#38BDF8")
        case .appointment: return ("#0F766E", "#8B5CF6")
        case .service: return ("#111827", "#7B3FF2")
        }
    }

    private static func defaultName(for industry: AISiteIndustry) -> String {
        switch industry {
        case .trucking: return "OneWay Logistics"
        case .restaurant: return "OneWay Kitchen"
        case .ecommerce: return "OneWay Shop"
        case .creator: return "OneWay Studio"
        case .photography: return "OneWay Photo"
        case .realEstate: return "OneWay Realty"
        case .construction: return "OneWay Builds"
        case .technology: return "OneWay Technology"
        case .personalBrand: return "OneWay Brand"
        case .nonprofit: return "OneWay Foundation"
        case .appointment: return "OneWay Booking"
        case .service: return "OneWay Services"
        }
    }

    private static func nameGuess(from prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = trimmed.split(separator: " ").prefix(4).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func designSystem(for industry: AISiteIndustry, palette: (primary: String, accent: String)) -> SiteDesignSystem {
        let foundation: String
        let typography: String
        let imageTreatment: String
        switch industry {
        case .trucking:
            foundation = "Logistics"
            typography = "Inter / Sora"
            imageTreatment = "Wide fleet imagery, high-contrast overlays, route-map accents"
        case .restaurant:
            foundation = "Restaurant"
            typography = "Fraunces / Inter"
            imageTreatment = "Warm food photography, editorial crops, soft table-light shadows"
        case .photography:
            foundation = "Editorial Portfolio"
            typography = "Playfair Display / Inter"
            imageTreatment = "Full-bleed cinematic galleries with generous whitespace"
        case .ecommerce:
            foundation = "Premium Store"
            typography = "Inter / Manrope"
            imageTreatment = "Clean product cards, lifestyle imagery, consistent aspect ratios"
        case .realEstate:
            foundation = "Luxury Service"
            typography = "Canela / Inter"
            imageTreatment = "Large property imagery, neighborhood cards, refined overlays"
        case .construction:
            foundation = "Local Service"
            typography = "Sora / Inter"
            imageTreatment = "Project galleries, before-after crops, sturdy card framing"
        case .technology:
            foundation = "Modern Business"
            typography = "Inter / IBM Plex Sans"
            imageTreatment = "Product screens, abstract system diagrams, crisp gradients"
        case .nonprofit:
            foundation = "High-Conversion Landing Page"
            typography = "Inter / Source Serif"
            imageTreatment = "Community imagery, impact cards, human-centered spacing"
        case .personalBrand, .creator, .appointment, .service:
            foundation = "Modern Business"
            typography = "Inter / Sora"
            imageTreatment = "Professional lifestyle imagery with clean content cards"
        }
        return SiteDesignSystem(
            foundation: foundation,
            colorPalette: [palette.primary, palette.accent, "#FFFFFF", "#F8FAFC", "#111827"],
            typographyPair: typography,
            spacingScale: [8, 12, 16, 24, 40, 64],
            buttonStyle: "High-contrast rounded pills with clear primary and secondary actions",
            cardStyle: "White cards, subtle border, soft shadow, 18-24 radius",
            imageTreatment: imageTreatment,
            sectionWidth: "1120px desktop, 720px tablet, fluid mobile with 20px gutters",
            borderRadius: 22,
            shadow: "0 18 50 rgba(15, 23, 42, 0.12)",
            animationRules: "Subtle fade and lift, no layout shift",
            responsiveBreakpoints: [320, 375, 430, 768, 1024, 1440, 1920]
        )
    }

    private func referencedAssetIDs(in site: OneWayBuilderSite) -> Set<UUID> {
        Set(site.pages.flatMap { page in
            page.sections.flatMap { section in
                (section.imageAssetIDs ?? []) + (section.videoAssetIDs ?? [])
            }
        })
    }

    private func isSupportedImageMimeType(_ mimeType: String) -> Bool {
        ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "image/gif"].contains(mimeType.lowercased())
    }

    private func isSupportedVideoMimeType(_ mimeType: String) -> Bool {
        ["video/mp4", "video/quicktime", "video/x-m4v"].contains(mimeType.lowercased())
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
