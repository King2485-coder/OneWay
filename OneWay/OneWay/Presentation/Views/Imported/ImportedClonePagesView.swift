import SwiftUI

struct ImportedClonePagesView: View {
    enum Destination: Hashable {
        case onboarding
        case login
        case signup
        case chats
        case chat
        case calls
        case status
        case communities
        case contacts
        case settings
        case editProfile
        case profilePicture
        case contactProfilePicture
        case contactDetails
        case allMedia
        case specificMedia
        case newConversation
        case addNewContact
        case editContact
        case newGroup
        case countries
        case chooseInfo
        case takePhoto
        case takePhotoForChat
        case notImplemented
    }

    private let messagingService: MessagingService
    private let friendService: FriendService
    private let storyService: StoryService
    private let groupService: GroupService
    private let contactImportService: ContactImportService
    private let importedContactsStore: ImportedContactsStore
    private let callService: CallService
    private let communityService: CommunityService
    private let cryptoService: CryptoService
    private let authService: AuthService
    private let keyService: KeyService
    private let localPersistence: LocalPersistence
    private let accountDeletionScheduler: AccountDeletionScheduler

    init(
        messagingService: MessagingService,
        friendService: FriendService,
        storyService: StoryService,
        groupService: GroupService,
        contactImportService: ContactImportService,
        importedContactsStore: ImportedContactsStore,
        callService: CallService,
        communityService: CommunityService,
        cryptoService: CryptoService,
        authService: AuthService,
        keyService: KeyService,
        localPersistence: LocalPersistence,
        accountDeletionScheduler: AccountDeletionScheduler
    ) {
        self.messagingService = messagingService
        self.friendService = friendService
        self.storyService = storyService
        self.groupService = groupService
        self.contactImportService = contactImportService
        self.importedContactsStore = importedContactsStore
        self.callService = callService
        self.communityService = communityService
        self.cryptoService = cryptoService
        self.authService = authService
        self.keyService = keyService
        self.localPersistence = localPersistence
        self.accountDeletionScheduler = accountDeletionScheduler
    }

    private let mappedDestinations: [Destination] = [
        .onboarding,
        .login,
        .signup,
        .chats,
        .chat,
        .calls,
        .status,
        .communities,
        .contacts,
        .settings,
        .editProfile,
        .profilePicture,
        .contactProfilePicture,
        .contactDetails,
        .allMedia,
        .specificMedia,
        .newConversation,
        .addNewContact,
        .editContact,
        .newGroup,
        .countries,
        .chooseInfo,
        .takePhoto,
        .takePhotoForChat,
        .notImplemented
    ]

