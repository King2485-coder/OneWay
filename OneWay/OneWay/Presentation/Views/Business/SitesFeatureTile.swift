import SwiftUI
import UIKit

enum SitesFeatureKind: String {
    case aiBuilder
    case templates
    case domains
    case analytics

    var title: String {
        switch self {
        case .aiBuilder: return "AI Builder"
        case .templates: return "Templates"
        case .domains: return "Domains"
        case .analytics: return "Analytics"
        }
    }

    var subtitle: String {
        switch self {
        case .aiBuilder: return "Build an entire professional website with one prompt."
        case .templates: return "247 Templates Available"
        case .domains: return "SSL Active • 4 Connected"
        case .analytics: return "1,842 visitors today"
        }
    }

    var actionTitle: String {
        switch self {
        case .aiBuilder: return "Start"
        case .templates: return "Browse"
        case .domains: return "Manage"
        case .analytics: return "Open"
        }
    }
}

struct SitesFeatureTile: View {
    let kind: SitesFeatureKind
    let cardWidth: CGFloat
    let action: () -> Void

    @State private var isPressed = false
    @State private var animateArtwork = false

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(tileBackground)
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(borderGradient, lineWidth: 1)
                RadialGradient(
                    colors: [OneWayCallTheme.purple.opacity(0.3), .clear],
                    center: .topTrailing,
                    startRadius: 8,
                    endRadius: 170
                )

                VStack(alignment: .leading, spacing: 8) {
                    artwork
                        .frame(height: min(104, max(78, cardWidth * 0.58)))
                        .frame(maxWidth: .infinity)
                        .scaleEffect(isPressed ? 1.03 : 1)
                    Spacer(minLength: 0)
                    Text(kind.title)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind.subtitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                            .fixedSize(horizontal: false, vertical: true)
                        actionPill
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(210, cardWidth * 1.48))
            .shadow(color: OneWayCallTheme.purple.opacity(isPressed ? 0.42 : 0.18), radius: isPressed ? 30 : 18, x: 0, y: isPressed ? 18 : 10)
            .scaleEffect(isPressed ? 1.018 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                animateArtwork = true
            }
        }
    }

    private var tileBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: 0x0A0615).opacity(0.98),
                Color(hex: 0x1A0D35).opacity(0.9),
                Color(hex: 0x080711).opacity(0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.12),
                OneWayCallTheme.purple.opacity(0.58),
                Color.white.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var artwork: some View {
        OneWayCinematicAssetView(
            asset: cinematicAsset,
            motion: .drift,
            intensity: animateArtwork ? 1 : 0.82
        )
        .padding(.horizontal, 4)
    }

    private var cinematicAsset: OneWayCinematicAsset {
        switch kind {
        case .aiBuilder, .templates, .domains:
            return .workspacePanels
        case .analytics:
            return .adsHologram
        }
    }

    private var actionPill: some View {
        HStack(spacing: 6) {
            Text(kind.actionTitle)
                .font(.caption2.weight(.black))
            OneWayResolvedIcon(systemName: "arrow.right")
                .font(.caption.weight(.black))
                .rotationEffect(.degrees(isPressed ? 18 : 0))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(OneWayCallTheme.purple.opacity(0.26), in: Capsule())
        .overlay(Capsule().stroke(OneWayCallTheme.purple.opacity(0.6), lineWidth: 1))
        .shadow(color: OneWayCallTheme.purple.opacity(0.35), radius: 12)
    }
}
