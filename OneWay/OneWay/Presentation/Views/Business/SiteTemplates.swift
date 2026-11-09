import Foundation

enum SiteTemplates {
    static let all: [OneWaySiteTemplate] = [
        .init(name: "Modern Business", category: "Business", description: "Polished company site with services and contact.", primaryHex: "#111827", accentHex: "#7B3FF2"),
        .init(name: "Local Service", category: "Service", description: "Fast service-company layout for quotes and calls.", primaryHex: "#0F172A", accentHex: "#F59E0B"),
        .init(name: "Online Store", category: "Store", description: "Product-forward storefront with trust sections.", primaryHex: "#111827", accentHex: "#10B981"),
        .init(name: "Creator Portfolio", category: "Portfolio", description: "Editorial portfolio with gallery and bio.", primaryHex: "#18181B", accentHex: "#A855F7"),
        .init(name: "Restaurant", category: "Restaurant", description: "Menu, location, reservations, and reviews.", primaryHex: "#1F1308", accentHex: "#EF4444"),
        .init(name: "Real Estate", category: "Real Estate", description: "Listings, proof, and booking-focused pages.", primaryHex: "#0C1B2A", accentHex: "#38BDF8"),
        .init(name: "Logistics", category: "Logistics", description: "Freight, fleet, service lanes, and quote CTA.", primaryHex: "#111827", accentHex: "#FBBF24"),
        .init(name: "Nonprofit", category: "Nonprofit", description: "Mission, programs, donations, and impact.", primaryHex: "#10231A", accentHex: "#22C55E"),
        .init(name: "Personal Brand", category: "Personal Brand", description: "Simple authority site with newsletter.", primaryHex: "#171717", accentHex: "#7B3FF2"),
        .init(name: "Event Page", category: "Event", description: "Date, location, speakers, tickets, and FAQ.", primaryHex: "#170A2C", accentHex: "#EC4899")
    ]
}
