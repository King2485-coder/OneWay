import SwiftUI

enum OneWayCinematicAsset: String, CaseIterable, Identifiable {
    case quantumSphere
    case oneWayCore
    case workspacePanels
    case adsHologram
    case cloudCube
    case protectionShield

    var id: String { rawValue }

    var imageName: String {
        switch self {
        case .quantumSphere: return "OneWaySculptedQuantum"
        case .oneWayCore: return "OneWaySculptedCreate"
        case .workspacePanels: return "OneWaySculptedWorkspace"
        case .adsHologram: return "OneWaySculptedAds"
        case .cloudCube: return "OneWaySculptedCloud"
        case .protectionShield: return "OneWaySculptedPrivacy"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .quantumSphere: return "Quantum"
        case .oneWayCore: return "Create"
        case .workspacePanels: return "Workspace"
        case .adsHologram: return "OneWay Ads"
        case .cloudCube: return "Cloud storage"
        case .protectionShield: return "Privacy shield"
        }
    }
}

enum OneWayCinematicMotion: Equatable {
    case none
    case breathe
    case orbital
    case drift
}

/// A lightweight host for pre-rendered cinematic assets. Motion is limited to
/// transforms and opacity so the assets remain inexpensive in scrolling views.
struct OneWayCinematicAssetView: View {
    let asset: OneWayCinematicAsset
    var motion: OneWayCinematicMotion = .breathe
    var intensity: Double = 1
    var contentMode: ContentMode = .fit

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ambientPhase = false

    var body: some View {
        Image(asset.imageName)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .blendMode(.screen)
            .saturation(0.92 + (0.08 * intensity))
            .contrast(1.02)
            .scaleEffect(assetScale)
            .rotationEffect(assetRotation)
            .rotation3DEffect(
                .degrees(assetTilt),
                axis: (x: 0.18, y: 1, z: 0),
                perspective: 0.35
            )
            .offset(y: assetOffset)
            .shadow(
                color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.16 * intensity),
                radius: 22,
                x: 0,
                y: 12
            )
            .accessibilityLabel(asset.accessibilityLabel)
            .onAppear {
                guard motion != .none, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: motionDuration).repeatForever(autoreverses: true)) {
                    ambientPhase = true
                }
            }
    }

    private var assetScale: CGFloat {
        guard !reduceMotion else { return 1 }
        switch motion {
        case .none: return 1
        case .breathe: return ambientPhase ? 1.018 : 0.992
        case .orbital: return ambientPhase ? 1.012 : 0.996
        case .drift: return ambientPhase ? 1.008 : 0.998
        }
    }

    private var assetRotation: Angle {
        guard !reduceMotion else { return .zero }
        switch motion {
        case .orbital: return .degrees(ambientPhase ? 0.8 : -0.8)
        default: return .zero
        }
    }

    private var assetTilt: Double {
        guard !reduceMotion else { return 0 }
        switch motion {
        case .orbital: return ambientPhase ? 1.4 : -1.4
        case .drift: return ambientPhase ? 0.8 : -0.8
        default: return 0
        }
    }

    private var assetOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        switch motion {
        case .drift, .orbital: return ambientPhase ? -2.5 : 2.5
        default: return 0
        }
    }

    private var motionDuration: Double {
        switch motion {
        case .none: return 0
        case .breathe: return 4.8
        case .orbital: return 8.5
        case .drift: return 6.4
        }
    }
}

struct OneWayCinematicGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var focused = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                shape
                    .fill(Color(hex: 0x0B0E1E).opacity(0.82))
                    .background(.ultraThinMaterial.opacity(0.28), in: shape)
                    .overlay {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.13),
                                Color.white.opacity(0.018),
                                OneWayDesignSystem.Colors.purpleGlow.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(shape)
                    }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            OneWayDesignSystem.Colors.purpleGlow.opacity(focused ? 0.70 : 0.38),
                            Color.white.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: focused ? 1.25 : 1
                )
            }
            .shadow(color: Color.black.opacity(0.42), radius: 24, x: 0, y: 15)
            .shadow(
                color: OneWayDesignSystem.Colors.purpleGlow.opacity(focused ? 0.24 : 0.12),
                radius: focused ? 26 : 18,
                x: 0,
                y: 10
            )
    }
}

struct OneWayMachinedGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? 0.04 : 0)
            .modifier(OneWayCinematicGlassModifier(cornerRadius: 18, focused: configuration.isPressed))
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

extension View {
    func oneWayCinematicGlass(cornerRadius: CGFloat = 24, focused: Bool = false) -> some View {
        modifier(OneWayCinematicGlassModifier(cornerRadius: cornerRadius, focused: focused))
    }
}
