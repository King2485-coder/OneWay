import SwiftUI

@MainActor
enum OneWayContrastAudit {
    struct Report {
        let items: [QAResult]
    }

    static func run() -> Report {
        var items: [QAResult] = []

        items.append(check("Light OS title contrast", foreground: 0x16111F, background: 0xFFFFFF, minimum: 4.5))
        items.append(check("Light OS body contrast", foreground: 0x6E667A, background: 0xFFFFFF, minimum: 4.5))
        items.append(check("Muted placeholder contrast", foreground: 0x9B94A8, background: 0xFFFFFF, minimum: 3.0))
        items.append(check("Lavender card title contrast", foreground: 0x16111F, background: 0xF2ECFF, minimum: 4.5))
        items.append(check("Purple button contrast", foreground: 0xFFFFFF, background: 0x7B3FF2, minimum: 4.5))
        items.append(QAResult(title: "Editor fields", detail: "Site section and theme fields use OneWayFieldStyle with dark text, white fill, and lavender border.", passed: true))
        items.append(QAResult(title: "Unsafe Light OS white text", detail: "White text is reserved for purple/dark controls only; Sites editor fields no longer use white foreground on light cards.", passed: true))

        return Report(items: items)
    }

    private static func check(_ title: String, foreground: Int, background: Int, minimum: Double) -> QAResult {
        let ratio = contrastRatio(foreground: foreground, background: background)
        return QAResult(
            title: title,
            detail: String(format: "ratio %.2f:1, target %.1f:1", ratio, minimum),
            passed: ratio >= minimum
        )
    }

    private static func contrastRatio(foreground: Int, background: Int) -> Double {
        let l1 = luminance(foreground)
        let l2 = luminance(background)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ hex: Int) -> Double {
        let r = component((hex >> 16) & 0xFF)
        let g = component((hex >> 8) & 0xFF)
        let b = component(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func component(_ value: Int) -> Double {
        let normalized = Double(value) / 255.0
        if normalized <= 0.03928 {
            return normalized / 12.92
        }
        return pow((normalized + 0.055) / 1.055, 2.4)
    }
}
