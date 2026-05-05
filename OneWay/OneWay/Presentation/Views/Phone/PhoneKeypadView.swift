import SwiftUI
import Combine

struct PhoneKeypadView: View {
    @ObservedObject var manager: CallManager

    private let digits: [[(value: String, letters: String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PhonePanel(
                    title: "Keypad",
                    subtitle: "Enter a contact name, handle, or OneWay UUID to place a direct call."
                ) {
                    VStack(spacing: 16) {
                        TextField("Type a OneWay contact", text: $manager.dialedText)
                            .textFieldStyle(.roundedBorder)
                            .font(.title2.monospacedDigit())

                        VStack(spacing: 12) {
                            ForEach(Array(digits.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 14) {
                                    ForEach(row, id: \.value) { digit in
                                        Button {
                                            manager.dialedText.append(digit.value)
                                        } label: {
                                            VStack(spacing: 2) {
                                                Text(digit.value)
                                                    .font(.title2.weight(.semibold))
                                                if !digit.letters.isEmpty {
                                                    Text(digit.letters)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 64)
                                            .background(Color(.tertiarySystemBackground))
                                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button {
                                Task { await manager.placeDialedCall(video: false) }
                            } label: {
                                Label("Call", systemImage: "phone.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                Task { await manager.placeDialedCall(video: true) }
                            } label: {
                                Label("Video", systemImage: "video.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                _ = manager.dialedText.popLast()
                            } label: {
                                Image(systemName: "delete.left.fill")
                                    .frame(width: 50, height: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                PhonePanel(
                    title: "Matches",
                    subtitle: "Quick suggestions from your connected OneWay contacts."
                ) {
                    if manager.keypadSuggestions.isEmpty {
                        PhoneEmptyState(
                            title: "No matches yet",
                            bodyText: "Start typing a contact name, handle, or UUID to see matching OneWay contacts."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(manager.keypadSuggestions) { friend in
                                Button {
                                    manager.dialedText = friend.handle
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(friend.displayName)
                                                .font(.headline)
                                            Text(friend.handle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.left.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Keypad")
        .scrollDismissesKeyboard(.interactively)
    }
}
