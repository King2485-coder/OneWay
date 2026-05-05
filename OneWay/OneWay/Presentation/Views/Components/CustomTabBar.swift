import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum RootTab: String, CaseIterable, Identifiable {
    case chats = "Chats"
    case communities = "Communities"
    case calls = "Calls"
    case business = "Business"
    case browser = "Web"
    case settings = "Settings"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .calls:
            return "phone.fill"
        case .communities:
            return "person.3.fill"
        case .chats:
            return "bubble.left.fill"
        case .business:
            return "briefcase.fill"
        case .browser:
            return "globe"
        case .settings:
            return "gearshape.fill"
        }
    }
}

struct CustomTabBar: View {
    @Binding var selection: RootTab
    @Binding var tabOrder: [RootTab]
    @State private var draggingTab: RootTab?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color.black.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 1)
                )
                .shadow(color: Theme.glassShadow, radius: 18, x: 0, y: 8)

            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    ImagePaint(
                        image: Image("planeWatermark"),
                        sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                        scale: 0.35
                    )
                )
                .opacity(0.1)
                .blendMode(.screen)
                .allowsHitTesting(false)

            HStack {
                ForEach(tabOrder) { tab in
                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.76)) {
                            selection = tab
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.symbolName)
                                .font(.system(size: 20, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(selection == tab ? Color.white.opacity(1.0) : Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .scaleEffect(selection == tab ? 1.1 : 1.0)
                        .overlay(alignment: .center) {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Theme.accentGradient)
                                    .frame(width: 36, height: 30)
                                    .blur(radius: 13)
                                    .opacity(0.55)
                                    .offset(y: -7)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .onDrag {
                        draggingTab = tab
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        return NSItemProvider(object: tab.rawValue as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: TabReorderDropDelegate(
                            targetTab: tab,
                            tabOrder: $tabOrder,
                            draggingTab: $draggingTab
                        )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: 80)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct TabReorderDropDelegate: DropDelegate {
    let targetTab: RootTab
    @Binding var tabOrder: [RootTab]
    @Binding var draggingTab: RootTab?

    func dropEntered(info: DropInfo) {
        guard let draggingTab,
              draggingTab != targetTab,
              let fromIndex = tabOrder.firstIndex(of: draggingTab),
              let toIndex = tabOrder.firstIndex(of: targetTab) else { return }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            tabOrder.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTab = nil
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
