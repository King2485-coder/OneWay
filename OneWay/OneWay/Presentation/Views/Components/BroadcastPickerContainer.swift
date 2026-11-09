import ReplayKit
import SwiftUI
import UIKit

enum OneWayBroadcastConfiguration {
    static let extensionBundleIdentifier = "com.king.OneWay.broadcast"
}

final class BroadcastPickerContainer: UIView {
    private let broadcastPicker = RPSystemBroadcastPickerView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        broadcastPicker.translatesAutoresizingMaskIntoConstraints = false
        broadcastPicker.preferredExtension = OneWayBroadcastConfiguration.extensionBundleIdentifier
        broadcastPicker.showsMicrophoneButton = true

        addSubview(broadcastPicker)

        NSLayoutConstraint.activate([
            broadcastPicker.leadingAnchor.constraint(equalTo: leadingAnchor),
            broadcastPicker.trailingAnchor.constraint(equalTo: trailingAnchor),
            broadcastPicker.topAnchor.constraint(equalTo: topAnchor),
            broadcastPicker.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct OneWayBroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> BroadcastPickerContainer {
        BroadcastPickerContainer()
    }

    func updateUIView(_ uiView: BroadcastPickerContainer, context: Context) {}
}
