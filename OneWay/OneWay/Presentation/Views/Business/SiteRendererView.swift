import SwiftUI
import AVKit
import UIKit

struct SiteRendererView: View {
    let site: OneWayBuilderSite
    var mode: SitePreviewMode = .desktop
    @State private var selectedPageID: UUID?
    private var currentPage: SitePage? { site.pages.first { $0.id == selectedPageID } ?? site.pages.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                nav
                ForEach(currentPage?.sections ?? []) { section in
                    sectionView(section)
                }
                if let shopURL = site.linkedShopURL {
                    Button("Visit " + (site.linkedShopName ?? "our shop")) {
                        NotificationCenter.default.post(name: Notification.Name("OneWayQuantumURLRequested"), object: shopURL)
                    }.font(.headline.bold()).padding(24).foregroundStyle(accent)
                }
            }
            .background(site.theme.isDark ? Color(hex: 0x111827) : .white)
            .clipShape(RoundedRectangle(cornerRadius: mode == .desktop ? 10 : 22, style: .continuous))
        }
        .frame(maxWidth: maxWidth)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: mode == .desktop ? 10 : 22, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 8)
    }

    private var maxWidth: CGFloat? {
        switch mode {
        case .mobile: return 360
        case .tablet: return 720
        case .desktop: return nil
        }
    }

    private var accent: Color {
        Color(hexString: site.theme.accentHex) ?? Color(hex: 0x7B3FF2)
    }

    private var textColor: Color {
        site.theme.isDark ? .white : Color(hex: 0x111827)
    }

    private var nav: some View {
        HStack {
            Text(site.name)
                .font(.headline.weight(.black))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if mode == .mobile {
                Menu {
                    ForEach(site.pages) { page in Button(page.title) { selectedPageID = page.id } }
                } label: {
                    OneWayResolvedIcon(systemName: "line.3.horizontal").font(.headline.weight(.black)).foregroundStyle(textColor.opacity(0.72))
                }
            } else {
                HStack(spacing: 16) {
                    ForEach(site.pages.prefix(5)) { page in
                        Button(page.title) { selectedPageID = page.id }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(textColor.opacity(0.72))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .padding(.horizontal, mode == .mobile ? 18 : 34)
        .padding(.vertical, 18)
        .background(site.theme.isDark ? Color.black.opacity(0.24) : Color.white)
    }

    @ViewBuilder
    private func sectionView(_ section: SiteSection) -> some View {
        switch section.type {
        case .hero:
            HStack(spacing: mode == .mobile ? 0 : 32) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(section.title)
                        .font(.system(size: mode == .mobile ? 34 : 58, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(mode == .mobile ? 4 : 3)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(section.body)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                    sectionPlacedComponents(section)
                    sectionImages(section)
                    sectionVideos(section)
                    HStack(spacing: 10) {
                        if let button = section.buttonTitle {
                            Text(button)
                                .font(.headline.weight(.black))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(accent, in: Capsule())
                        }
                        Text("Learn More")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if mode != .mobile {
                    imagePanel(section)
                        .frame(maxWidth: 360)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(mode == .mobile ? 24 : 58)
            .background(
                LinearGradient(colors: [Color(hex: 0x111827), accent.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        case .services, .productGrid, .pricing, .process, .serviceArea:
            VStack(alignment: .leading, spacing: 18) {
                Text(section.title).font(.title.weight(.black)).foregroundStyle(textColor)
                sectionPlacedComponents(section)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: mode == .mobile ? 120 : 180), spacing: 14)], spacing: 14) {
                    ForEach(items(for: section), id: \.self) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            OneWayResolvedIcon(systemName: icon(for: section.type)).foregroundStyle(accent)
                            Text(item).font(.headline.weight(.black)).foregroundStyle(textColor)
                            Text(section.body).font(.caption).foregroundStyle(textColor.opacity(0.62))
                                .lineLimit(4)
                        }
                        .padding(16)
                        .background((site.theme.isDark ? Color.white.opacity(0.08) : Color(hex: 0xF4F4F5)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .padding(mode == .mobile ? 22 : 42)
        case .about:
            HStack(alignment: .center, spacing: 26) {
                if mode != .mobile {
                    imagePanel(section)
                        .frame(maxWidth: 320)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.title)
                        .font(.title.weight(.black))
                        .foregroundStyle(textColor)
                    Text(section.body)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(textColor.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                    sectionPlacedComponents(section)
                    HStack(spacing: 8) {
                        pill("Responsive")
                        pill("SEO Ready")
                        pill("Fast")
                    }
                }
            }
            .padding(mode == .mobile ? 22 : 42)
        case .gallery:
            VStack(alignment: .leading, spacing: 18) {
                Text(section.title).font(.title.weight(.black)).foregroundStyle(textColor)
                Text(section.body).font(.subheadline.weight(.semibold)).foregroundStyle(textColor.opacity(0.64))
                sectionPlacedComponents(section)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    let media = assets(for: section)
                    if media.isEmpty {
                        ForEach(0..<6, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 18)
                                .fill(LinearGradient(colors: [accent.opacity(0.18), Color(hex: 0x111827).opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .aspectRatio(index == 0 ? 1.3 : 1.0, contentMode: .fit)
                        }
                    } else {
                        ForEach(media) { asset in
                            SiteRenderedMedia(
                                asset: asset,
                                cornerRadius: section.imagePresentation?.cornerRadius ?? 18,
                                opacity: section.imagePresentation?.opacity ?? 1,
                                fill: section.imagePresentation?.cropMode != .fit
                            )
                            .aspectRatio(1.08, contentMode: .fit)
                            .accessibilityLabel(asset.altText.isEmpty ? asset.originalFileName : asset.altText)
                        }
                    }
                }
            }
            .padding(mode == .mobile ? 22 : 42)
        case .testimonials:
            VStack(alignment: .leading, spacing: 16) {
                Text(section.title).font(.title.weight(.black)).foregroundStyle(textColor)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: mode == .mobile ? 190 : 240), spacing: 14)], spacing: 14) {
                    ForEach(["Clear communication", "Professional results", "Easy next steps"], id: \.self) { headline in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 3) {
                                ForEach(0..<5, id: \.self) { _ in OneWayResolvedIcon(systemName: "star.fill").font(.caption2).foregroundStyle(accent) }
                            }
                            Text(headline)
                                .font(.headline.weight(.black))
                                .foregroundStyle(textColor)
                            Text(section.body)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(textColor.opacity(0.64))
                                .lineLimit(4)
                        }
                        .padding(16)
                        .background((site.theme.isDark ? Color.white.opacity(0.08) : Color(hex: 0xF8FAFC)), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
            .padding(mode == .mobile ? 22 : 42)
        case .faq:
            VStack(alignment: .leading, spacing: 14) {
                Text(section.title).font(.title.weight(.black)).foregroundStyle(textColor)
                ForEach(["What is the next step?", "How fast can we get started?", "How do visitors contact us?"], id: \.self) { question in
                    HStack(alignment: .top, spacing: 12) {
                        OneWayResolvedIcon(systemName: "plus.circle.fill")
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(question)
                                .font(.headline.weight(.black))
                                .foregroundStyle(textColor)
                            Text(section.body)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(textColor.opacity(0.64))
                                .lineLimit(3)
                        }
                    }
                    .padding(14)
                    .background((site.theme.isDark ? Color.white.opacity(0.08) : Color(hex: 0xF8FAFC)), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(mode == .mobile ? 22 : 42)
        case .trustBadges:
            HStack(alignment: .top, spacing: 12) {
                ForEach(["Verified", "Fast", "Secure"], id: \.self) { item in
                    VStack(spacing: 8) {
                        OneWayResolvedIcon(systemName: item == "Secure" ? "lock.shield.fill" : "checkmark.seal.fill")
                            .font(.title2.weight(.black))
                            .foregroundStyle(accent)
                        Text(item)
                            .font(.headline.weight(.black))
                            .foregroundStyle(textColor)
                        Text(section.body)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(textColor.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background((site.theme.isDark ? Color.white.opacity(0.08) : Color(hex: 0xF8FAFC)), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(mode == .mobile ? 22 : 42)
        case .booking, .contactForm, .leadMagnet, .newsletter:
            VStack(alignment: .leading, spacing: 14) {
                Text(section.title).font(.title2.weight(.black)).foregroundStyle(textColor)
                Text(section.body).font(.subheadline.weight(.semibold)).foregroundStyle(textColor.opacity(0.68))
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(textColor.opacity(0.09)).frame(height: 42)
                    RoundedRectangle(cornerRadius: 8).fill(textColor.opacity(0.09)).frame(height: 42)
                    RoundedRectangle(cornerRadius: 8).fill(textColor.opacity(0.09)).frame(height: 72)
                    if let button = section.buttonTitle {
                        Text(button)
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
                .background((site.theme.isDark ? Color.white.opacity(0.08) : Color.white), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(textColor.opacity(0.12), lineWidth: 1))
            }
            .padding(mode == .mobile ? 22 : 42)
            .background(site.theme.isDark ? Color.black.opacity(0.16) : Color(hex: 0xF8FAFC))
        case .cta:
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.title.weight(.black))
                        .foregroundStyle(.white)
                    Text(section.body)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
                Spacer()
                if let button = section.buttonTitle {
                    Text(button)
                        .font(.headline.weight(.black))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.white, in: Capsule())
                }
            }
            .padding(mode == .mobile ? 22 : 42)
            .background(accent)
        case .footer:
            VStack(spacing: 8) {
                Text(section.title).font(.headline.weight(.black))
                Text(section.body).font(.caption.weight(.semibold))
                sectionPlacedComponents(section)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(28)
            .background(Color(hex: 0x111827))
        default:
            VStack(alignment: .leading, spacing: 10) {
                Text(section.title).font(.title2.weight(.black)).foregroundStyle(textColor)
                Text(section.body).foregroundStyle(textColor.opacity(0.7))
                sectionPlacedComponents(section)
                if let button = section.buttonTitle {
                    Text(button).font(.subheadline.weight(.black)).foregroundStyle(accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(mode == .mobile ? 22 : 42)
        }
    }

    private func items(for section: SiteSection) -> [String] {
        switch section.type {
        case .productGrid: return ["Featured", "Best Sellers", "New Arrivals"]
        case .pricing: return ["Starter", "Professional", "Custom"]
        case .process: return ["Request", "Confirm", "Deliver"]
        case .serviceArea: return ["Local", "Regional", "Nationwide"]
        default: return ["Core Service", "Fast Support", "Custom Solution"]
        }
    }

    private func icon(for type: SiteSectionType) -> String {
        switch type {
        case .productGrid: return "bag.fill"
        case .pricing: return "tag.fill"
        case .process: return "arrow.triangle.2.circlepath"
        case .serviceArea: return "map.fill"
        default: return "shippingbox.fill"
        }
    }

    private func imagePanel(_ section: SiteSection) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let asset = assets(for: section).first {
                SiteRenderedMedia(
                    asset: asset,
                    cornerRadius: section.imagePresentation?.cornerRadius ?? 28,
                    opacity: section.imagePresentation?.opacity ?? 1,
                    fill: section.imagePresentation?.cropMode != .fit
                )
                LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.46)], startPoint: .top, endPoint: .bottom)
            } else {
                RoundedRectangle(cornerRadius: 28)
                    .fill(LinearGradient(colors: [accent.opacity(0.2), Color(hex: 0x111827).opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            VStack(alignment: .leading, spacing: 8) {
                OneWayResolvedIcon(systemName: visualIcon(for: section))
                    .font(.system(size: 48, weight: .black))
                    .foregroundStyle(.white)
                Text(section.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(22)
        }
        .aspectRatio(1.15, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    @ViewBuilder
    private func sectionImages(_ section: SiteSection) -> some View {
        let componentIds = Set(placedComponents(for: section).compactMap(\.assetID))
        let media = assets(for: section).filter { !componentIds.contains($0.id) }
        if !media.isEmpty && mode == .mobile {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(media.prefix(4)) { asset in
                        SiteRenderedMedia(
                            asset: asset,
                            cornerRadius: section.imagePresentation?.cornerRadius ?? 18,
                            opacity: section.imagePresentation?.opacity ?? 1,
                            fill: section.imagePresentation?.cropMode != .fit
                        )
                        .frame(width: 156, height: 104)
                        .accessibilityLabel(asset.altText.isEmpty ? asset.originalFileName : asset.altText)
                    }
                }
            }
        }
    }

    private func assets(for section: SiteSection) -> [SiteMediaAsset] {
        let componentImageIds = placedComponents(for: section)
            .filter { $0.componentType == .image || $0.componentType == .heroMedia }
            .compactMap(\.assetID)
        let ids = componentImageIds.isEmpty ? (section.imageAssetIDs ?? []) : componentImageIds
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in
            site.mediaLibrary?.first { $0.id == id && $0.processingStatus == .ready }
        }
    }

    @ViewBuilder
    private func sectionVideos(_ section: SiteSection) -> some View {
        let componentIds = Set(placedComponents(for: section).compactMap(\.assetID))
        let media = videoAssets(for: section).filter { !componentIds.contains($0.id) }
        if !media.isEmpty {
            VStack(spacing: 10) {
                ForEach(media.prefix(mode == .mobile ? 1 : 2)) { asset in
                    SiteRenderedVideo(asset: asset)
                        .frame(height: mode == .mobile ? 190 : 260)
                        .accessibilityLabel(asset.altText.isEmpty ? asset.originalFileName : asset.altText)
                }
            }
        }
    }

    private func videoAssets(for section: SiteSection) -> [SiteMediaAsset] {
        let componentVideoIds = placedComponents(for: section)
            .filter { $0.componentType == .video }
            .compactMap(\.assetID)
        let ids = componentVideoIds.isEmpty ? (section.videoAssetIDs ?? []) : componentVideoIds
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in
            site.mediaLibrary?.first { $0.id == id && $0.mediaType == .video && $0.processingStatus == .ready }
        }
    }

    private func visualIcon(for section: SiteSection) -> String {
        let title = "\(site.name) \(section.title) \(section.body)".lowercased()
        if title.contains("freight") || title.contains("logistics") { return "box.truck.fill" }
        if title.contains("food") || title.contains("menu") || title.contains("restaurant") { return "fork.knife" }
        if title.contains("photo") || title.contains("portfolio") { return "camera.fill" }
        if title.contains("property") || title.contains("real estate") { return "house.fill" }
        if title.contains("construction") || title.contains("project") { return "hammer.fill" }
        if title.contains("shop") || title.contains("product") { return "bag.fill" }
        return "sparkles"
    }

    private func pill(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.black))
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(accent.opacity(0.12), in: Capsule())
    }

    private func placedComponents(for section: SiteSection) -> [SiteComponent] {
        (section.components ?? [])
            .filter { $0.assetID != nil }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    @ViewBuilder
    private func sectionPlacedComponents(_ section: SiteSection) -> some View {
        let components = placedComponents(for: section)
        if !components.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(components) { component in
                    if let assetID = component.assetID,
                       let asset = site.mediaLibrary?.first(where: { $0.id == assetID && $0.processingStatus == .ready }) {
                        renderedComponent(component, asset: asset)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func renderedComponent(_ component: SiteComponent, asset: SiteMediaAsset) -> some View {
        let width = componentWidth(component)
        let height = componentHeight(component)
        let isVideo = asset.mediaType == .video || component.componentType == .video
        Group {
            if isVideo {
                SiteRenderedVideo(asset: asset, component: component)
            } else {
                SiteRenderedMedia(
                    asset: asset,
                    cornerRadius: component.cornerRadius,
                    opacity: component.opacity,
                    fill: component.fitMode != .fit
                )
            }
        }
        .frame(maxWidth: component.alignment == .stretch || component.widthMode == .full ? .infinity : width)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: alignment(for: component.alignment))
        .padding(.top, component.spacingAbove)
        .padding(.bottom, component.spacingBelow)
        .shadow(color: component.shadowEnabled ? .black.opacity(0.18) : .clear, radius: component.shadowEnabled ? 16 : 0, x: 0, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: component.cornerRadius, style: .continuous)
                .stroke(component.borderEnabled ? accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .accessibilityLabel(component.altText.isEmpty ? asset.originalFileName : component.altText)
    }

    private func componentWidth(_ component: SiteComponent) -> CGFloat? {
        switch component.widthMode {
        case .small: return mode == .mobile ? 140 : 220
        case .medium: return mode == .mobile ? 220 : 360
        case .large: return mode == .mobile ? nil : 560
        case .full: return nil
        case .custom: return component.customWidth.map { CGFloat($0) }
        }
    }

    private func componentHeight(_ component: SiteComponent) -> CGFloat? {
        switch component.heightMode {
        case .auto: return component.componentType == .video ? (mode == .mobile ? 190 : 280) : nil
        case .short: return 160
        case .medium: return mode == .mobile ? 220 : 300
        case .tall: return mode == .mobile ? 320 : 460
        case .custom: return component.customHeight.map { CGFloat($0) }
        }
    }

    private func alignment(for alignment: SiteComponentAlignment) -> Alignment {
        switch alignment {
        case .left: return .leading
        case .center, .stretch: return .center
        case .right: return .trailing
        }
    }
}

private extension Color {
    init?(hexString: String) {
        let raw = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = Int(raw, radix: 16) else { return nil }
        self = Color(hex: UInt32(value))
    }
}

private struct SiteRenderedMedia: View {
    let asset: SiteMediaAsset
    let cornerRadius: Double
    let opacity: Double
    let fill: Bool

    var body: some View {
        Group {
            if let image = dataImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else if let url = remoteURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: fill ? .fill : .fit)
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                            .redacted(reason: .placeholder)
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x111827).opacity(0.04))
        .opacity(opacity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipped()
    }

    private var dataImage: UIImage? {
        guard let url = asset.previewURLString,
              url.starts(with: "data:image"),
              let range = url.range(of: "base64,"),
              let data = Data(base64Encoded: String(url[range.upperBound...])) else { return nil }
        return UIImage(data: data)
    }

    private var remoteURL: URL? {
        guard let urlString = asset.previewURLString,
              let url = URL(string: urlString),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x7B3FF2).opacity(0.2), Color(hex: 0x111827).opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                OneWayResolvedIcon(systemName: "photo.on.rectangle.angled")
                    .font(.title.weight(.black))
                Text(asset.altText.isEmpty ? "Site Image" : asset.altText)
                    .font(.caption.weight(.black))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
    }
}

private struct SiteRenderedVideo: View {
    let asset: SiteMediaAsset
    var component: SiteComponent? = nil

    var body: some View {
        Group {
            if let url = playbackURL {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x111827), Color(hex: 0x7B3FF2).opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 10) {
                        OneWayResolvedIcon(systemName: "play.rectangle.fill")
                            .font(.system(size: 42, weight: .black))
                        Text(asset.processingStatus == .ready ? "Video Preview" : "Processing video...")
                            .font(.headline.weight(.black))
                        Text(asset.originalFileName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: component?.cornerRadius ?? 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }

    private var playbackURL: URL? {
        let value = asset.variants["playback"] ?? asset.variants["original"] ?? asset.previewURLString
        guard let value,
              let url = URL(string: value),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https" || scheme == "file" || value.starts(with: "data:video") else { return nil }
        return value.starts(with: "data:video") ? nil : url
    }
}
