import SwiftUI

struct BurnButtonOverlay: View {
    let isEnabled: Bool
    let onBurn: () async throws -> Void

    @State private var position: CGPoint = .zero
    @State private var hasInitializedPosition = false
    @State private var showConfirm = false
    @State private var showResult = false
    @State private var resultMessage = ""
    @State private var isBurning = false

    var body: some View {
        GeometryReader { proxy in
            if isEnabled {
                button(proxy: proxy)
            }
        }
        .allowsHitTesting(isEnabled)
        .confirmationDialog(
            "Burn Account",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Burn Account", role: .destructive) {
                Task {
                    await burn()
                }
            }

            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This performs a best-effort account wipe on this app instance. External copies like screenshots or backups may still exist.")
        }
        .alert("Burn Result", isPresented: $showResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resultMessage)
        }
    }

    private func button(proxy: GeometryProxy) -> some View {
        Button {
            showConfirm = true
        } label: {
            Label("Burn", systemImage: isBurning ? "hourglass" : "flame.fill")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(isBurning ? Color.gray : Color.red)
                .clipShape(Capsule())
                .shadow(radius: 4)
        }
        .disabled(isBurning)
        .position(resolvedPosition(in: proxy.size))
        .gesture(
            DragGesture()
                .onChanged { value in
                    position = clamped(value.location, in: proxy.size)
                }
        )
        .onAppear {
            if !hasInitializedPosition {
                position = CGPoint(x: proxy.size.width - 70, y: proxy.size.height - 120)
                hasInitializedPosition = true
            }
        }
    }

    private func resolvedPosition(in size: CGSize) -> CGPoint {
        if !hasInitializedPosition {
            return CGPoint(x: size.width - 70, y: size.height - 120)
        }

        return clamped(position, in: size)
    }

    private func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let horizontalPadding: CGFloat = 70
        let verticalPadding: CGFloat = 60

        return CGPoint(
            x: min(max(point.x, horizontalPadding), max(horizontalPadding, size.width - horizontalPadding)),
            y: min(max(point.y, verticalPadding), max(verticalPadding, size.height - verticalPadding))
        )
    }

    private func burn() async {
        isBurning = true
        defer { isBurning = false }

        do {
            try await onBurn()
            resultMessage = "Account wipe request completed on this device. Absolute deletion across screenshots/backups cannot be guaranteed."
        } catch {
            resultMessage = "Burn failed. Please try again."
        }

        showResult = true
    }
}
