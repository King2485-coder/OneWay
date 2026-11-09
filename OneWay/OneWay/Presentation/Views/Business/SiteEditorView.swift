import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct SiteEditorView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    @State private var draft: OneWayBuilderSite
    let onRoute: (SitesRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPageIndex = 0
    @State private var selectedSectionIndex = 0
    @State private var showChecklist = false
    @State private var previewMode: SitePreviewMode = .mobile
    @State private var aiInstruction = ""
    @State private var showAIPanel = false
    private let mediaUploadService = SiteMediaUploadService()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var videoItems: [PhotosPickerItem] = []
    @State private var showImageSourceDialog = false
    @State private var showVideoSourceDialog = false
    @State private var showImagePhotoPicker = false
    @State private var showVideoPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showVideoFileImporter = false
    @State private var cameraRequest: SiteCameraRequest?
    @State private var isUploadingMedia = false
    @State private var imageAltText = ""
    @State private var imageCaption = ""
    @State private var showPublishReview = false
    @State private var selectedComponentForPlacement: SiteComponent?
    @State private var uploadStatusText = ""
    @FocusState private var focusedField: SiteEditorFocusedField?

    init(viewModel: OneWaySitesViewModel, site: OneWayBuilderSite, onRoute: @escaping (SitesRoute) -> Void) {
        self.viewModel = viewModel
        self._draft = State(initialValue: site)
        self.onRoute = onRoute
    }

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                editorTopBar
                ScrollView {
                    VStack(spacing: 14) {
                        builderStrip
                        pagesPanel
                        sectionsPanel
                        mediaPanel
                        canvasPanel
                        if !draft.pages.isEmpty, !draft.pages[selectedPageIndex].sections.isEmpty {
                            editorPanel
                        }
                        SiteThemeEditorView(theme: $draft.theme)
                    }
                    .padding(16)
                    .padding(.bottom, 120)
                }
            }
        }
        .navigationBarHidden(true)
        .alert("Your site is almost ready. Finish these items before publishing.", isPresented: $showChecklist) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.publishChecklist.joined(separator: "\n"))
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotoItems(items, mediaType: .image) }
        }
        .onChange(of: videoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotoItems(items, mediaType: .video) }
        }
        .photosPicker(isPresented: $showImagePhotoPicker, selection: $photoItems, maxSelectionCount: 1, matching: .images)
        .photosPicker(isPresented: $showVideoPhotoPicker, selection: $videoItems, maxSelectionCount: 1, matching: .videos)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            print("SITE_MEDIA_PICKER_DISMISSED mediaType=IMAGE sourceType=FILES")
            Task { await importFiles(result, mediaType: .image) }
        }
        .fileImporter(isPresented: $showVideoFileImporter, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie], allowsMultipleSelection: true) { result in
            print("SITE_MEDIA_PICKER_DISMISSED mediaType=VIDEO sourceType=FILES")
            Task { await importFiles(result, mediaType: .video) }
        }
        .confirmationDialog("Choose media source", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
            mediaSourceButtons(for: .image)
        }
        .confirmationDialog("Choose media source", isPresented: $showVideoSourceDialog, titleVisibility: .visible) {
            mediaSourceButtons(for: .video)
        }
        .sheet(item: $cameraRequest) { request in
            SiteCameraCaptureView(mediaType: request.mediaType) { result in
                cameraRequest = nil
                Task { await handleCameraResult(result, mediaType: request.mediaType) }
            }
        }
        .sheet(isPresented: $showPublishReview) {
            SitePublishReviewSheet(viewModel: viewModel, site: draft) {
                save()
                if !viewModel.publish(draft) {
                    showChecklist = true
                } else if let updated = viewModel.site(draft.id) {
                    draft = updated
                }
                showPublishReview = false
            }
        }
        .sheet(item: $selectedComponentForPlacement) { component in
            SiteMediaPlacementEditor(
                site: draft,
                component: component,
                assets: viewModel.mediaAssets(for: draft),
                onUpdate: { updated in
                    draft = viewModel.updateComponent(updated, in: draft)
                    selectedComponentForPlacement = updated
                },
                onMove: { target in
                    draft = viewModel.moveComponent(component.id, in: draft, to: target)
                    selectedComponentForPlacement = nil
                },
                onDuplicate: { target in
                    draft = viewModel.duplicateComponent(component.id, in: draft, to: target)
                    selectedComponentForPlacement = nil
                },
                onDelete: {
                    draft = viewModel.deleteComponent(component.id, in: draft)
                    selectedComponentForPlacement = nil
                }
            )
        }
    }

    private var editorTopBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                OneWayResolvedIcon(systemName: "chevron.left")
                    .frame(width: 38, height: 38)
                    .background(OneWayCallTheme.lavenderSurface, in: Circle())
                    .overlay(Circle().stroke(OneWayCallTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(OneWayCallTheme.purple)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Site name", text: $draft.name)
                    .font(.headline.weight(.black))
                    .oneWayReadableText(.title)
                    .focused($focusedField, equals: .siteName)
                Text("Saved locally")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
            }

            Spacer()

            iconTopButton("arrow.uturn.backward") {}
            iconTopButton("arrow.uturn.forward") {}
            iconTopButton("sparkles") { showAIPanel.toggle() }
        }
        .padding(14)
        .background(OneWayCallTheme.surface)
        .overlay(Rectangle().fill(OneWayCallTheme.border).frame(height: 1), alignment: .bottom)
    }

    private var builderStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Device", selection: $previewMode) {
                    ForEach(SitePreviewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Spacer(minLength: 0)
            }

            if showAIPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask OneWay AI")
                        .font(.headline.weight(.black))
                        .oneWayReadableText(.title)
                TextField("Example: Make this hero more direct and add a quote CTA", text: $aiInstruction, axis: .vertical)
                    .lineLimit(2...4)
                    .oneWayLightFieldStyle()
                    .focused($focusedField, equals: .aiInstruction)
                    Button("Apply AI Suggestion") {
                        applyAISuggestion()
                    }
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(OneWayCallTheme.purpleGradient, in: Capsule())
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                labeledBuilderAction("Pages", "doc.text.fill") {}
                labeledBuilderAction("Sections", "square.stack.3d.up.fill") {}
                labeledBuilderAction("Preview", "eye.fill") {
                    save()
                    onRoute(.preview(draft.id))
                }
                labeledBuilderAction("Publish", "icloud.and.arrow.up.fill", primary: true) {
                    save()
                    viewModel.publishChecklist = viewModel.validationIssues(for: draft) + viewModel.imagePublishIssues(for: draft)
                    viewModel.publishWarnings = viewModel.imageAccessibilityWarnings(for: draft)
                    if viewModel.publishChecklist.isEmpty {
                        showPublishReview = true
                    } else {
                        showChecklist = true
                    }
                }
            }
        }
        .padding(14)
        .oneWayCallGlass(cornerRadius: 18)
    }

    private var pagesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelTitle("Pages", icon: "doc.text.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(draft.pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            selectedPageIndex = index
                            selectedSectionIndex = 0
                        } label: {
                            Text(page.title)
                                .font(.caption.weight(.black))
                                .foregroundStyle(index == selectedPageIndex ? .white : OneWayCallTheme.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(index == selectedPageIndex ? OneWayCallTheme.purple : OneWayCallTheme.surface, in: Capsule())
                                .overlay(Capsule().stroke(index == selectedPageIndex ? Color.clear : OneWayCallTheme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        draft.pages.append(SitePage(title: "New Page", slug: "new-page", sections: [
                            .init(type: .hero, title: "New Page", body: "Add your page content here.", buttonTitle: nil)
                        ]))
                    } label: {
                        OneWayResolvedLabel("Add Page", systemImage: "plus")
                            .font(.caption.weight(.black))
                            .foregroundStyle(OneWayCallTheme.purple)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(OneWayCallTheme.lavenderSurface, in: Capsule())
                            .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                    }
                }
            }
        }
        .padding(14)
        .oneWayCallGlass(cornerRadius: 18)
    }

    private var sectionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelTitle("Sections", icon: "square.stack.3d.up.fill")
            if draft.pages.indices.contains(selectedPageIndex) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(draft.pages[selectedPageIndex].sections.enumerated()), id: \.element.id) { index, section in
                            Button { selectedSectionIndex = index } label: {
                                Text(section.type.rawValue)
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(index == selectedSectionIndex ? .white : OneWayCallTheme.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(index == selectedSectionIndex ? OneWayCallTheme.purple : OneWayCallTheme.surface, in: Capsule())
                                    .overlay(Capsule().stroke(index == selectedSectionIndex ? Color.clear : OneWayCallTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        Menu {
                            ForEach(SiteSectionType.allCases, id: \.self) { type in
                                Button(type.rawValue) {
                                    draft.pages[selectedPageIndex].sections.append(.init(type: type, title: type.rawValue, body: "Add \(type.rawValue.lowercased()) content.", buttonTitle: nil))
                                }
                            }
                        } label: {
                            OneWayResolvedLabel("Add Section", systemImage: "plus")
                                .font(.caption.weight(.black))
                                .foregroundStyle(OneWayCallTheme.purple)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(OneWayCallTheme.lavenderSurface, in: Capsule())
                                .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                        }
                    }
                }
            }
        }
        .padding(14)
        .oneWayCallGlass(cornerRadius: 18)
    }

    private var canvasPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelTitle("Live Website Preview", icon: "rectangle.inset.filled")
            SiteRendererView(site: draft, mode: previewMode)
                .frame(maxWidth: .infinity)
                .frame(height: 520)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .padding(14)
        .oneWayCallGlass(cornerRadius: 18)
    }

    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelTitle("Site Media", icon: "photo.on.rectangle.angled")
                Spacer()
                Button {
                    print("SITE_MEDIA_SOURCE_MENU_OPENED mediaType=IMAGE")
                    showImageSourceDialog = true
                } label: {
                    OneWayResolvedLabel("Add Image", systemImage: "plus")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(OneWayCallTheme.purpleGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    print("SITE_MEDIA_SOURCE_MENU_OPENED mediaType=VIDEO")
                    showVideoSourceDialog = true
                } label: {
                    OneWayResolvedLabel("Add Video", systemImage: "video.badge.plus")
                        .font(.caption.weight(.black))
                        .foregroundStyle(OneWayCallTheme.purple)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(OneWayCallTheme.lavenderSurface, in: Capsule())
                        .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if isUploadingMedia {
                ProgressView(uploadStatusText.isEmpty ? "Uploading media..." : uploadStatusText)
                    .font(.caption.weight(.bold))
                    .tint(OneWayCallTheme.purple)
            }

            TextField("Alt text for next upload", text: $imageAltText)
                .oneWayLightFieldStyle()
                .focused($focusedField, equals: .altText)
            TextField("Caption", text: $imageCaption)
                .oneWayLightFieldStyle()
                .focused($focusedField, equals: .caption)

            let assets = viewModel.mediaAssets(for: draft)
            if assets.isEmpty {
                ContentUnavailableView("No Site images yet", systemImage: "photo.badge.plus", description: Text("Add a hero image, logo, gallery photo, or content image. Draft content stays safe if an upload fails."))
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(assets) { asset in
                            mediaTile(asset)
                        }
                    }
                }
            }
        }
        .padding(14)
        .oneWayCallGlass(cornerRadius: 18)
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("Edit Section", icon: "pencil")
            SiteSectionEditorView(section: Binding(
                get: { draft.pages[selectedPageIndex].sections[selectedSectionIndex] },
                set: { draft.pages[selectedPageIndex].sections[selectedSectionIndex] = $0 }
            ))
            if draft.pages.indices.contains(selectedPageIndex),
               draft.pages[selectedPageIndex].sections.indices.contains(selectedSectionIndex) {
                SiteSectionImageEditor(
                    site: draft,
                    section: $draft.pages[selectedPageIndex].sections[selectedSectionIndex],
                    assets: viewModel.mediaAssets(for: draft),
                    onRemove: { assetID in
                        draft = viewModel.removeImage(assetID, from: draft, pageIndex: selectedPageIndex, sectionIndex: selectedSectionIndex)
                    },
                    onAutosave: { save() }
                )
                SiteComponentsPlacementList(
                    site: draft,
                    section: draft.pages[selectedPageIndex].sections[selectedSectionIndex],
                    assets: viewModel.mediaAssets(for: draft),
                    onSelect: { selectedComponentForPlacement = $0 },
                    onMoveUp: { component in draft = moveComponent(component, delta: -1) },
                    onMoveDown: { component in draft = moveComponent(component, delta: 1) }
                )
            }
        }
        .padding(14)
        .oneWayCallGlass(cornerRadius: 18)
    }

    private func panelTitle(_ text: String, icon: String) -> some View {
        OneWayResolvedLabel(text, systemImage: icon)
            .font(.headline.weight(.black))
            .oneWayReadableText(.title)
    }

    @ViewBuilder
    private func mediaSourceButtons(for mediaType: SiteMediaType) -> some View {
        Button("Photos") {
            requestMediaSource(mediaType: mediaType, source: .photos)
        }
        Button("Files") {
            requestMediaSource(mediaType: mediaType, source: .files)
        }
        Button("Camera") {
            requestMediaSource(mediaType: mediaType, source: .camera)
        }
        Button("Cancel", role: .cancel) {}
    }

    private func requestMediaSource(mediaType: SiteMediaType, source: SiteMediaSource) {
        print("SITE_MEDIA_SOURCE_SELECTED mediaType=\(mediaType.rawValue) sourceType=\(source.rawValue) activeField=\(focusedField?.rawValue ?? "none") keyboardVisible=\(focusedField != nil)")
        focusedField = nil
        dismissKeyboard()
        showImageSourceDialog = false
        showVideoSourceDialog = false
        showImagePhotoPicker = false
        showVideoPhotoPicker = false
        showFileImporter = false
        showVideoFileImporter = false
        cameraRequest = nil
        DispatchQueue.main.async {
            print("SITE_MEDIA_PICKER_PRESENT_REQUESTED mediaType=\(mediaType.rawValue) sourceType=\(source.rawValue) presentationState=idle")
            switch (mediaType, source) {
            case (.image, .photos):
                showImagePhotoPicker = true
                print("SITE_MEDIA_PICKER_PRESENTED mediaType=IMAGE sourceType=PHOTOS")
            case (.video, .photos):
                showVideoPhotoPicker = true
                print("SITE_MEDIA_PICKER_PRESENTED mediaType=VIDEO sourceType=PHOTOS")
            case (.image, .files):
                showFileImporter = true
                print("SITE_MEDIA_PICKER_PRESENTED mediaType=IMAGE sourceType=FILES")
            case (.video, .files):
                showVideoFileImporter = true
                print("SITE_MEDIA_PICKER_PRESENTED mediaType=VIDEO sourceType=FILES")
            case (_, .camera):
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    viewModel.publishMessage = "Camera is unavailable in the simulator. Use Photos or Files."
                    print("SITE_MEDIA_PICKER_PRESENT_FAILED mediaType=\(mediaType.rawValue) sourceType=CAMERA failureCode=camera_unavailable")
                    return
                }
                cameraRequest = SiteCameraRequest(mediaType: mediaType)
                print("SITE_MEDIA_PICKER_PRESENTED mediaType=\(mediaType.rawValue) sourceType=CAMERA")
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func save() {
        viewModel.upsert(draft)
    }

    private func applyAISuggestion() {
        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty,
              draft.pages.indices.contains(selectedPageIndex),
              draft.pages[selectedPageIndex].sections.indices.contains(selectedSectionIndex) else { return }
        draft.pages[selectedPageIndex].sections[selectedSectionIndex].body += "\n\nAI improvement: \(instruction)"
        aiInstruction = ""
        save()
    }

    private func mediaTile(_ asset: SiteMediaAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SiteMediaThumbnail(asset: asset)
                .frame(width: 128, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(asset.originalFileName)
                .font(.caption.weight(.black))
                .oneWayReadableText(.body)
                .lineLimit(1)
            Text(asset.mediaType == .video ? (asset.processingStatus == .ready ? "Video ready" : "Processing video...") : (asset.altText.isEmpty ? "Alt text needed" : "Alt text ready"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(asset.processingStatus == .ready ? (asset.altText.isEmpty && asset.mediaType == .image ? .orange : .green) : .orange)
            Button("Insert") {
                if let target = viewModel.insertionTarget(for: draft, pageIndex: selectedPageIndex, sectionIndex: selectedSectionIndex) {
                    draft = viewModel.insertMediaComponent(asset, into: draft, target: target)
                    selectedComponentForPlacement = viewModel.components(in: draft, pageIndex: selectedPageIndex, sectionIndex: selectedSectionIndex).last(where: { $0.assetID == asset.id })
                }
            }
            .font(.caption.weight(.black))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(OneWayCallTheme.purple, in: Capsule())
        }
        .frame(width: 144)
        .padding(10)
        .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private func importPhotoItems(_ items: [PhotosPickerItem], mediaType: SiteMediaType) async {
        print("SITE_MEDIA_PICKER_DISMISSED mediaType=\(mediaType.rawValue) sourceType=PHOTOS")
        await MainActor.run {
            isUploadingMedia = true
            uploadStatusText = "Preparing media..."
        }
        defer { Task { @MainActor in isUploadingMedia = false } }
        for item in items {
            do {
                print("SITE_MEDIA_PICKED siteId=\(draft.id.uuidString) mediaType=\(mediaType.rawValue) sourceType=PHOTOS")
                guard let picked = try await item.loadTransferable(type: SitePickedMediaFile.self) else { throw CocoaError(.fileReadUnknown) }
                let prepared = try preparePickedFile(picked.fileURL, mediaType: mediaType, sourceType: "PHOTOS")
                try await uploadAndInsert(prepared: prepared, mediaType: mediaType, sourceType: "PHOTOS")
                try? FileManager.default.removeItem(at: prepared.url)
            } catch {
                await MainActor.run {
                    viewModel.publishMessage = "Media upload failed: \(error.localizedDescription)"
                    uploadStatusText = "Upload failed"
                    print("SITE_MEDIA_UPLOAD_REQUEST_FAILED siteId=\(draft.id.uuidString) mediaType=\(mediaType.rawValue) sourceType=PHOTOS failureCode=\(String(describing: error))")
                }
            }
        }
        await MainActor.run {
            photoItems = []
            videoItems = []
        }
    }

    private func importFiles(_ result: Result<[URL], Error>, mediaType: SiteMediaType) async {
        await MainActor.run { isUploadingMedia = true }
        defer { Task { @MainActor in isUploadingMedia = false } }
        do {
            let urls = try result.get()
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                print("SITE_MEDIA_PICKED siteId=\(draft.id.uuidString) mediaType=\(mediaType.rawValue) sourceType=FILES")
                let prepared = try preparePickedFile(url, mediaType: mediaType, sourceType: "FILES")
                try await uploadAndInsert(prepared: prepared, mediaType: mediaType, sourceType: "FILES")
                try? FileManager.default.removeItem(at: prepared.url)
            }
        } catch let error as CocoaError where error.code == .userCancelled {
            print("SITE_MEDIA_PICKER_DISMISSED mediaType=\(mediaType.rawValue) sourceType=FILES cancellation=true")
        } catch {
            await MainActor.run { viewModel.publishMessage = "Media upload failed: \(error.localizedDescription)" }
        }
    }

    private func handleCameraResult(_ result: Result<SiteCameraCaptureResult, Error>, mediaType: SiteMediaType) async {
        print("SITE_MEDIA_PICKER_DISMISSED mediaType=\(mediaType.rawValue) sourceType=CAMERA")
        await MainActor.run { isUploadingMedia = true }
        defer { Task { @MainActor in isUploadingMedia = false } }
        do {
            let capture = try result.get()
            let prepared = try preparePickedFile(capture.fileURL, mediaType: mediaType, sourceType: "CAMERA", fallbackMimeType: capture.mimeType)
            try await uploadAndInsert(prepared: prepared, mediaType: mediaType, sourceType: "CAMERA")
            try? FileManager.default.removeItem(at: capture.fileURL)
        } catch let error as CocoaError where error.code == .userCancelled {
            print("SITE_MEDIA_PICKER_DISMISSED mediaType=\(mediaType.rawValue) sourceType=CAMERA cancellation=true")
        } catch {
            await MainActor.run { viewModel.publishMessage = "Camera capture failed: \(error.localizedDescription)" }
        }
    }

    private func copyToAppTemporaryStorage(_ sourceURL: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneway-site-media-\(UUID().uuidString)")
            .appendingPathExtension(sourceURL.pathExtension)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        guard FileManager.default.fileExists(atPath: destination.path),
              (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return destination
    }

    private func preparePickedFile(_ sourceURL: URL, mediaType: SiteMediaType, sourceType: String, fallbackMimeType: String? = nil) throws -> SitePreparedMediaFile {
        print("SITE_MEDIA_LOCAL_COPY_STARTED siteId=\(draft.id.uuidString) mediaType=\(mediaType.rawValue) sourceType=\(sourceType)")
        let tempURL = try copyToAppTemporaryStorage(sourceURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let signatureMime = detectedMimeType(for: tempURL, fallback: fallbackMimeType)
        guard byteCount > 0 else { throw CocoaError(.fileReadUnknown) }
        print("SITE_MEDIA_LOCAL_COPY_SUCCEEDED siteId=\(draft.id.uuidString) mediaType=\(mediaType.rawValue) sourceType=\(sourceType) localFileExists=true byteCount=\(byteCount) mimeType=\(signatureMime)")
        return SitePreparedMediaFile(url: tempURL, fileName: tempURL.lastPathComponent, mimeType: signatureMime, byteCount: byteCount)
    }

    private func uploadAndInsert(prepared: SitePreparedMediaFile, mediaType: SiteMediaType, sourceType: String) async throws {
        guard let target = await MainActor.run(body: { viewModel.insertionTarget(for: draft, pageIndex: selectedPageIndex, sectionIndex: selectedSectionIndex) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        await MainActor.run { uploadStatusText = "Uploading \(mediaType == .video ? "video" : "image")..." }
        let uploaded = try await mediaUploadService.uploadMedia(
            site: draft,
            fileURL: prepared.url,
            fileName: prepared.fileName,
            mimeType: prepared.mimeType,
            mediaType: mediaType,
            altText: imageAltText,
            caption: imageCaption,
            sourceType: sourceType,
            target: target
        )
        await MainActor.run {
            uploadStatusText = "Saving placement..."
            draft = viewModel.saveUploadedMediaAsset(uploaded, to: draft)
            draft = viewModel.insertMediaComponent(uploaded, into: draft, target: target)
            selectedComponentForPlacement = viewModel.components(in: draft, pageIndex: selectedPageIndex, sectionIndex: selectedSectionIndex).last(where: { $0.assetID == uploaded.id })
            print("SITE_MEDIA_DRAFT_SAVE_SUCCEEDED siteId=\(draft.id.uuidString) pageId=\(target.pageId.uuidString) sectionId=\(target.sectionId.uuidString) assetId=\(uploaded.id.uuidString) mediaType=\(mediaType.rawValue) processingStatus=\(uploaded.processingStatus.rawValue)")
        }
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        default: return "image/jpeg"
        }
    }

    private func detectedMimeType(for url: URL, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty { return fallback }
        if let handle = try? FileHandle(forReadingFrom: url) {
            let data = handle.readData(ofLength: 16)
            try? handle.close()
            let bytes = [UInt8](data)
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
            if bytes.count > 11, String(bytes: bytes[4..<12], encoding: .ascii)?.contains("ftyp") == true {
                let brand = String(bytes: bytes.dropFirst(8).prefix(4), encoding: .ascii)?.lowercased() ?? ""
                if brand.contains("heic") || brand.contains("heif") { return "image/heic" }
                if url.pathExtension.lowercased() == "mov" { return "video/quicktime" }
                if url.pathExtension.lowercased() == "m4v" { return "video/x-m4v" }
                return "video/mp4"
            }
            if bytes.count > 12,
               String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
               String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
                return "image/webp"
            }
        }
        return mimeType(for: url)
    }

    private func moveComponent(_ component: SiteComponent, delta: Int) -> OneWayBuilderSite {
        guard draft.pages.indices.contains(selectedPageIndex),
              draft.pages[selectedPageIndex].sections.indices.contains(selectedSectionIndex) else { return draft }
        let section = draft.pages[selectedPageIndex].sections[selectedSectionIndex]
        let components = viewModel.components(in: draft, pageIndex: selectedPageIndex, sectionIndex: selectedSectionIndex)
        guard let current = components.firstIndex(where: { $0.id == component.id }) else { return draft }
        let nextIndex = min(max(current + delta, 0), max(components.count - 1, 0))
        let target = SiteMediaInsertionTarget(siteId: draft.id, pageId: draft.pages[selectedPageIndex].id, sectionId: section.id, insertionIndex: nextIndex)
        return viewModel.moveComponent(component.id, in: draft, to: target)
    }

    private func iconTopButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .frame(width: 34, height: 34)
                .background(OneWayCallTheme.lavenderSurface, in: Circle())
                .overlay(Circle().stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func labeledBuilderAction(_ title: String, _ icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.headline.weight(.black))
                Text(title)
                    .font(.caption2.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(primary ? .white : OneWayCallTheme.purple)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(primary ? AnyShapeStyle(OneWayCallTheme.purpleGradient) : AnyShapeStyle(OneWayCallTheme.lavenderSurface), in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

private struct SiteMediaThumbnail: View {
    let asset: SiteMediaAsset

    var body: some View {
        Group {
            if let image = dataImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let urlString = asset.previewURLString,
                      let url = URL(string: urlString),
                      url.scheme?.hasPrefix("http") == true {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipped()
    }

    private var dataImage: UIImage? {
        guard let url = asset.previewURLString,
              url.starts(with: "data:image"),
              let range = url.range(of: "base64,"),
              let data = Data(base64Encoded: String(url[range.upperBound...])) else { return nil }
        return UIImage(data: data)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [OneWayCallTheme.purple.opacity(0.8), OneWayCallTheme.lavenderSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
            OneWayResolvedIcon(systemName: "photo")
                .font(.title.weight(.black))
                .foregroundStyle(.white)
        }
    }
}

private struct SitePreparedMediaFile {
    let url: URL
    let fileName: String
    let mimeType: String
    let byteCount: Int
}

private struct SitePickedMediaFile: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .item) { media in
            SentTransferredFile(media.fileURL)
        } importing: { received in
            let original = received.file
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("oneway-picked-\(UUID().uuidString)")
                .appendingPathExtension(original.pathExtension.isEmpty ? "bin" : original.pathExtension)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: original, to: destination)
            return SitePickedMediaFile(fileURL: destination)
        }
    }
}

private struct SiteComponentsPlacementList: View {
    let site: OneWayBuilderSite
    let section: SiteSection
    let assets: [SiteMediaAsset]
    let onSelect: (SiteComponent) -> Void
    let onMoveUp: (SiteComponent) -> Void
    let onMoveDown: (SiteComponent) -> Void

    private var components: [SiteComponent] {
        (section.components ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                OneWayResolvedLabel("Placed Media", systemImage: "rectangle.3.group.fill")
                    .font(.subheadline.weight(.black))
                    .oneWayReadableText(.title)
                Spacer()
                Text("\(components.count)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayCallTheme.purple)
            }
            if components.isEmpty {
                Text("Upload media from this section or insert from the Site Media Library.")
                    .font(.caption.weight(.semibold))
                    .oneWayReadableText(.subtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(OneWayCallTheme.lavenderSurface, in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(components) { component in
                    let asset = component.assetID.flatMap { id in assets.first { $0.id == id } }
                    HStack(spacing: 10) {
                        if let asset {
                            SiteMediaThumbnail(asset: asset)
                                .frame(width: 56, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            OneWayResolvedIcon(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: 56, height: 42)
                                .background(OneWayCallTheme.lavenderSurface, in: RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset?.originalFileName ?? component.componentType.rawValue.capitalized)
                                .font(.caption.weight(.black))
                                .oneWayReadableText(.body)
                                .lineLimit(1)
                            Text("\(component.widthMode.rawValue) • \(component.alignment.rawValue) • \(component.fitMode.rawValue)")
                                .font(.caption2.weight(.bold))
                                .oneWayReadableText(.subtitle)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button { onMoveUp(component) } label: { OneWayResolvedIcon(systemName: "chevron.up") }
                        Button { onMoveDown(component) } label: { OneWayResolvedIcon(systemName: "chevron.down") }
                        Button("Edit") { onSelect(component) }
                            .font(.caption.weight(.black))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OneWayCallTheme.purple)
                    .padding(10)
                    .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(OneWayCallTheme.border, lineWidth: 1))
                }
            }
        }
        .padding(12)
        .background(OneWayCallTheme.lavenderSurface.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct SiteMediaPlacementEditor: View {
    let site: OneWayBuilderSite
    @State var component: SiteComponent
    let assets: [SiteMediaAsset]
    let onUpdate: (SiteComponent) -> Void
    let onMove: (SiteMediaInsertionTarget) -> Void
    let onDuplicate: (SiteMediaInsertionTarget) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var destinationPageID: UUID
    @State private var destinationSectionID: UUID
    @State private var destinationPosition: SitePlacementPosition = .end

    init(
        site: OneWayBuilderSite,
        component: SiteComponent,
        assets: [SiteMediaAsset],
        onUpdate: @escaping (SiteComponent) -> Void,
        onMove: @escaping (SiteMediaInsertionTarget) -> Void,
        onDuplicate: @escaping (SiteMediaInsertionTarget) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.site = site
        self._component = State(initialValue: component)
        self.assets = assets
        self.onUpdate = onUpdate
        self.onMove = onMove
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        let currentPage = site.pages.first(where: { page in page.sections.contains(where: { $0.id == component.sectionID }) }) ?? site.pages.first
        self._destinationPageID = State(initialValue: currentPage?.id ?? UUID())
        self._destinationSectionID = State(initialValue: component.sectionID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewCard
                    placementControls
                    locationControls
                    videoControls
                    actionControls
                }
                .padding(18)
                .padding(.bottom, 50)
            }
            .background(OneWayCallTheme.background.ignoresSafeArea())
            .navigationTitle("Media Placement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onUpdate(component)
                        dismiss()
                    }
                    .fontWeight(.black)
                }
            }
        }
    }

    private var asset: SiteMediaAsset? {
        component.assetID.flatMap { id in assets.first { $0.id == id } }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let asset {
                SiteMediaThumbnail(asset: asset)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                Text(asset.originalFileName)
                    .font(.headline.weight(.black))
                    .oneWayReadableText(.title)
            }
            Text("Edit where this media appears, how it sizes, and how it behaves after publishing.")
                .font(.subheadline.weight(.semibold))
                .oneWayReadableText(.subtitle)
        }
        .padding(16)
        .oneWayCallGlass(cornerRadius: 24)
    }

    private var placementControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layout")
                .font(.headline.weight(.black))
                .oneWayReadableText(.title)
            Picker("Width", selection: $component.widthMode) {
                ForEach(SiteComponentWidthMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Alignment", selection: $component.alignment) {
                ForEach(SiteComponentAlignment.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Height", selection: $component.heightMode) {
                ForEach(SiteComponentHeightMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Fit", selection: $component.fitMode) {
                ForEach(SiteComponentFitMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Position", selection: $component.cropPosition) {
                ForEach(SiteComponentCropPosition.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Role", selection: $component.role) {
                ForEach(SiteComponentRole.allCases) { Text($0.rawValue).tag($0) }
            }
            Slider(value: $component.focalPointX, in: 0...1) { Text("Focal X") }
            Slider(value: $component.focalPointY, in: 0...1) { Text("Focal Y") }
            Slider(value: $component.cornerRadius, in: 0...40) { Text("Corner Radius") }
            Toggle("Shadow", isOn: $component.shadowEnabled)
            Toggle("Border", isOn: $component.borderEnabled)
        }
        .pickerStyle(.menu)
        .padding(16)
        .oneWayCallGlass(cornerRadius: 22)
    }

    private var locationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move To")
                .font(.headline.weight(.black))
                .oneWayReadableText(.title)
            Picker("Page", selection: $destinationPageID) {
                ForEach(site.pages) { page in Text(page.title).tag(page.id) }
            }
            Picker("Section", selection: $destinationSectionID) {
                ForEach(site.pages.first(where: { $0.id == destinationPageID })?.sections ?? []) { section in
                    Text(section.title.isEmpty ? section.type.rawValue : section.title).tag(section.id)
                }
            }
            Picker("Position", selection: $destinationPosition) {
                ForEach(SitePlacementPosition.allCases) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Button("Move") {
                    onMove(targetForSelection())
                    dismiss()
                }
                Button("Duplicate") {
                    onDuplicate(targetForSelection())
                    dismiss()
                }
            }
            .font(.headline.weight(.black))
            .buttonStyle(.borderedProminent)
            .tint(OneWayCallTheme.purple)
        }
        .pickerStyle(.menu)
        .padding(16)
        .oneWayCallGlass(cornerRadius: 22)
    }

    @ViewBuilder
    private var videoControls: some View {
        if component.componentType == .video {
            VStack(alignment: .leading, spacing: 12) {
                Text("Video")
                    .font(.headline.weight(.black))
                    .oneWayReadableText(.title)
                Toggle("Show Controls", isOn: $component.showControls)
                Toggle("Autoplay", isOn: $component.autoplay)
                Toggle("Muted", isOn: $component.muted)
                Toggle("Loop", isOn: $component.loop)
                Text("Autoplay videos stay muted by default for browser compatibility.")
                    .font(.caption.weight(.semibold))
                    .oneWayReadableText(.subtitle)
            }
            .padding(16)
            .oneWayCallGlass(cornerRadius: 22)
        }
    }

    private var actionControls: some View {
        Button(role: .destructive) {
            onDelete()
            dismiss()
        } label: {
            OneWayResolvedLabel("Remove Block", systemImage: "trash.fill")
                .frame(maxWidth: .infinity)
        }
        .font(.headline.weight(.black))
        .padding()
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private func targetForSelection() -> SiteMediaInsertionTarget {
        let section = site.pages.first(where: { $0.id == destinationPageID })?.sections.first(where: { $0.id == destinationSectionID })
        let endIndex = section?.components?.count ?? 0
        let index: Int
        switch destinationPosition {
        case .beginning: index = 0
        case .end: index = endIndex
        }
        return SiteMediaInsertionTarget(siteId: site.id, pageId: destinationPageID, sectionId: destinationSectionID, insertionIndex: index)
    }
}

private enum SitePlacementPosition: String, CaseIterable, Identifiable {
    case beginning = "Beginning"
    case end = "End"

    var id: String { rawValue }
}

private enum SiteEditorFocusedField: String, Hashable {
    case siteName
    case aiInstruction
    case altText
    case caption
}

private enum SiteMediaSource: String {
    case photos = "PHOTOS"
    case files = "FILES"
    case camera = "CAMERA"
}

private struct SiteCameraRequest: Identifiable {
    let id = UUID()
    let mediaType: SiteMediaType
}

private struct SiteCameraCaptureResult {
    let fileURL: URL
    let fileName: String
    let mimeType: String
}

private struct SiteCameraCaptureView: UIViewControllerRepresentable {
    let mediaType: SiteMediaType
    let onComplete: (Result<SiteCameraCaptureResult, Error>) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        picker.mediaTypes = mediaType == .video ? [UTType.movie.identifier] : [UTType.image.identifier]
        if mediaType == .video {
            picker.cameraCaptureMode = .video
            picker.videoQuality = .typeMedium
            picker.videoMaximumDuration = 60
        } else {
            picker.cameraCaptureMode = .photo
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(mediaType: mediaType, onComplete: onComplete)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let mediaType: SiteMediaType
        let onComplete: (Result<SiteCameraCaptureResult, Error>) -> Void

        init(mediaType: SiteMediaType, onComplete: @escaping (Result<SiteCameraCaptureResult, Error>) -> Void) {
            self.mediaType = mediaType
            self.onComplete = onComplete
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) {
                self.onComplete(.failure(CocoaError(.userCancelled)))
            }
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            do {
                let result: SiteCameraCaptureResult
                if mediaType == .video {
                    guard let url = info[.mediaURL] as? URL else { throw CocoaError(.fileReadUnknown) }
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("oneway-camera-\(UUID().uuidString)")
                        .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                    result = SiteCameraCaptureResult(fileURL: destination, fileName: destination.lastPathComponent, mimeType: destination.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime")
                } else {
                    guard let image = info[.originalImage] as? UIImage,
                          let data = image.jpegData(compressionQuality: 0.88) else { throw CocoaError(.fileReadUnknown) }
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("oneway-camera-\(UUID().uuidString)")
                        .appendingPathExtension("jpg")
                    try data.write(to: destination, options: [.atomic])
                    result = SiteCameraCaptureResult(fileURL: destination, fileName: destination.lastPathComponent, mimeType: "image/jpeg")
                }
                picker.dismiss(animated: true) {
                    self.onComplete(.success(result))
                }
            } catch {
                picker.dismiss(animated: true) {
                    self.onComplete(.failure(error))
                }
            }
        }
    }
}

private struct SiteSectionImageEditor: View {
    let site: OneWayBuilderSite
    @Binding var section: SiteSection
    let assets: [SiteMediaAsset]
    let onRemove: (UUID) -> Void
    let onAutosave: () -> Void

    private var selectedAssets: [SiteMediaAsset] {
        let ids = section.imageAssetIDs ?? []
        return ids.compactMap { id in assets.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OneWayResolvedLabel("Image Placement", systemImage: "crop")
                .font(.headline.weight(.black))
                .oneWayReadableText(.title)

            if selectedAssets.isEmpty {
                Text("Insert images from the Site Media panel. The section stores asset references and presentation settings, not image binaries.")
                    .font(.caption.weight(.semibold))
                    .oneWayReadableText(.subtitle)
            } else {
                ForEach(selectedAssets) { asset in
                    HStack(spacing: 10) {
                        SiteMediaThumbnail(asset: asset)
                            .frame(width: 72, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(asset.originalFileName)
                                .font(.caption.weight(.black))
                                .oneWayReadableText(.body)
                                .lineLimit(1)
                            Text(asset.caption.isEmpty ? asset.mimeType : asset.caption)
                                .font(.caption2.weight(.bold))
                                .oneWayReadableText(.subtitle)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) { onRemove(asset.id) } label: {
                            OneWayResolvedIcon(systemName: "trash.fill")
                        }
                    }
                }
                imagePresentationControls
            }
        }
        .padding(12)
        .background(OneWayCallTheme.lavenderSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private var imagePresentationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Crop", selection: Binding(
                get: { section.imagePresentation?.cropMode ?? .fill },
                set: { mode in
                    var presentation = section.imagePresentation ?? SiteImagePresentation()
                    presentation.cropMode = mode
                    section.imagePresentation = presentation
                    onAutosave()
                }
            )) {
                ForEach(SiteImageCropMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Corner Radius").font(.caption.weight(.bold))
                Slider(value: Binding(
                    get: { section.imagePresentation?.cornerRadius ?? 24 },
                    set: { value in
                        var presentation = section.imagePresentation ?? SiteImagePresentation()
                        presentation.cornerRadius = value
                        section.imagePresentation = presentation
                        onAutosave()
                    }
                ), in: 0...40)
            }

            HStack {
                Text("Opacity").font(.caption.weight(.bold))
                Slider(value: Binding(
                    get: { section.imagePresentation?.opacity ?? 1 },
                    set: { value in
                        var presentation = section.imagePresentation ?? SiteImagePresentation()
                        presentation.opacity = value
                        section.imagePresentation = presentation
                        onAutosave()
                    }
                ), in: 0.35...1)
            }
        }
    }
}

private struct SitePublishReviewSheet: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    let site: OneWayBuilderSite
    let onPublish: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pre-Publish Review")
                        .font(.largeTitle.weight(.black))
                        .oneWayReadableText(.title)
                    reviewRow("Site", site.name)
                    reviewRow("Address", site.publicAddress ?? "oneway://site/\(slug(site.name))")
                    reviewRow("Pages", "\(site.pages.count)")
                    reviewRow("Images", "\(viewModel.mediaAssets(for: site).count)")
                    reviewRow("Visibility", (site.visibility ?? .public).rawValue)

                    if !viewModel.publishWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            OneWayResolvedLabel("Accessibility Warnings", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline.weight(.black))
                                .foregroundStyle(.orange)
                            ForEach(viewModel.publishWarnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.caption.weight(.semibold))
                                    .oneWayReadableText(.subtitle)
                            }
                        }
                        .padding(14)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    }

                    Button(action: onPublish) {
                        OneWayResolvedLabel("Publish to OneWay Internet", systemImage: "icloud.and.arrow.up.fill")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(OneWayCallTheme.purpleGradient, in: Capsule())
                    }
                }
                .padding(18)
            }
            .background(OneWayCallTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func reviewRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.bold)).oneWayReadableText(.subtitle)
            Spacer()
            Text(value).font(.subheadline.weight(.black)).oneWayReadableText(.body)
        }
        .padding(14)
        .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private func slug(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private extension View {
    func siteTopButton() -> some View {
        font(.caption.weight(.black))
            .foregroundStyle(OneWayCallTheme.purple)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(OneWayCallTheme.lavenderSurface, in: Capsule())
            .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
    }
}
