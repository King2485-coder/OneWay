import SwiftUI

struct AvatarStudioView: View {
    @State private var skinTone: Double = 0.55
    @State private var eyeSize: Double = 0.52
    @State private var eyeSpacing: Double = 0.55
    @State private var browAngle: Double = 0.5
    @State private var noseWidth: Double = 0.45
    @State private var lipFullness: Double = 0.55
    @State private var jawWidth: Double = 0.62
    @State private var hairVolume: Double = 0.62
    @State private var beardAmount: Double = 0.2

    @State private var hairStyle: HairStyle = .waves
    @State private var hairColor: HairColor = .dark
    @State private var eyeColor: EyeColor = .brown
    @State private var mood: Mood = .friendly

    @State private var hasGlasses = true
    @State private var hasPiercing = false
    @State private var hasFreckles = false

    @State private var didSave = false
    @State private var didReset = false

    var body: some View {
        Form {
            Section("Human Avatar Preview") {
                HumanAvatarRenderer(
                    skinTone: skinTone,
                    eyeSize: eyeSize,
                    eyeSpacing: eyeSpacing,
                    browAngle: browAngle,
                    noseWidth: noseWidth,
                    lipFullness: lipFullness,
                    jawWidth: jawWidth,
                    hairVolume: hairVolume,
                    beardAmount: beardAmount,
                    hairStyle: hairStyle,
                    hairColor: hairColor,
                    eyeColor: eyeColor,
                    mood: mood,
                    hasGlasses: hasGlasses,
                    hasPiercing: hasPiercing,
                    hasFreckles: hasFreckles
                )
                .frame(height: 270)
                .padding(.vertical, 6)
            }

            Section("Identity") {
                Picker("Hair style", selection: $hairStyle) {
                    ForEach(HairStyle.allCases, id: \.self) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                Picker("Hair color", selection: $hairColor) {
                    ForEach(HairColor.allCases, id: \.self) { color in
                        Text(color.rawValue).tag(color)
                    }
                }
                Picker("Eye color", selection: $eyeColor) {
                    ForEach(EyeColor.allCases, id: \.self) { color in
                        Text(color.rawValue).tag(color)
                    }
                }
                Picker("Mood", selection: $mood) {
                    ForEach(Mood.allCases, id: \.self) { mood in
                        Text(mood.rawValue).tag(mood)
                    }
                }
            }

            Section("Face Geometry") {
                SliderRow(title: "Skin tone", value: $skinTone)
                SliderRow(title: "Eye size", value: $eyeSize)
                SliderRow(title: "Eye spacing", value: $eyeSpacing)
                SliderRow(title: "Brow angle", value: $browAngle)
                SliderRow(title: "Nose width", value: $noseWidth)
                SliderRow(title: "Lip fullness", value: $lipFullness)
                SliderRow(title: "Jaw width", value: $jawWidth)
                SliderRow(title: "Hair volume", value: $hairVolume)
                SliderRow(title: "Beard", value: $beardAmount)
            }

            Section("Details") {
                Toggle("Glasses", isOn: $hasGlasses)
                Toggle("Piercing", isOn: $hasPiercing)
                Toggle("Freckles", isOn: $hasFreckles)
            }

            Section("Actions") {
                Button("Randomize Human Avatar") {
                    randomize()
                }
                .buttonStyle(PrimaryPillButtonStyle())

                Button("Reset to Default") {
                    reset()
                    didReset = true
                }
                .buttonStyle(PrimaryPillButtonStyle())

                Button("Save Avatar") {
                    didSave = true
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .navigationTitle("Avatar Studio")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .alert("Avatar updated.", isPresented: $didSave) {
            Button("OK") {}
        }
        .alert("Avatar reset to defaults.", isPresented: $didReset) {
            Button("OK") {}
        }
    }

    private func reset() {
        skinTone = 0.55
        eyeSize = 0.52
        eyeSpacing = 0.55
        browAngle = 0.5
        noseWidth = 0.45
        lipFullness = 0.55
        jawWidth = 0.62
        hairVolume = 0.62
        beardAmount = 0.2
        hairStyle = .waves
        hairColor = .dark
        eyeColor = .brown
        mood = .friendly
        hasGlasses = true
        hasPiercing = false
        hasFreckles = false
    }

    private func randomize() {
        skinTone = .random(in: 0...1)
        eyeSize = .random(in: 0...1)
        eyeSpacing = .random(in: 0...1)
        browAngle = .random(in: 0...1)
        noseWidth = .random(in: 0...1)
        lipFullness = .random(in: 0...1)
        jawWidth = .random(in: 0...1)
        hairVolume = .random(in: 0...1)
        beardAmount = .random(in: 0...1)
        hairStyle = HairStyle.allCases.randomElement() ?? .waves
        hairColor = HairColor.allCases.randomElement() ?? .dark
        eyeColor = EyeColor.allCases.randomElement() ?? .brown
        mood = Mood.allCases.randomElement() ?? .friendly
        hasGlasses = Bool.random()
        hasPiercing = Bool.random()
        hasFreckles = Bool.random()
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

enum HairStyle: String, CaseIterable {
    case buzz = "Buzz"
    case fade = "Fade"
    case waves = "Waves"
    case curly = "Curly"
}

enum HairColor: String, CaseIterable {
    case dark = "Dark"
    case brown = "Brown"
    case auburn = "Auburn"
    case blonde = "Blonde"
    case silver = "Silver"

    var color: Color {
        switch self {
        case .dark: return Color(hex: 0x1C1B1A)
        case .brown: return Color(hex: 0x4B3327)
        case .auburn: return Color(hex: 0x7A3A2A)
        case .blonde: return Color(hex: 0xC7A66A)
        case .silver: return Color(hex: 0xAEB4BB)
        }
    }
}

enum EyeColor: String, CaseIterable {
    case brown = "Brown"
    case hazel = "Hazel"
    case green = "Green"
    case blue = "Blue"

    var color: Color {
        switch self {
        case .brown: return Color(hex: 0x4B2F21)
        case .hazel: return Color(hex: 0x7B6D38)
        case .green: return Color(hex: 0x2F6E4F)
        case .blue: return Color(hex: 0x2E5F90)
        }
    }
}

enum Mood: String, CaseIterable {
    case friendly = "Friendly"
    case focused = "Focused"
    case confident = "Confident"
    case playful = "Playful"
}

private struct HumanAvatarRenderer: View {
    let skinTone: Double
    let eyeSize: Double
    let eyeSpacing: Double
    let browAngle: Double
    let noseWidth: Double
    let lipFullness: Double
    let jawWidth: Double
    let hairVolume: Double
    let beardAmount: Double
    let hairStyle: HairStyle
    let hairColor: HairColor
    let eyeColor: EyeColor
    let mood: Mood
    let hasGlasses: Bool
    let hasPiercing: Bool
    let hasFreckles: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let faceW = size * (0.42 + jawWidth * 0.18)
            let faceH = size * 0.55
            let eyeY = size * 0.44
            let eyeGap = size * (0.08 + eyeSpacing * 0.12)
            let eyeR = size * (0.018 + eyeSize * 0.018)
            let skin = Color(hue: 0.09 + skinTone * 0.15, saturation: 0.36 + (1 - skinTone) * 0.12, brightness: 0.96)

            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .blur(radius: 16)
                    .frame(width: size * 0.85, height: size * 0.85)

                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(skin)
                    .frame(width: faceW, height: faceH)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )

                RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                    .fill(skin.opacity(0.96))
                    .frame(width: faceW * 0.34, height: faceH * 0.24)
                    .offset(y: faceH * 0.48)

                Circle()
                    .fill(skin)
                    .frame(width: size * 0.11, height: size * 0.11)
                    .offset(x: -faceW * 0.52, y: faceH * 0.02)
                Circle()
                    .fill(skin)
                    .frame(width: size * 0.11, height: size * 0.11)
                    .offset(x: faceW * 0.52, y: faceH * 0.02)

                hairLayer(size: size, faceW: faceW)
                    .foregroundStyle(hairColor.color)
                    .offset(y: -faceH * 0.33)

                Capsule()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: size * 0.09, height: size * 0.016)
                    .rotationEffect(.degrees(-24 + browAngle * 48))
                    .offset(x: -eyeGap, y: eyeY - size * 0.035)

                Capsule()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: size * 0.09, height: size * 0.016)
                    .rotationEffect(.degrees(24 - browAngle * 48))
                    .offset(x: eyeGap, y: eyeY - size * 0.035)

                Circle()
                    .fill(.white)
                    .frame(width: eyeR * 2.4, height: eyeR * 2.4)
                    .offset(x: -eyeGap, y: eyeY)
                Circle()
                    .fill(.white)
                    .frame(width: eyeR * 2.4, height: eyeR * 2.4)
                    .offset(x: eyeGap, y: eyeY)

                Circle()
                    .fill(eyeColor.color)
                    .frame(width: eyeR * 1.35, height: eyeR * 1.35)
                    .offset(x: -eyeGap, y: eyeY)
                Circle()
                    .fill(eyeColor.color)
                    .frame(width: eyeR * 1.35, height: eyeR * 1.35)
                    .offset(x: eyeGap, y: eyeY)

                RoundedRectangle(cornerRadius: size * 0.03, style: .continuous)
                    .fill(Color.black.opacity(0.2))
                    .frame(width: size * (0.02 + noseWidth * 0.03), height: size * 0.09)
                    .offset(y: size * 0.03)

                mouthLayer(size: size)
                    .offset(y: size * 0.15)

                if beardAmount > 0.15 {
                    Capsule()
                        .fill(hairColor.color.opacity(0.8))
                        .frame(width: size * (0.16 + beardAmount * 0.14), height: size * (0.03 + beardAmount * 0.04))
                        .offset(y: size * 0.21)
                }

                if hasFreckles {
                    ForEach(0..<10, id: \.self) { i in
                        Circle()
                            .fill(Color.black.opacity(0.15))
                            .frame(width: 2.2, height: 2.2)
                            .offset(x: CGFloat(i % 5) * 8 - 16, y: CGFloat(i / 5) * 7 + 18)
                    }
                }

                if hasGlasses {
                    HStack(spacing: size * 0.04) {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.black.opacity(0.58), lineWidth: 3)
                            .frame(width: size * 0.11, height: size * 0.08)
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.black.opacity(0.58), lineWidth: 3)
                            .frame(width: size * 0.11, height: size * 0.08)
                    }
                    .offset(y: eyeY)
                }

                if hasPiercing {
                    Circle()
                        .stroke(Color(hex: 0xF5C542), lineWidth: 2)
                        .frame(width: size * 0.032, height: size * 0.032)
                        .offset(x: faceW * 0.49, y: faceH * 0.06)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.divider, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func hairLayer(size: CGFloat, faceW: CGFloat) -> some View {
        switch hairStyle {
        case .buzz:
            Capsule()
                .frame(width: faceW * 0.85, height: size * (0.07 + hairVolume * 0.04))
        case .fade:
            RoundedRectangle(cornerRadius: size * 0.08)
                .frame(width: faceW * 0.92, height: size * (0.12 + hairVolume * 0.05))
        case .waves:
            ZStack {
                Capsule().frame(width: faceW * 0.94, height: size * (0.12 + hairVolume * 0.07))
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { _ in
                        Circle().frame(width: size * 0.07, height: size * 0.07)
                    }
                }
                .offset(y: size * 0.02)
            }
        case .curly:
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { _ in
                    Circle().frame(width: size * 0.08, height: size * 0.08)
                }
            }
        }
    }

    @ViewBuilder
    private func mouthLayer(size: CGFloat) -> some View {
        switch mood {
        case .friendly:
            Capsule().fill(Color.red.opacity(0.45)).frame(width: size * 0.15, height: size * (0.016 + lipFullness * 0.03))
        case .focused:
            Capsule().fill(Color.black.opacity(0.45)).frame(width: size * 0.13, height: size * 0.012)
        case .confident:
            Capsule().fill(Color.red.opacity(0.5)).frame(width: size * 0.14, height: size * (0.014 + lipFullness * 0.02)).rotationEffect(.degrees(-6))
        case .playful:
            Capsule().fill(Color.red.opacity(0.55)).frame(width: size * 0.16, height: size * (0.018 + lipFullness * 0.032)).rotationEffect(.degrees(5))
        }
    }
}
