import SwiftUI

struct SiteDashboardHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OneWay Sites")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .oneWayReadableText(.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text("Manage your websites.")
                    .font(.system(size: 15, weight: .semibold))
                    .oneWayReadableText(.subtitle)
                    .lineLimit(2)
            }
            .layoutPriority(1)
            Spacer()
            OneWayCinematicAssetView(
                asset: .workspacePanels,
                motion: .drift,
                intensity: 0.84
            )
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
            OneWayResolvedIcon(systemName: "ellipsis")
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .frame(width: 38, height: 38)
                .background(OneWayCallTheme.surface, in: Circle())
                .overlay(Circle().stroke(OneWayCallTheme.border, lineWidth: 1))
        }
    }
}
