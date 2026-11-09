import Foundation

enum SiteQualityValidator {
    static func validate(_ site: OneWayBuilderSite) -> SiteQualityReport {
        var issues: [String] = []
        let homeSections = site.pages.first?.sections ?? []
        let sectionTypes = Set(homeSections.map(\.type))

        require(!site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Site name is required.", into: &issues)
        require(site.pages.contains { $0.slug == "privacy-policy" || $0.title == "Privacy Policy" }, "Privacy Policy page is required.", into: &issues)
        require(site.pages.contains { $0.slug == "terms" || $0.title == "Terms" }, "Terms page is required.", into: &issues)
        require(site.pages.contains { $0.title == "404" || $0.slug == "404" }, "404 page is required.", into: &issues)
        require(sectionTypes.contains(.hero), "Hero section is required.", into: &issues)
        require(sectionTypes.contains(.about), "About section is required.", into: &issues)
        require(sectionTypes.contains(.services) || sectionTypes.contains(.productGrid), "Services or products section is required.", into: &issues)
        require(sectionTypes.contains(.testimonials), "Testimonials section is required.", into: &issues)
        require(sectionTypes.contains(.trustBadges), "Trust indicators are required.", into: &issues)
        require(sectionTypes.contains(.faq), "FAQ section is required.", into: &issues)
        require(sectionTypes.contains(.contactForm) || sectionTypes.contains(.booking), "Contact or booking form is required.", into: &issues)
        require(sectionTypes.contains(.footer), "Footer is required.", into: &issues)
        require(!site.seoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "SEO title is required.", into: &issues)
        require(site.seoDescription.count >= 80, "SEO description should be specific and at least 80 characters.", into: &issues)

        let emptySections = homeSections.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            $0.body.localizedCaseInsensitiveContains("add content here") ||
            $0.body.localizedCaseInsensitiveContains("lorem ipsum") ||
            $0.body.localizedCaseInsensitiveContains("sample text")
        }
        if !emptySections.isEmpty {
            issues.append("Every section must contain finished content.")
        }

        let criticalPenalty = min(30, issues.count * 4)
        let sectionBonus = min(8, homeSections.count)
        return SiteQualityReport(
            visualDesign: max(70, 94 + sectionBonus / 2 - criticalPenalty),
            content: max(70, 94 - criticalPenalty),
            responsiveness: max(72, 93 - min(12, issues.count * 2)),
            accessibility: max(74, 92 - min(10, issues.count * 2)),
            performance: 94,
            seo: max(72, 93 - min(18, issues.count * 3)),
            completeness: max(70, 96 - criticalPenalty),
            conversionReadiness: max(72, 94 - min(18, issues.count * 3)),
            criticalIssues: issues
        )
    }

    private static func require(_ condition: Bool, _ message: String, into issues: inout [String]) {
        if !condition {
            issues.append(message)
        }
    }
}
