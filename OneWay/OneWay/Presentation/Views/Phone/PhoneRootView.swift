import SwiftUI
import Combine

struct PhoneRootView: View {
    @StateObject private var manager: CallManager

    private let callService: CallService

    init(
        friendService: FriendService,
        contactImportService: ContactImportService,
        importedContactsStore: ImportedContactsStore,
        callService: CallService
    ) {
        self.callService = callService
        _manager = StateObject(
            wrappedValue: CallManager(
                friendService: friendService,
                contactImportService: contactImportService,
                importedContactsStore: importedContactsStore,
                callService: callService
            )
        )
    }

    var body: some View {
        NavigationStack {
            TabView {
                PhoneFavoritesView(manager: manager)
                    .tabItem {
                        Label("Favorites", systemImage: "star.fill")
                    }

                PhoneRecentsView(manager: manager)
                    .tabItem {
                        Label("Recents", systemImage: "clock.fill")
                    }

                PhoneContactsView(manager: manager)
                    .tabItem {
                        Label("Contacts", systemImage: "person.2.fill")
                    }

                PhoneKeypadView(manager: manager)
                    .tabItem {
                        Label("Keypad", systemImage: "circle.grid.3x3.fill")
                    }

                PhoneVoicemailView(manager: manager)
                    .tabItem {
                        Label("Voicemail", systemImage: "waveform")
                    }
            }
            .safeAreaInset(edge: .top) {
                PhoneBackendBanner(state: manager.backendState)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            .task {
                await manager.refreshAll()
            }
            .alert(
                "Calls",
                isPresented: Binding(
                    get: { manager.alertMessage != nil },
                    set: { if !$0 { manager.alertMessage = nil } }
                )
            ) {
                Button("OK") { manager.alertMessage = nil }
            } message: {
                Text(manager.alertMessage ?? "")
            }

            .alert(
                "External Phone Call",
                isPresented: Binding(
                    get: { manager.pendingExternalDialRequest != nil },
                    set: { if !$0 { manager.cancelExternalDial() } }
                )
            ) {
                Button("Cancel", role: .cancel) { manager.cancelExternalDial() }
                Button("Use External Network") { manager.confirmExternalDial() }
            } message: {
                Text("This number is outside OneWay. It will use your phone carrier or external phone network. Continue?")
            }
            .sheet(item: $manager.activeVoiceCall) { activeCall in
                CallSessionSheet(
                    callID: activeCall.id,
                    callType: activeCall.type,
                    displayName: activeCall.displayName,
                    callService: callService
                ) {
                    manager.dismissCallSheet()
                }
                .presentationDetents([.medium, .large])
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}
