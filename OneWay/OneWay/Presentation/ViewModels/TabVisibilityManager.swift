import SwiftUI
import Combine

final class TabVisibilityManager: ObservableObject {
    @Published var isTabBarHidden: Bool = false
}
