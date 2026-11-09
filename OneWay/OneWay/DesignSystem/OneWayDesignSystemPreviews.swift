import SwiftUI

struct OneWayDesignSystemCatalogView: View {
    @State private var fieldText = "OneWay"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OneWayDS.Spacing.sectionSpacing) {
                OneWayNavigationBar(title: "Design System", subtitle: "OneWay 1.0", onBack: nil) {
                    OneWayCoreView(state: .protected, size: 44, accessibilityLabel: "Protected Core")
                }

                section("OneWay Core") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 12)], spacing: 12) {
                        ForEach(OneWayCoreState.allCases) { state in
                            VStack(spacing: 8) {
                                OneWayCoreView(state: state, size: 58, accessibilityLabel: state.rawValue)
                                Text(state.rawValue.capitalized)
                                    .font(OneWayDS.Typography.metadata)
                                    .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.68)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                section("Cards") {
                    OneWaySignatureCard(variant: .hero, status: .active) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Signature Hero")
                                .font(OneWayDS.Typography.cardTitle)
                                .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                            Text("Asymmetric, glass, luminous, unmistakably OneWay.")
                                .font(OneWayDS.Typography.body)
                                .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        OneWayStatusCard(title: "Available", value: "$2,438.28", subtitle: "Ready", status: .available, icon: "checkmark.circle.fill")
                        OneWayStatusCard(title: "Pending", value: "$128.45", subtitle: "Settling", status: .pending, icon: "clock.fill")
                    }
                }

                section("Buttons") {
                    Button("Primary Action") {}
                        .buttonStyle(OneWayPrimaryButtonStyle())
                    Button("Secondary Action") {}
                        .buttonStyle(OneWaySecondaryButtonStyle())
                    Button("Destructive Action") {}
                        .buttonStyle(OneWayDestructiveButtonStyle())
                    HStack {
                        OneWayActionTile(title: "Send", icon: "paperplane.fill") {}
                        OneWayActionTile(title: "Receive", icon: "arrow.down.left.circle.fill", status: .available) {}
                    }
                }

                section("Rows And Forms") {
                    OneWayTextField(title: "Name", placeholder: "Enter name", text: $fieldText)
                    OneWayNavigationRow(icon: "lock.shield.fill", title: "Security", subtitle: "Protected by OneWay", status: .secure) {}
                    OneWayNavigationRow(icon: "wifi.slash", title: "Offline", subtitle: "Try again when connected", status: .offline) {}
                }

                section("States") {
                    OneWayEmptyState(icon: "sparkles", title: "Nothing here yet", message: "Useful content will appear after activity begins.", actionTitle: "Start") {}
                    OneWayErrorState(title: "Server unavailable", message: "Your data is safe. Try again in a moment.", status: .warning) {}
                    OneWaySkeletonCard()
                }
            }
            .padding(OneWayDS.Spacing.screenPadding)
        }
        .background(
            LinearGradient(colors: [OneWayDS.ColorToken.backgroundPrimary, OneWayDS.ColorToken.backgroundSecondary, OneWayDS.ColorToken.oneWayPurpleDeep], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OneWayDS.Spacing.md) {
            Text(title)
                .font(OneWayDS.Typography.sectionTitle)
                .foregroundStyle(OneWayDS.ColorToken.textPrimary)
            content()
        }
    }
}

#Preview("OneWay Design System 1.0") {
    OneWayDesignSystemCatalogView()
}

#Preview("OneWay Design System - Accessibility Size") {
    OneWayDesignSystemCatalogView()
        .environment(\.dynamicTypeSize, .accessibility3)
}
