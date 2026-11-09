import XCTest
import SwiftUI
@testable import CipherChat

/// Opt-in captures of production views, with no account creation or purchase actions.
@MainActor final class PhonePolishAppearanceTests: XCTestCase {
    func testCaptureProductionLayouts() throws {
        let environment = AppEnvironment.live
        let screens: [(String, AnyView)] = [
            ("quantum", AnyView(BrowserHomeView(domainService: environment.domainService, siteService: environment.siteService))),
            ("features", AnyView(OneWayQuickActionsView(onSelect: { _ in }, onDeleteAccount: {}, onClose: {}))),
            ("sites", AnyView(CreateSiteFlowView(viewModel: OneWaySitesViewModel(), onRoute: { _ in }))),
            ("chirp", AnyView(WalkieView(onBack: {}, onOpenKeypad: {}))),
            ("shops", AnyView(ShopsHomeView(viewModel: MarketplaceViewModel(), searchText: .constant(""), onSearch: {}, onFilter: {}, onCategories: {}, onQuantumHome: {}, onRoute: { _ in })))
        ]
        for width: CGFloat in [402, 430] {
            for (name, screen) in screens {
                let view = screen.environmentObject(environment)
                    .preferredColorScheme(.dark).tint(OneWayDesignSystem.Colors.purple).fontDesign(.rounded)
                let controller = UIHostingController(rootView: view)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 932)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.frame = window.bounds
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(name)-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertGreaterThan(image.size.width, 0)
                window.isHidden = true
            }
        }
    }
    func testKeypadRoutesOneWayVideoSeparatelyFromAudio() async throws {
        let environment = AppEnvironment.live
        let suite = "KeypadVideoRouting." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let cacheKey = "OneWay.CallContacts.\(AppEnvironment.currentUserID())"
        let previousContacts = UserDefaults.standard.data(forKey: cacheKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            if let previousContacts { UserDefaults.standard.set(previousContacts, forKey: cacheKey) }
            else { UserDefaults.standard.removeObject(forKey: cacheKey) }
        }
        let friends = try await StubFriendService().fetchFriends()
        let friend = try XCTUnwrap(friends.first)
        UserDefaults.standard.set(try JSONEncoder().encode([friend]), forKey: cacheKey)
        let manager = CallManager(friendService: StubFriendService(),
                                  contactImportService: environment.contactImportService,
                                  importedContactsStore: UserDefaultsImportedContactsStore(defaults: defaults),
                                  callService: StubCallService())
        manager.dialedText = friend.handle
        await manager.placeDialedCall(video: true)
        XCTAssertEqual(manager.activeVoiceCall?.type, .video)
        XCTAssertEqual(manager.activeVoiceCall?.displayName, friend.displayName)
        manager.dismissCallSheet()
        await manager.placeDialedCall(video: false)
        XCTAssertEqual(manager.activeVoiceCall?.type, .voice)
        manager.dismissCallSheet()
        manager.dialedText = "+12025550148"
        await manager.placeDialedCall(video: true)
        XCTAssertNil(manager.activeVoiceCall)
        XCTAssertNil(manager.externalCallConfirmation)
        XCTAssertEqual(manager.alertMessage, "Video calls require a OneWay ID or OneWay number.")
    }

    func testCaptureMetallicKeypad() throws {
        let environment = AppEnvironment.live
        let suite = "MetalKeypadCapture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = CallManager(friendService: environment.friendService,
                                  contactImportService: environment.contactImportService,
                                  importedContactsStore: UserDefaultsImportedContactsStore(defaults: defaults),
                                  callService: environment.callService)
        for (width, height): (CGFloat, CGFloat) in [(390, 844), (430, 932)] {
            for entered in [false, true] {
                manager.updateDialedText(entered ? "+12025550148" : "")
                let view = PhoneKeypadView(manager: manager, onBackToHome: {}, onOpenChirp: {})
                    .preferredColorScheme(.dark).tint(OneWayDesignSystem.Colors.purple).fontDesign(.rounded)
                let controller = UIHostingController(rootView: view)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: height)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.frame = window.bounds
                controller.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "keypad-\(Int(width))-\(entered ? "entered" : "empty")"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(manager.dialedText, entered ? "+12025550148" : "")
                window.isHidden = true
            }
        }
    }

}
