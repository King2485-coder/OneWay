import SwiftUI

struct SiteActivitySummaryView: View {
    let visitors: Int
    let leads: Int
    let forms: Int
    let sales: Int
    let onAnalytics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today")
                    .font(.title3.weight(.black))
                    .foregroundStyle(OneWayCallTheme.text)
                    .lineLimit(1)
                Spacer()
                Button("Analytics", action: onAnalytics)
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayCallTheme.purple)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                stat("Visitors", "\(visitors.formatted())", "person.2.fill")
                stat("Leads", "\(leads)", "envelope.fill")
                stat("Forms", "\(forms)", "tray.full.fill")
                stat("Sales", "\(sales)", "cart.fill")
            }
        }
        .padding(12)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 9) {
            OneWayResolvedIcon(systemName: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .frame(width: 26, height: 26)
                .background(OneWayCallTheme.lavenderSurface, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: 0xC8C1EA))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}
