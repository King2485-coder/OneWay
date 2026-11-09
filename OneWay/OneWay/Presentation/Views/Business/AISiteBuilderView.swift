import SwiftUI

struct AISiteBuilderView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    let onGenerated: (OneWayBuilderSite) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var answers: [String: String] = [:]
    @State private var questions: [AISiteInterviewQuestion] = []
    @State private var stage: Stage = .prompt
    @State private var generatedSite: OneWayBuilderSite?
    @State private var previewMode: SitePreviewMode = .mobile

    private enum Stage: Hashable {
        case prompt
        case interview
        case generating
        case result
    }

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MarketplaceBackBar(title: "Build with OneWay AI") { dismiss() } trailing: { EmptyView() }
                    progressHeader
                    stageContent
                }
                .padding(18)
                .padding(.bottom, 120)
            }
        }
        .navigationBarHidden(true)
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .prompt:
            promptStage
        case .interview:
            interviewStage
        case .generating:
            generatingStage
        case .result:
            resultStage
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach([Stage.prompt, .interview, .generating, .result], id: \.self) { item in
                    Capsule()
                        .fill(progressColor(for: item))
                        .frame(height: 7)
                }
            }
            Text(headerTitle)
                .font(.system(size: 27, weight: .black, design: .rounded))
                .oneWayReadableText(.title)
                .fixedSize(horizontal: false, vertical: true)
            Text(headerSubtitle)
                .font(.subheadline.weight(.semibold))
                .oneWayReadableText(.subtitle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .frame(minHeight: 142)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(OneWayCallTheme.border, lineWidth: 1))
                    .oneWayReadableText(.body)
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Example: Build a trucking company website for nationwide freight with quote requests, service areas, and a professional black and gold look.")
                        .font(.subheadline.weight(.semibold))
                        .oneWayReadableText(.muted)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }

            quickPrompts

            Button {
                let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                prompt = cleanPrompt.isEmpty ? "Build a professional service business website." : cleanPrompt
                questions = viewModel.interviewQuestions(for: prompt)
                stage = .interview
            } label: {
                OneWayResolvedLabel("Start AI Interview", systemImage: "sparkles")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(OneWayCallTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        }
    }

    private var quickPrompts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One-tap starts")
                .font(.caption.weight(.black))
                .oneWayReadableText(.muted)
            ForEach([
                "Build a trucking company site with quote requests and service areas.",
                "Build a restaurant site with menu, catering, and reservations.",
                "Build an online store with featured products and secure checkout.",
                "Build a nonprofit site with donation and volunteer pages."
            ], id: \.self) { sample in
                Button {
                    prompt = sample
                    questions = viewModel.interviewQuestions(for: sample)
                    stage = .interview
                } label: {
                    HStack {
                        OneWayResolvedIcon(systemName: "plus.circle.fill")
                            .foregroundStyle(OneWayCallTheme.purple)
                        Text(sample)
                            .font(.subheadline.weight(.bold))
                            .oneWayReadableText(.body)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(12)
                    .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(OneWayCallTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var interviewStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(questions.enumerated()), id: \.element.id) { _, question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.title)
                        .font(.caption.weight(.black))
                        .oneWayReadableText(.title)
                    TextField(question.placeholder, text: Binding(
                        get: { answers[question.title] ?? "" },
                        set: { answers[question.title] = $0 }
                    ), axis: question.title.contains("know") ? .vertical : .horizontal)
                    .lineLimit(question.title.contains("know") ? 5 : 1)
                    .textInputAutocapitalization(.words)
                    .oneWayLightFieldStyle()
                }
            }

            HStack(spacing: 10) {
                Button("Back") { stage = .prompt }
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayCallTheme.purple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(OneWayCallTheme.lavenderSurface, in: RoundedRectangle(cornerRadius: 16))
                Button {
                    stage = .generating
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        generatedSite = viewModel.generateSiteFromPrompt(prompt, answers: answers)
                        stage = .result
                    }
                } label: {
                    OneWayResolvedLabel("Generate Website", systemImage: "wand.and.stars")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OneWayCallTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var generatingStage: some View {
        VStack(spacing: 18) {
            ProgressView()
                .scaleEffect(1.35)
                .tint(OneWayCallTheme.purple)
            Text("OneWay AI is building pages, copy, forms, SEO, image direction, and publishing checks.")
                .font(.headline.weight(.bold))
                .oneWayReadableText(.title)
                .multilineTextAlignment(.center)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                generationChip("Pages", "doc.text.fill")
                generationChip("SEO", "magnifyingglass")
                generationChip("Forms", "tray.full.fill")
                generationChip("Mobile", "iphone")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .oneWayCallGlass(cornerRadius: 24)
    }

    private var resultStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let site = generatedSite {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(site.name)
                            .font(.title2.weight(.black))
                            .oneWayReadableText(.title)
                        Text("\(site.pages.count) pages • \(site.pages.reduce(0) { $0 + $1.sections.count }) sections • SEO ready")
                            .font(.caption.weight(.bold))
                            .oneWayReadableText(.subtitle)
                    }
                    Spacer()
                    statusPill("Draft", icon: "doc.badge.gearshape.fill")
                }

                Picker("Preview", selection: $previewMode) {
                    ForEach(SitePreviewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                SiteRendererView(site: site, mode: previewMode)
                    .frame(maxWidth: previewMode == .mobile ? 390 : (previewMode == .tablet ? 720 : .infinity))
                    .frame(height: previewMode == .desktop ? 620 : 560)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(OneWayCallTheme.border, lineWidth: 1))

                resultActions(site)
                generationSummary(site)
            }
        }
    }

    private func resultActions(_ site: OneWayBuilderSite) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            actionButton("Edit Site", "pencil", primary: true) { onGenerated(site) }
            actionButton("Preview", "eye.fill") { onGenerated(site) }
            actionButton("Ask AI", "sparkles") {
                prompt = "Improve \(site.name)"
                stage = .prompt
            }
            actionButton("Publish", "icloud.and.arrow.up.fill") {
                if viewModel.publish(site), let updated = viewModel.site(site.id) {
                    generatedSite = updated
                }
            }
        }
    }

    private func generationSummary(_ site: OneWayBuilderSite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            OneWayResolvedLabel("Generated Website Package", systemImage: "checkmark.seal.fill")
                .font(.headline.weight(.black))
                .oneWayReadableText(.title)
            ForEach([
                "\(site.pages.count) responsive pages",
                "Contact, quote, booking, or lead capture blocks where relevant",
                "SEO title and description",
                "Domain and SSL publish checklist",
                "Editable sections, pages, colors, copy, and calls to action"
            ], id: \.self) { item in
                OneWayResolvedLabel(item, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .oneWayReadableText(.subtitle)
            }
        }
        .padding(16)
        .oneWayCallGlass(cornerRadius: 20)
    }

    private func generationChip(_ title: String, _ icon: String) -> some View {
        OneWayResolvedLabel(title, systemImage: icon)
            .font(.caption.weight(.black))
            .foregroundStyle(OneWayCallTheme.purple)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(OneWayCallTheme.lavenderSurface, in: Capsule())
    }

    private func actionButton(_ title: String, _ icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedLabel(title, systemImage: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(primary ? .white : OneWayCallTheme.purple)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(primary ? AnyShapeStyle(OneWayCallTheme.purpleGradient) : AnyShapeStyle(OneWayCallTheme.lavenderSurface), in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }

    private func statusPill(_ title: String, icon: String) -> some View {
        OneWayResolvedLabel(title, systemImage: icon)
            .font(.caption2.weight(.black))
            .foregroundStyle(OneWayCallTheme.purple)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(OneWayCallTheme.lavenderSurface, in: Capsule())
    }

    private func progressColor(for item: Stage) -> Color {
        let order: [Stage] = [.prompt, .interview, .generating, .result]
        guard let current = order.firstIndex(of: stage), let index = order.firstIndex(of: item) else { return OneWayCallTheme.border }
        return index <= current ? OneWayCallTheme.purple : OneWayCallTheme.border
    }

    private var headerTitle: String {
        switch stage {
        case .prompt: return "Describe the website"
        case .interview: return "Answer the important questions"
        case .generating: return "Building the full site"
        case .result: return "Your website is ready to improve"
        }
    }

    private var headerSubtitle: String {
        switch stage {
        case .prompt: return "Start with plain language. OneWay will infer the industry and needed pages."
        case .interview: return "Only the useful details are needed. Blank answers are okay."
        case .generating: return "Creating pages, sections, forms, SEO, and a publish-ready draft."
        case .result: return "Preview by device, edit sections, ask AI for changes, or publish when checks pass."
        }
    }
}
