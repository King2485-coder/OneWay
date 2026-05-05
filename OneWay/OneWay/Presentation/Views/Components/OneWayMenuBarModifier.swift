import SwiftUI

struct OneWayMenuBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .safeAreaPadding(.bottom, 92)
    }
}

extension View {
    func oneWayMenuBar() -> some View {
        modifier(OneWayMenuBarModifier())
    }
}
