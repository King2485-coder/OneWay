import SwiftUI

struct OneWayDialPad: View {
    let maxButtonSize: CGFloat
    let rowSpacing: CGFloat
    let columnSpacing: CGFloat
    let onTap: (String) -> Void

    private let rows: [[(value: String, letters: String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    var body: some View {
        GeometryReader { proxy in
            let buttonSize = min(
                (proxy.size.width - (columnSpacing * 2)) / 3,
                maxButtonSize
            )

            VStack(spacing: rowSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: columnSpacing) {
                        ForEach(row, id: \.value) { key in
                            OneWayDialButton(value: key.value, letters: key.letters, size: buttonSize) {
                                onTap(key.value)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
