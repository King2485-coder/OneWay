import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers

struct EditSiteView: View {
    @StateObject private var viewModel: EditSiteViewModel
    @State private var showingPreview = false
    @State private var showingBlockMenu = false
    @State private var showingReorderSheet = false
    private let siteService: SiteService

    init(siteService: SiteService, domainSlug: String) {
        self.siteService = siteService
        self._viewModel = StateObject(
            wrappedValue: EditSiteViewModel(siteService: siteService, domainSlug: domainSlug)
        )
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    modePicker
                    titleAndDescription
                    modeSpecificSection
                    publishChecklist
                    messages
                    actionButtons
                }
                .padding(20)
                .padding(.bottom, 120)
            }
        }
        .navigationTitle("Edit Site")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .sheet(isPresented: $showingPreview) {
            NavigationStack {
                SiteWebView(
                    url: viewModel.liveURL ?? URL(string: "https://oneway.app")!,
                    html: viewModel.previewHTML
                )
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                        Button("Back") { showingPreview = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingReorderSheet) {
            SiteSectionReorderSheet(
                blocks: $viewModel.blocks,
                titleForBlock: blockTitle,
                iconForBlock: blockIcon,
                onMove: viewModel.moveBlocks(fromOffsets:toOffset:),
                onDone: { showingReorderSheet = false }
            )
        }
        .confirmationDialog("Add a section", isPresented: $showingBlockMenu, titleVisibility: .visible) {
            Button("Hero") { viewModel.addBlock(.hero(eyebrow: "Built on OneWay", title: viewModel.title, subtitle: viewModel.siteDescription)) }
            Button("Text") { viewModel.addBlock(.text(text: "Write a short section for visitors.")) }
            Button("Services") { viewModel.addBlock(.services(title: "What we offer", items: defaultServiceItems())) }
            Button("FAQ") { viewModel.addBlock(.faq(title: "Good to know", items: defaultFAQItems())) }
            Button("Photo") { viewModel.addBlock(.photo(url: "", alt: "Site photo", caption: "")) }
            Button("Gallery") { viewModel.addBlock(.gallery(title: "Gallery", images: defaultGalleryImages())) }
            Button("Testimonial") { viewModel.addBlock(.testimonial(quote: "Add a customer quote here.", name: "Customer name", role: "")) }
            Button("Button / Link") { viewModel.addBlock(.button(label: "Learn more", url: "https://")) }
            Button("Contact") { viewModel.addBlock(.contact(name: viewModel.title, email: "", phone: "")) }
            Button("Business Hours") { viewModel.addBlock(.hours(hours: "Monday-Friday, 9 AM-5 PM")) }
            Button("Call / Text CTA") { viewModel.addBlock(.callText(label: "Call or text us", phoneNumber: "")) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.fullDomain)
                    .font(.headline)
                    .foregroundStyle(Theme.accentGold)
                Spacer()
                if viewModel.isPublished {
                    OneWayResolvedLabel("Published", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.75), in: Capsule())
                }
            }

            Text("Build a simple site customers can visit, then publish it on your OneWay address.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(SiteMode.allCases) { mode in
                modePill(for: mode)
            }
        }
    }

    @ViewBuilder
    private func modePill(for mode: SiteMode) -> some View {
        let isActive = viewModel.mode == mode
        Button {
            viewModel.mode = mode
        } label: {
            VStack(spacing: 2) {
                Text(mode.label)
                    .font(.subheadline.weight(.semibold))
                Text(mode.hint)
                    .font(.caption2)
                    .opacity(0.85)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.glassSurface)
                    if isActive {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.accentGradient)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? Color.clear : Theme.divider, lineWidth: 1)
            )
            .foregroundStyle(isActive ? Color.white : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var titleAndDescription: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Title")
            TextField("My OneWay Site", text: $viewModel.title)
                .textInputAutocapitalization(.sentences)
                .oneWayFieldStyle()

            fieldLabel("Description")
            TextField("What's this page about?", text: $viewModel.siteDescription, axis: .vertical)
                .lineLimit(2...4)
                .oneWayFieldStyle()
        }
    }

    @ViewBuilder
    private var modeSpecificSection: some View {
        switch viewModel.mode {
        case .nocode:
            nocodeBuilder
        case .code:
            htmlEditor
        case .ai:
            aiSection
        }
    }

    private var nocodeBuilder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page sections")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Stack a page from simple pieces. No code needed.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if !viewModel.blocks.isEmpty {
                    Button {
                        showingReorderSheet = true
                    } label: {
                        OneWayResolvedLabel("Reorder", systemImage: "arrow.up.arrow.down")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.textSecondary)
                }
                Button {
                    showingBlockMenu = true
                } label: {
                    OneWayResolvedLabel("Add", systemImage: "plus")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primaryBlue)
            }

            templateStrip

            if viewModel.blocks.isEmpty {
                emptyBlocksState
            } else {
                ForEach(Array(viewModel.blocks.enumerated()), id: \.offset) { index, block in
                    blockEditor(index: index, block: block)
                }
            }
        }
    }

    private var templateStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start with a template")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SiteTemplate.allCases) { template in
                        Button {
                            viewModel.applyTemplate(template)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                OneWayResolvedIcon(systemName: template.icon)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(Theme.accentGold)
                                Text(template.title)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(template.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                            }
                            .frame(width: 148, alignment: .leading)
                            .padding(12)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.divider, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptyBlocksState: some View {
        VStack(spacing: 10) {
            OneWayResolvedIcon(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(Theme.accentGold)
            Text("Start with a hero, contact card, or call button.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Your first site can be just one page. Add a few sections, preview it, then publish.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Add first section") { showingBlockMenu = true }
                .buttonStyle(PrimaryPillButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private func blockEditor(index: Int, block: SiteBlock) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OneWayResolvedLabel(blockTitle(block), systemImage: blockIcon(block))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { viewModel.moveBlock(from: index, direction: -1) } label: { OneWayResolvedIcon(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { viewModel.moveBlock(from: index, direction: 1) } label: { OneWayResolvedIcon(systemName: "chevron.down") }
                    .disabled(index == viewModel.blocks.count - 1)
                Button(role: .destructive) { viewModel.removeBlock(at: index) } label: { OneWayResolvedIcon(systemName: "trash") }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)

            blockFields(index: index, block: block)
        }
        .padding(14)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    @ViewBuilder
    private func blockFields(index: Int, block: SiteBlock) -> some View {
        switch block {
        case .hero:
            smallTextField("Eyebrow", text: heroBinding(index, field: .eyebrow))
            smallTextField("Headline", text: heroBinding(index, field: .title))
            smallTextField("Subtitle", text: heroBinding(index, field: .subtitle), lineLimit: 2...4)
        case .text:
            smallTextField("Text", text: textBlockBinding(index), lineLimit: 3...6)
        case .services(_, let items):
            smallTextField("Section title", text: servicesTitleBinding(index))

            ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Service \(itemIndex + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if items.count > 1 {
                            Button(role: .destructive) {
                                removeServiceItem(blockIndex: index, itemIndex: itemIndex)
                            } label: {
                                OneWayResolvedIcon(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    smallTextField("Service name", text: serviceItemBinding(index, itemIndex: itemIndex, field: .title))
                    smallTextField("Short description", text: serviceItemBinding(index, itemIndex: itemIndex, field: .detail), lineLimit: 2...4)
                }
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                addServiceItem(to: index)
            } label: {
                OneWayResolvedLabel("Add service", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentGold)
        case .faq(_, let items):
            smallTextField("Section title", text: faqTitleBinding(index))

            ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Question \(itemIndex + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if items.count > 1 {
                            Button(role: .destructive) {
                                removeFAQItem(blockIndex: index, itemIndex: itemIndex)
                            } label: {
                                OneWayResolvedIcon(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    smallTextField("Question", text: faqItemBinding(index, itemIndex: itemIndex, field: .question))
                    smallTextField("Answer", text: faqItemBinding(index, itemIndex: itemIndex, field: .answer), lineLimit: 2...4)
                }
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                addFAQItem(to: index)
            } label: {
                OneWayResolvedLabel("Add question", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentGold)
        case .button:
            smallTextField("Button label", text: buttonBinding(index, field: .label))
            smallTextField("Link", text: buttonBinding(index, field: .url))
        case .contact:
            smallTextField("Name", text: contactBinding(index, field: .name))
            smallTextField("Email", text: contactBinding(index, field: .email))
            smallTextField("Phone", text: contactBinding(index, field: .phone))
        case .hours:
            smallTextField("Hours", text: hoursBinding(index), lineLimit: 2...4)
        case .callText:
            smallTextField("Call to action", text: callTextBinding(index, field: .label))
            smallTextField("Phone number", text: callTextBinding(index, field: .phoneNumber))
        case .photo(let url, _, _):
            if let previewURL = URL(string: url), !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AsyncImage(url: previewURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                            OneWayResolvedIcon(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            SitePhotoUploadButton(isUploading: viewModel.uploadingBlockIndex == index) { item in
                Task { await uploadSelectedPhoto(item, toBlockAt: index) }
            }
            smallTextField("Image URL", text: photoBinding(index, field: .url))
            smallTextField("Image description", text: photoBinding(index, field: .alt))
            smallTextField("Caption", text: photoBinding(index, field: .caption), lineLimit: 1...3)
        case .gallery(_, let images):
            smallTextField("Gallery title", text: galleryTitleBinding(index))

            ForEach(Array(images.enumerated()), id: \.offset) { imageIndex, _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Image \(imageIndex + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if images.count > 1 {
                            Button(role: .destructive) {
                                removeGalleryImage(blockIndex: index, imageIndex: imageIndex)
                            } label: {
                                OneWayResolvedIcon(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    let imageURL = images[imageIndex].url.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let previewURL = URL(string: imageURL), !imageURL.isEmpty {
                        AsyncImage(url: previewURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            default:
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                    OneWayResolvedIcon(systemName: "photo")
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    SitePhotoUploadButton(
                        isUploading: viewModel.isUploadingGalleryImage(blockIndex: index, imageIndex: imageIndex)
                    ) { item in
                        Task {
                            await uploadSelectedGalleryPhoto(item, blockIndex: index, imageIndex: imageIndex)
                        }
                    }
                    smallTextField("Image URL", text: galleryImageBinding(index, imageIndex: imageIndex, field: .url))
                    smallTextField("Image description", text: galleryImageBinding(index, imageIndex: imageIndex, field: .alt))
                    smallTextField("Caption", text: galleryImageBinding(index, imageIndex: imageIndex, field: .caption))
                }
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                addGalleryImage(to: index)
            } label: {
                OneWayResolvedLabel("Add gallery image", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentGold)
        case .testimonial:
            smallTextField("Quote", text: testimonialBinding(index, field: .quote), lineLimit: 3...6)
            smallTextField("Name", text: testimonialBinding(index, field: .name))
            smallTextField("Title or note", text: testimonialBinding(index, field: .role))
        case .heading, .paragraph, .image, .link, .divider, .html:
            Text("This older block will still publish. Add a new section to edit with the new builder.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var htmlEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                fieldLabel("HTML")
                Spacer()
                Button("Starter template") { viewModel.applyStarterTemplate() }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accentGold)
                Button("Preview") { showingPreview = true }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.primaryBlue)
                    .disabled(viewModel.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextEditor(text: $viewModel.html)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 260)
                .padding(10)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.divider, lineWidth: 1))

            if let validation = viewModel.validationMessage {
                OneWayResolvedLabel(validation, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("Describe your site")
            TextField("A landing page for my photography portfolio…", text: $viewModel.aiPrompt, axis: .vertical)
                .lineLimit(3...6)
                .oneWayFieldStyle()

            Button {
                Task { await viewModel.generateWithAI() }
            } label: {
                HStack {
                    if viewModel.isGenerating {
                        ProgressView().tint(.white)
                    } else {
                        OneWayResolvedIcon(systemName: "sparkles")
                        Text("Generate with AI")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(viewModel.isGenerating)

            if !viewModel.blocks.isEmpty {
                Divider()
                    .overlay(Theme.divider)
                nocodeBuilder
            }
        }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let info = viewModel.infoMessage {
                Text(info)
                    .font(.footnote)
                    .foregroundStyle(Theme.accentGold)
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                showingPreview = true
            } label: {
                OneWayResolvedLabel("Preview site", systemImage: "eye.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.glassSurface, in: Capsule())
                    .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)

            Button {
                Task { await viewModel.save(thenPublish: true) }
            } label: {
                HStack {
                    if viewModel.isSaving || viewModel.isPublishing {
                        ProgressView().tint(.white)
                    } else {
                        OneWayResolvedIcon(systemName: "paperplane.fill")
                        Text("Save & publish")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(viewModel.isSaving || viewModel.isPublishing)

            Button {
                Task { await viewModel.save(thenPublish: false) }
            } label: {
                Text("Save draft")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.glassSurface, in: Capsule())
                    .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)

            if viewModel.isPublished, let url = viewModel.liveURL {
                NavigationLink {
                    BrowserPageView(url: url, siteService: siteService)
                } label: {
                    OneWayResolvedLabel("Visit live site", systemImage: "arrow.up.right.square.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.glassSurface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                        .foregroundStyle(Theme.accentGold)
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textMuted)
    }

    @ViewBuilder
    private var publishChecklist: some View {
        if !viewModel.publishChecklist.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                OneWayResolvedLabel("Your site is almost ready", systemImage: "checklist")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Finish these items before publishing.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)

                ForEach(viewModel.publishChecklist, id: \.self) { item in
                    OneWayResolvedLabel(item, systemImage: "circle")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.divider, lineWidth: 1))
        }
    }

    private func smallTextField(_ placeholder: String, text: Binding<String>, lineLimit: ClosedRange<Int> = 1...1) -> some View {
        TextField(placeholder, text: text, axis: lineLimit.upperBound > 1 ? .vertical : .horizontal)
            .lineLimit(lineLimit)
            .oneWayFieldStyle()
    }

    private func blockTitle(_ block: SiteBlock) -> String {
        switch block {
        case .hero: return "Hero"
        case .text: return "Text"
        case .button: return "Button / Link"
        case .contact: return "Contact"
        case .hours: return "Business Hours"
        case .callText: return "Call / Text"
        case .photo: return "Photo"
        case .gallery: return "Gallery"
        case .testimonial: return "Testimonial"
        case .services: return "Services"
        case .faq: return "FAQ"
        case .heading: return "Heading"
        case .paragraph: return "Paragraph"
        case .image: return "Image"
        case .link: return "Link"
        case .divider: return "Divider"
        case .html: return "Custom HTML"
        }
    }

    private func blockIcon(_ block: SiteBlock) -> String {
        switch block {
        case .hero: return "sparkles.rectangle.stack"
        case .text: return "text.alignleft"
        case .button: return "link.circle.fill"
        case .contact: return "person.crop.circle.badge.checkmark"
        case .hours: return "clock.fill"
        case .callText: return "phone.bubble.left.fill"
        case .photo: return "photo.on.rectangle.angled"
        case .gallery: return "square.grid.2x2.fill"
        case .testimonial: return "quote.bubble.fill"
        case .services: return "list.bullet.rectangle.portrait.fill"
        case .faq: return "questionmark.bubble.fill"
        case .heading: return "textformat.size"
        case .paragraph: return "paragraphsign"
        case .image: return "photo.fill"
        case .link: return "link"
        case .divider: return "minus"
        case .html: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

private enum HeroField { case eyebrow, title, subtitle }
private enum ButtonField { case label, url }
private enum ContactField { case name, email, phone }
private enum CallTextField { case label, phoneNumber }
private enum PhotoField { case url, alt, caption }
private enum GalleryImageField { case url, alt, caption }
private enum TestimonialField { case quote, name, role }
private enum ServiceItemField { case title, detail }
private enum FAQItemField { case question, answer }

private extension EditSiteView {
    func defaultServiceItems() -> [SiteServiceItem] {
        [
            SiteServiceItem(title: "Main offer", detail: "Describe the service, product, or package people should notice first."),
            SiteServiceItem(title: "Fast follow-up", detail: "Tell visitors how quickly you reply and what happens next."),
            SiteServiceItem(title: "Trusted support", detail: "Add your proof point, location, warranty, or experience note.")
        ]
    }

    func defaultFAQItems() -> [SiteFAQItem] {
        [
            SiteFAQItem(question: "How do I get started?", answer: "Call, text, or send a message and we will follow up with next steps."),
            SiteFAQItem(question: "Where are you located?", answer: "Add your service area, address, or online availability.")
        ]
    }

    func defaultGalleryImages() -> [SiteGalleryImage] {
        [
            SiteGalleryImage(url: "", alt: "Gallery image", caption: "First highlight"),
            SiteGalleryImage(url: "", alt: "Gallery image", caption: "Second highlight"),
            SiteGalleryImage(url: "", alt: "Gallery image", caption: "Third highlight")
        ]
    }

    func uploadSelectedPhoto(_ item: PhotosPickerItem, toBlockAt index: Int) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run {
                viewModel.errorMessage = "Couldn't read that photo. Try another image."
            }
            return
        }

        let mimeType = item.supportedContentTypes
            .compactMap(\.preferredMIMEType)
            .first { ["image/jpeg", "image/png", "image/webp"].contains($0) } ?? "image/jpeg"
        let fileExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "jpg"
        await viewModel.uploadPhoto(
            data: data,
            fileName: "site-photo-\(UUID().uuidString).\(fileExtension)",
            mimeType: mimeType,
            toBlockAt: index
        )
    }

    func uploadSelectedGalleryPhoto(_ item: PhotosPickerItem, blockIndex: Int, imageIndex: Int) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run {
                viewModel.errorMessage = "Couldn't read that gallery photo. Try another image."
            }
            return
        }

        let mimeType = item.supportedContentTypes
            .compactMap(\.preferredMIMEType)
            .first { ["image/jpeg", "image/png", "image/webp"].contains($0) } ?? "image/jpeg"
        let fileExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "jpg"
        await viewModel.uploadGalleryPhoto(
            data: data,
            fileName: "gallery-photo-\(UUID().uuidString).\(fileExtension)",
            mimeType: mimeType,
            blockIndex: blockIndex,
            imageIndex: imageIndex
        )
    }

    func heroBinding(_ index: Int, field: HeroField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index), case .hero(let eyebrow, let title, let subtitle) = viewModel.blocks[index] else { return "" }
            switch field {
            case .eyebrow: return eyebrow
            case .title: return title
            case .subtitle: return subtitle
            }
        } set: { value in
            guard viewModel.blocks.indices.contains(index), case .hero(let eyebrow, let title, let subtitle) = viewModel.blocks[index] else { return }
            switch field {
            case .eyebrow: viewModel.updateBlock(at: index, with: .hero(eyebrow: value, title: title, subtitle: subtitle))
            case .title: viewModel.updateBlock(at: index, with: .hero(eyebrow: eyebrow, title: value, subtitle: subtitle))
            case .subtitle: viewModel.updateBlock(at: index, with: .hero(eyebrow: eyebrow, title: title, subtitle: value))
            }
        }
    }

    func textBlockBinding(_ index: Int) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index), case .text(let text) = viewModel.blocks[index] else { return "" }
            return text
        } set: { value in
            viewModel.updateBlock(at: index, with: .text(text: value))
        }
    }

    func servicesTitleBinding(_ index: Int) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index),
                  case .services(let title, _) = viewModel.blocks[index] else { return "" }
            return title
        } set: { value in
            guard viewModel.blocks.indices.contains(index),
                  case .services(_, let items) = viewModel.blocks[index] else { return }
            viewModel.updateBlock(at: index, with: .services(title: value, items: items))
        }
    }

    func serviceItemBinding(_ blockIndex: Int, itemIndex: Int, field: ServiceItemField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(blockIndex),
                  case .services(_, let items) = viewModel.blocks[blockIndex],
                  items.indices.contains(itemIndex) else { return "" }
            let item = items[itemIndex]
            switch field {
            case .title: return item.title
            case .detail: return item.detail
            }
        } set: { value in
            guard viewModel.blocks.indices.contains(blockIndex),
                  case .services(let title, let items) = viewModel.blocks[blockIndex],
                  items.indices.contains(itemIndex) else { return }
            var next = items
            switch field {
            case .title:
                next[itemIndex].title = value
            case .detail:
                next[itemIndex].detail = value
            }
            viewModel.updateBlock(at: blockIndex, with: .services(title: title, items: next))
        }
    }

    func addServiceItem(to blockIndex: Int) {
        guard viewModel.blocks.indices.contains(blockIndex),
              case .services(let title, let items) = viewModel.blocks[blockIndex] else { return }
        var next = items
        next.append(SiteServiceItem(title: "New offer", detail: "Describe what visitors get."))
        viewModel.updateBlock(at: blockIndex, with: .services(title: title, items: next))
    }

    func removeServiceItem(blockIndex: Int, itemIndex: Int) {
        guard viewModel.blocks.indices.contains(blockIndex),
              case .services(let title, let items) = viewModel.blocks[blockIndex],
              items.indices.contains(itemIndex),
              items.count > 1 else { return }
        var next = items
        next.remove(at: itemIndex)
        viewModel.updateBlock(at: blockIndex, with: .services(title: title, items: next))
    }

    func faqTitleBinding(_ index: Int) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index),
                  case .faq(let title, _) = viewModel.blocks[index] else { return "" }
            return title
        } set: { value in
            guard viewModel.blocks.indices.contains(index),
                  case .faq(_, let items) = viewModel.blocks[index] else { return }
            viewModel.updateBlock(at: index, with: .faq(title: value, items: items))
        }
    }

    func faqItemBinding(_ blockIndex: Int, itemIndex: Int, field: FAQItemField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(blockIndex),
                  case .faq(_, let items) = viewModel.blocks[blockIndex],
                  items.indices.contains(itemIndex) else { return "" }
            let item = items[itemIndex]
            switch field {
            case .question: return item.question
            case .answer: return item.answer
            }
        } set: { value in
            guard viewModel.blocks.indices.contains(blockIndex),
                  case .faq(let title, let items) = viewModel.blocks[blockIndex],
                  items.indices.contains(itemIndex) else { return }
            var next = items
            switch field {
            case .question:
                next[itemIndex].question = value
            case .answer:
                next[itemIndex].answer = value
            }
            viewModel.updateBlock(at: blockIndex, with: .faq(title: title, items: next))
        }
    }

    func addFAQItem(to blockIndex: Int) {
        guard viewModel.blocks.indices.contains(blockIndex),
              case .faq(let title, let items) = viewModel.blocks[blockIndex] else { return }
        var next = items
        next.append(SiteFAQItem(question: "New question", answer: "Add the answer visitors need."))
        viewModel.updateBlock(at: blockIndex, with: .faq(title: title, items: next))
    }

    func removeFAQItem(blockIndex: Int, itemIndex: Int) {
        guard viewModel.blocks.indices.contains(blockIndex),
              case .faq(let title, let items) = viewModel.blocks[blockIndex],
              items.indices.contains(itemIndex),
              items.count > 1 else { return }
        var next = items
        next.remove(at: itemIndex)
        viewModel.updateBlock(at: blockIndex, with: .faq(title: title, items: next))
    }

    func buttonBinding(_ index: Int, field: ButtonField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index), case .button(let label, let url) = viewModel.blocks[index] else { return "" }
            return field == .label ? label : url
        } set: { value in
            guard viewModel.blocks.indices.contains(index), case .button(let label, let url) = viewModel.blocks[index] else { return }
            viewModel.updateBlock(at: index, with: field == .label ? .button(label: value, url: url) : .button(label: label, url: value))
        }
    }

    func contactBinding(_ index: Int, field: ContactField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index), case .contact(let name, let email, let phone) = viewModel.blocks[index] else { return "" }
            switch field {
            case .name: return name
            case .email: return email
            case .phone: return phone
            }
        } set: { value in
            guard viewModel.blocks.indices.contains(index), case .contact(let name, let email, let phone) = viewModel.blocks[index] else { return }
            switch field {
            case .name: viewModel.updateBlock(at: index, with: .contact(name: value, email: email, phone: phone))
            case .email: viewModel.updateBlock(at: index, with: .contact(name: name, email: value, phone: phone))
            case .phone: viewModel.updateBlock(at: index, with: .contact(name: name, email: email, phone: value))
            }
        }
    }

    func hoursBinding(_ index: Int) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index), case .hours(let hours) = viewModel.blocks[index] else { return "" }
            return hours
        } set: { value in
            viewModel.updateBlock(at: index, with: .hours(hours: value))
        }
    }

    func callTextBinding(_ index: Int, field: CallTextField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index), case .callText(let label, let phoneNumber) = viewModel.blocks[index] else { return "" }
            return field == .label ? label : phoneNumber
        } set: { value in
            guard viewModel.blocks.indices.contains(index), case .callText(let label, let phoneNumber) = viewModel.blocks[index] else { return }
            viewModel.updateBlock(at: index, with: field == .label ? .callText(label: value, phoneNumber: phoneNumber) : .callText(label: label, phoneNumber: value))
        }
    }

    func photoBinding(_ index: Int, field: PhotoField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index),
                  case .photo(let url, let alt, let caption) = viewModel.blocks[index] else { return "" }
            switch field {
            case .url: return url
            case .alt: return alt
            case .caption: return caption
            }
        } set: { value in
            guard viewModel.blocks.indices.contains(index),
                  case .photo(let url, let alt, let caption) = viewModel.blocks[index] else { return }
            switch field {
            case .url:
                viewModel.updateBlock(at: index, with: .photo(url: value, alt: alt, caption: caption))
            case .alt:
                viewModel.updateBlock(at: index, with: .photo(url: url, alt: value, caption: caption))
            case .caption:
                viewModel.updateBlock(at: index, with: .photo(url: url, alt: alt, caption: value))
            }
        }
    }

    func galleryTitleBinding(_ index: Int) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index),
                  case .gallery(let title, _) = viewModel.blocks[index] else { return "" }
            return title
        } set: { value in
            guard viewModel.blocks.indices.contains(index),
                  case .gallery(_, let images) = viewModel.blocks[index] else { return }
            viewModel.updateBlock(at: index, with: .gallery(title: value, images: images))
        }
    }

    func galleryImageBinding(_ blockIndex: Int, imageIndex: Int, field: GalleryImageField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(blockIndex),
                  case .gallery(_, let images) = viewModel.blocks[blockIndex],
                  images.indices.contains(imageIndex) else { return "" }
            let image = images[imageIndex]
            switch field {
            case .url: return image.url
            case .alt: return image.alt
            case .caption: return image.caption
            }
        } set: { value in
            guard viewModel.blocks.indices.contains(blockIndex),
                  case .gallery(let title, let images) = viewModel.blocks[blockIndex],
                  images.indices.contains(imageIndex) else { return }
            var next = images
            switch field {
            case .url:
                next[imageIndex].url = value
            case .alt:
                next[imageIndex].alt = value
            case .caption:
                next[imageIndex].caption = value
            }
            viewModel.updateBlock(at: blockIndex, with: .gallery(title: title, images: next))
        }
    }

    func addGalleryImage(to blockIndex: Int) {
        guard viewModel.blocks.indices.contains(blockIndex),
              case .gallery(let title, let images) = viewModel.blocks[blockIndex] else { return }
        var next = images
        next.append(SiteGalleryImage(url: "", alt: "Gallery image", caption: "New highlight"))
        viewModel.updateBlock(at: blockIndex, with: .gallery(title: title, images: next))
    }

    func removeGalleryImage(blockIndex: Int, imageIndex: Int) {
        guard viewModel.blocks.indices.contains(blockIndex),
              case .gallery(let title, let images) = viewModel.blocks[blockIndex],
              images.indices.contains(imageIndex),
              images.count > 1 else { return }
        var next = images
        next.remove(at: imageIndex)
        viewModel.updateBlock(at: blockIndex, with: .gallery(title: title, images: next))
    }

    func testimonialBinding(_ index: Int, field: TestimonialField) -> Binding<String> {
        Binding {
            guard viewModel.blocks.indices.contains(index),
                  case .testimonial(let quote, let name, let role) = viewModel.blocks[index] else { return "" }
            switch field {
            case .quote: return quote
            case .name: return name
            case .role: return role
            }
        } set: { value in
            guard viewModel.blocks.indices.contains(index),
                  case .testimonial(let quote, let name, let role) = viewModel.blocks[index] else { return }
            switch field {
            case .quote:
                viewModel.updateBlock(at: index, with: .testimonial(quote: value, name: name, role: role))
            case .name:
                viewModel.updateBlock(at: index, with: .testimonial(quote: quote, name: value, role: role))
            case .role:
                viewModel.updateBlock(at: index, with: .testimonial(quote: quote, name: name, role: value))
            }
        }
    }
}

private struct SiteSectionReorderSheet: View {
    @Binding var blocks: [SiteBlock]
    let titleForBlock: (SiteBlock) -> String
    let iconForBlock: (SiteBlock) -> String
    let onMove: (IndexSet, Int) -> Void
    let onDone: () -> Void
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()
                List {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        OneWayResolvedLabel(titleForBlock(block), systemImage: iconForBlock(block))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .listRowBackground(Theme.glassSurface)
                    }
                    .onMove(perform: onMove)
                }
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
            }
            .navigationTitle("Reorder sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}

private struct SitePhotoUploadButton: View {
    let isUploading: Bool
    let onPick: (PhotosPickerItem) -> Void
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            OneWayResolvedLabel(isUploading ? "Uploading photo..." : "Choose photo", systemImage: "photo.badge.plus")
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(isUploading)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            onPick(item)
            pickerItem = nil
        }
    }
}

private extension View {
    func oneWayFieldStyle() -> some View {
        self
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.divider, lineWidth: 1)
            )
    }
}
