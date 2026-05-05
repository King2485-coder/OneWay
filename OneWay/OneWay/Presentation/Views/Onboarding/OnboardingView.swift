import SwiftUI

struct OnboardingView: View {
    @State private var index = 0
    @State private var animateHero = false
    @State private var animateMock = false
    @State private var ctaPressed = false
    let onFinish: () -> Void

    private let pages: [OnboardingPage] = [
        .init(
            title: "Group Chats",
            subtitle: "Stay connected with groups up to 1,000 people.",
            kind: .groupChats
        ),
        .init(
            title: "Private Conversations",
            subtitle: "Your messages stay between you and the people you choose.",
            kind: .privateMessaging
        ),
        .init(
            title: "End-to-End Encrypted",
            subtitle: "Nobody can read your messages. Not even us.",
            kind: .encrypted
        ),
        .init(
            title: "Send Photos, Videos & Files",
            subtitle: "Share moments instantly with friends and family.",
            kind: .sendAnything
        ),
        .init(
            title: "Welcome to OneWay",
            subtitle: "Fast. Private. Simple.",
            kind: .start
        )
    ]

    var body: some View {
        ZStack {
            animatedBackground

            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { offset, page in
                        pageView(for: page)
                            .tag(offset)
                            .padding(.horizontal, 24)
                            .padding(.top, 26)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 34)
                    .padding(.top, 14)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: index)
        .onAppear {
            triggerEntranceAnimation()
        }
        .onChange(of: index) { _, _ in
            animateHero = false
            animateMock = false
            triggerEntranceAnimation()
        }
        .preferredColorScheme(.dark)
    }

    private var animatedBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .black,
                    Color.blue.opacity(0.24),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Theme.primaryBlue.opacity(animateHero ? 0.3 : 0.16),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 1.0), value: animateHero)
        }
    }

    @ViewBuilder
    private func pageView(for page: OnboardingPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image("planeWatermark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .opacity(0.9)
                Text("OneWay")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }

            Text(page.title)
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .offset(y: animateHero ? 0 : 40)
                .opacity(animateHero ? 1 : 0)

            Text(page.subtitle)
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .offset(y: animateHero ? 0 : 28)
                .opacity(animateHero ? 1 : 0)

            Spacer(minLength: 12)

            PhoneMockupCard(kind: page.kind)
                .offset(y: animateMock ? 0 : 32)
                .scaleEffect(animateMock ? 1 : 0.96)
                .opacity(animateMock ? 1 : 0)

            Spacer()
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { dot in
                    Capsule()
                        .fill(dot == index ? Theme.primaryBlue : Color.white.opacity(0.3))
                        .frame(width: dot == index ? 20 : 8, height: 8)
                }
            }

            Button {
                ctaPressed = true
                if index < pages.count - 1 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        index += 1
                    }
                } else {
                    onFinish()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    ctaPressed = false
                }
            } label: {
                Text(index == pages.count - 1 ? "Get Started" : "Next")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.accentGradient)
                    )
                    .shadow(color: Theme.primaryBlue.opacity(0.35), radius: 16, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .scaleEffect(ctaPressed ? 0.92 : 1)
            .animation(.spring(), value: ctaPressed)
        }
    }

    private func triggerEntranceAnimation() {
        withAnimation(.easeOut(duration: 0.8)) {
            animateHero = true
        }
        withAnimation(.spring(response: 0.58, dampingFraction: 0.82).delay(0.08)) {
            animateMock = true
        }
    }
}

private struct OnboardingPage {
    enum Kind {
        case groupChats
        case privateMessaging
        case encrypted
        case sendAnything
        case start
    }

    let title: String
    let subtitle: String
    let kind: Kind
}

private struct PhoneMockupCard: View {
    let kind: OnboardingPage.Kind

    var body: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.11))
                        .frame(width: 88, height: 5)
                        .padding(.top, 12)

                    mockContent

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .frame(height: 430)
            .shadow(color: Theme.glassShadow, radius: 20, x: 0, y: 10)
    }

    @ViewBuilder
    private var mockContent: some View {
        switch kind {
        case .groupChats:
            VStack(spacing: 10) {
                chatRow(name: "Core Team", message: "Standup starts now ✅", right: "2m")
                chatRow(name: "Design Squad", message: "Love the new reactions 🎉", right: "6m")
                mediaStrip
            }
        case .privateMessaging:
            VStack(spacing: 10) {
                bubble("Hey, are we still on for tonight?", mine: false)
                bubble("Yep, see you at 8 👌", mine: true)
                HStack {
                    Text("Read 1:42 PM")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
            }
        case .encrypted:
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.primaryBlue)
                            Text("Secure Session")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                bubble("Message encrypted on device", mine: false)
                bubble("Only you and Sam can read this.", mine: true)
            }
        case .sendAnything:
            VStack(spacing: 10) {
                mediaStrip
                bubble("Vacation clip.mov", mine: true)
                bubble("Family-photo.jpg", mine: false)
            }
        case .start:
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.accentGradient.opacity(0.38))
                    .frame(height: 180)
                    .overlay {
                        Image("planeWatermark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .opacity(0.9)
                    }
                Text("Your chats. Your people. Your privacy.")
                    .multilineTextAlignment(.center)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var mediaStrip: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 74)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
            }
        }
    }

    private func chatRow(name: String, message: String, right: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 38, height: 38)
                .overlay {
                    Text(String(name.prefix(1)))
                        .foregroundStyle(Theme.textPrimary)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(right)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 36) }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(mine ? Theme.primaryBlue.opacity(0.5) : Color.white.opacity(0.08))
                )
            if !mine { Spacer(minLength: 36) }
        }
    }
}