    var body: some View {
        List {
            Section("Imported Reference") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WhatsAppClone-main copied into workspace")
                        .font(.headline)
                    Text("/Users/king/Documents/OneWay/Reference/WhatsAppClone-main")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            Section("Clone Pages (Connected)") {
                ForEach(mappedDestinations, id: \.self) { destination in
                    NavigationLink(value: destination) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: destination))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(sourcePath(for: destination))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "link")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Imported Clone Pages")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .navigationDestination(for: Destination.self) { destination in
            destinationView(for: destination)
        }
    }

    private func title(for destination: Destination) -> String {
        switch destination {
        case .onboarding: return "OnboardingScreen"
        case .login: return "LoginScreen"
        case .signup: return "SignupScreen"
        case .chats: return "ChatsScreen"
        case .chat: return "ChatScreen"
        case .calls: return "CallsScreen"
        case .status: return "StatusScreen"
        case .communities: return "Communities"
        case .contacts: return "ContactsScreen"
        case .settings: return "SettingsScreen"
        case .editProfile: return "EditProfileScreen"
        case .profilePicture: return "ProfilePictureScreen"
        case .contactProfilePicture: return "ContactProfilePictureScreen"
        case .contactDetails: return "ContactDetailsScreen"
        case .allMedia: return "AllMediaScreen"
        case .specificMedia: return "SpecificMediaScreen"
        case .newConversation: return "NewConversationModal"
        case .addNewContact: return "AddNewContactModal"
        case .editContact: return "EditContactModal"
        case .newGroup: return "NewGroupModal"
        case .countries: return "CountriesModal"
        case .chooseInfo: return "ChooseInfoScreen"
        case .takePhoto: return "TakePhotoScreen"
        case .takePhotoForChat: return "TakePhotoScreenForChat"
        case .notImplemented: return "NotImplementedYetScreen"
        }
    }

    private func sourcePath(for destination: Destination) -> String {
        switch destination {
        case .onboarding: return "src/screens/OnboardingScreen.tsx"
        case .login: return "src/screens/LoginScreen.tsx"
        case .signup: return "src/screens/SignupScreen.tsx"
        case .chats: return "src/screens/ChatsScreen.tsx"
        case .chat: return "src/screens/ChatScreen.tsx"
        case .calls: return "src/screens/CallsScreen.tsx"
        case .status: return "src/screens/StatusScreen.tsx"
        case .communities: return "src/navigator/BottomTabNavigator.tsx"
        case .contacts: return "src/screens/ContactsScreen.tsx"
        case .settings: return "src/screens/SettingsScreen.tsx"
        case .editProfile: return "src/screens/EditProfileScreen.tsx"
        case .profilePicture: return "src/screens/ProfilePictureScreen.tsx"
        case .contactProfilePicture: return "src/screens/ContactProfilePictureScreen.tsx"
        case .contactDetails: return "src/screens/ContactDetailsScreen.tsx"
        case .allMedia: return "src/screens/AllMediaScreen.tsx"
        case .specificMedia: return "src/screens/SpecificMediaScreen.tsx"
        case .newConversation: return "src/screens/NewConversationModal.tsx"
        case .addNewContact: return "src/screens/AddNewContactModal.tsx"
        case .editContact: return "src/screens/EditContactModal.tsx"
        case .newGroup: return "src/screens/NewGroupModal.tsx"
        case .countries: return "src/screens/CountriesModal.tsx"
        case .chooseInfo: return "src/screens/ChooseInfoScreen.tsx"
        case .takePhoto: return "src/screens/TakePhotoScreen.tsx"
        case .takePhotoForChat: return "src/screens/TakePhotoScreenForChat.tsx"
        case .notImplemented: return "src/screens/NotImplementedYetScreen.tsx"
        }
    }

    @ViewBuilder
    private func destinationView(for destination: Destination) -> some View {
        switch destination {
        case .onboarding:
            CloneAuthFlowView(startAt: .onboarding, authService: authService)
        case .login:
            CloneAuthFlowView(startAt: .login, authService: authService)
        case .signup:
            CloneAuthFlowView(startAt: .signup, authService: authService)
        case .chats:
            ChatsListView(
                messagingService: messagingService,
                friendService: friendService,
                storyService: storyService,
                groupService: groupService,
                callService: callService
            )
        case .chat:
            CloneChatScreenView(
                messagingService: messagingService,
                groupService: groupService,
                friendService: friendService,
                callService: callService
            )
        case .calls:
            PhoneRootView(
                friendService: friendService,
                contactImportService: contactImportService,
                importedContactsStore: importedContactsStore,
                callService: callService
            )
        case .status:
            UpdatesView(
                storyService: storyService,
                safetyService: StubSafetyService()
            )
        case .communities:
            CommunitiesView(
                communityService: communityService,
                messagingService: messagingService,
                cryptoService: cryptoService
            )
        case .contacts:
            CloneContactsScreenView(friendService: friendService)
        case .settings:
            SettingsBridgeView()
        case .editProfile:
            CloneEditProfileView()
        case .profilePicture:
            CloneProfilePictureView()
        case .contactProfilePicture:
            CloneContactProfilePictureView()
        case .contactDetails:
            CloneContactDetailsView(friendService: friendService)
        case .allMedia:
            CloneAllMediaView()
        case .specificMedia:
            CloneSpecificMediaView(itemName: "Media Item")
        case .newConversation:
            CloneNewConversationView(friendService: friendService)
        case .addNewContact:
            CloneAddNewContactView()
        case .editContact:
            CloneEditContactView()
        case .newGroup:
            CloneNewGroupView()
        case .countries:
            CloneCountriesView()
        case .chooseInfo:
            CloneChooseInfoView()
        case .takePhoto:
            CloneTakePhotoView()
        case .takePhotoForChat:
            CloneTakePhotoForChatView()
        case .notImplemented:
            CloneFeatureRoadmapView()
        }
    }
}

private struct CloneInfoPageView: View {
    let title: String
    let sourcePath: String
    let notes: String

    var body: some View {
        List {
            Section("Imported Page") {
                LabeledContent("Screen", value: title)
                LabeledContent("Source", value: sourcePath)
            }

            Section("Status") {
                Text(notes)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle(title)
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

private struct SettingsBridgeView: View {
    var body: some View {
        List {
            Section("Connected") {
                Text("Use the main app Settings tab for the full OneWay settings experience.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("SettingsScreen")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}
