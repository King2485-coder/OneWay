import SwiftUI

struct ShopFeedView: View {
    private let onManage: (() -> Void)?

    init(service: StorefrontService = .shared, onManage: (() -> Void)? = nil) {
        self.onManage = onManage
    }

    var body: some View {
        OneWayShopsView(onManage: onManage)
    }
}
