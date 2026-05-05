import SwiftUI
import PhotosUI
import UIKit

struct CloneChatScreenView: View {
    private let messagingService: MessagingService
    private let groupService: GroupService
    private let friendService: FriendService
    private let callService: CallService

    @State private var chats: [ChatSummary] = []
    @State private var isLoading = false

    init(messagingService: MessagingService, groupService: GroupService, friendService: FriendService, callService: CallService) {
        self.messagingService = messagingService
        self.groupService = groupService
        self.friendService = friendService
        self.callService = callService
    }

    var body: some View {
        List {
            Section("Recent Chats") {
                if isLoading {
                    ProgressView()
                } else if chats.isEmpty {
                    Text("No chats found.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(chats) { chat in
                        NavigationLink {
                            ChatThreadView(
                                chat: chat,
                                messagingService: messagingService,
                                groupService: groupService,
                                friendService: friendService,
                                callService: callService
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chat.participantName)
                                    .font(.headline)
                                Text(chat.lastMessagePreview)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .navigationTitle("ChatScreen")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }

    private func load() async {
        guard chats.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        chats = (try? await messagingService.fetchChats()) ?? []
    }
}

struct CloneContactsScreenView: View {
    @State private var showAdd = false
    let friendService: FriendService

    var body: some View {
        List {
            Section("Contacts Actions") {
                Button("Add New Contact") {
                    showAdd = true
                }
                NavigationLink("View Friends List") {
                    FriendsListView(friendService: friendService)
                }
            }
        }
        .navigationTitle("ContactsScreen")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .sheet(isPresented: $showAdd) {
            AddFriendView(friendService: friendService)
        }
    }
}

struct CloneEditProfileView: View {
    @State private var name = "You"
    @State private var status = "Available"
    @State private var bio = "Secure by default."
    @State private var didSave = false

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display Name", text: $name)
                TextField("Status", text: $status)
                TextField("Bio", text: $bio, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Button("Save Changes") {
                    didSave = true
                }
                    .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .navigationTitle("EditProfileScreen")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .alert("Profile updated.", isPresented: $didSave) {
            Button("OK") {}
        }
    }
}

struct CloneProfilePictureView: View {
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(Theme.glassSurface)
                .frame(width: 180, height: 180)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 84))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

            PhotosPicker(selection: $item, matching: .images) {
                Text("Choose Profile Photo")
            }
            .buttonStyle(PrimaryPillButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(20)
        .navigationTitle("ProfilePictureScreen")
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .onChange(of: item) { _, selected in
            guard let selected else { return }
            Task {
                if let data = try? await selected.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    image = uiImage
                }
            }
        }
    }
}

struct CloneContactProfilePictureView: View {
    var body: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(Theme.glassSurface)
                .frame(width: 210, height: 210)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 100))
                        .foregroundStyle(Theme.textSecondary)
                }
            Text("Contact Profile Picture")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(24)
        .navigationTitle("ContactProfilePicture")
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

struct CloneContactDetailsView: View {
    let friendService: FriendService

    var body: some View {
        List {
            Section("Contact") {
                Label("Friend", systemImage: "person.crop.circle")
                Label("Online", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }
            Section("Actions") {
                NavigationLink("Message") { FriendsListView(friendService: friendService) }
                Label("Voice Call", systemImage: "phone.fill")
                Label("Video Call", systemImage: "video.fill")
            }
            Section("Media") {
                NavigationLink("View All Media") { CloneAllMediaView() }
            }
        }
        .navigationTitle("ContactDetailsScreen")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

struct CloneAllMediaView: View {
    private let samples = ["Photo 1", "Photo 2", "Video 1", "File.pdf"]

    var body: some View {
        List {
            Section("Shared Media") {
                ForEach(samples, id: \.self) { name in
                    NavigationLink(name) {
                        CloneSpecificMediaView(itemName: name)
                    }
                }
            }
        }
        .navigationTitle("AllMediaScreen")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

struct CloneSpecificMediaView: View {
    let itemName: String

    var body: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Theme.glassSurface)
                .frame(height: 260)
                .overlay {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.textSecondary)
                }
            Text(itemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("SpecificMediaScreen")
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

struct CloneNewConversationView: View {
    let friendService: FriendService

    var body: some View {
        List {
            Section("Start Conversation") {
                NavigationLink("Choose Friend") {
                    FriendsListView(friendService: friendService)
                }
                NavigationLink("Add New Contact") {
                    AddFriendView(friendService: friendService)
                }
            }
        }
        .navigationTitle("NewConversationModal")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

struct CloneAddNewContactView: View {
    @State private var name = ""
    @State private var handle = ""
    @State private var didSave = false

    var body: some View {
        Form {
            Section("Contact Info") {
                TextField("Name", text: $name)
                TextField("Handle", text: $handle)
            }
            Section {
                Button("Save Contact") {
                    didSave = true
                    name = ""
                    handle = ""
                }
                    .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .navigationTitle("AddNewContactModal")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .alert("Contact saved.", isPresented: $didSave) {
            Button("OK") {}
        }
    }
}

struct CloneEditContactView: View {
    @State private var nickname = "Friend"
    @State private var notes = ""
    @State private var didSave = false
    @State private var didDelete = false

    var body: some View {
        Form {
            Section("Edit Contact") {
                TextField("Nickname", text: $nickname)
                TextField("Notes", text: $notes, axis: .vertical)
            }
            Section {
                Button("Save") {
                    didSave = true
                }
                    .buttonStyle(PrimaryPillButtonStyle())
                Button("Delete Contact", role: .destructive) {
                    didDelete = true
                    nickname = ""
                    notes = ""
                }
            }
        }
        .navigationTitle("EditContactModal")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .alert("Contact updated.", isPresented: $didSave) {
            Button("OK") {}
        }
        .alert("Contact deleted.", isPresented: $didDelete) {
            Button("OK") {}
        }
    }
}

struct CloneNewGroupView: View {
    @State private var name = ""
    @State private var disappearing = true
    @State private var didCreate = false

    var body: some View {
        Form {
            Section("Group") {
                TextField("Group Name", text: $name)
                Toggle("Disappearing Messages", isOn: $disappearing)
            }
            Section("Members") {
                Label("Alex", systemImage: "person")
                Label("Priya", systemImage: "person")
                Label("Jordan", systemImage: "person")
            }
            Section {
                Button("Create Group") {
                    didCreate = true
                    name = ""
                }
                    .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .navigationTitle("NewGroupModal")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .alert("Group created.", isPresented: $didCreate) {
            Button("OK") {}
        }
    }
}

struct CloneCountriesView: View {
    @State private var query = ""
    private let countries = ["United States", "Canada", "United Kingdom", "India", "France", "Germany", "Japan", "Australia"]

    var body: some View {
        List {
            ForEach(filtered, id: \.self) { country in
                Text(country)
            }
        }
        .searchable(text: $query, prompt: "Search country")
        .navigationTitle("CountriesModal")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }

    private var filtered: [String] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return countries }
        return countries.filter { $0.localizedCaseInsensitiveContains(value) }
    }
}

struct CloneChooseInfoView: View {
    @State private var selected = "Phone Number"
    @State private var didContinue = false

    var body: some View {
        Form {
            Section("Primary Info") {
                Picker("Mode", selection: $selected) {
                    Text("Phone Number").tag("Phone Number")
                    Text("Email Address").tag("Email Address")
                    Text("Username").tag("Username")
                }
                .pickerStyle(.inline)
            }
            Section {
                Button("Continue") {
                    didContinue = true
                }
                    .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .navigationTitle("ChooseInfoScreen")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .alert("Selected \(selected).", isPresented: $didContinue) {
            Button("OK") {}
        }
    }
}

struct CloneTakePhotoView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Theme.glassSurface)
                .frame(height: 260)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Pick Photo")
            }
            .buttonStyle(PrimaryPillButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("TakePhotoScreen")
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    image = uiImage
                }
            }
        }
    }
}

struct CloneTakePhotoForChatView: View {
    @State private var caption = ""
    @State private var didSend = false

    var body: some View {
        Form {
            Section("Capture") {
                NavigationLink("Open Camera Style Picker") {
                    CloneTakePhotoView()
                }
            }
            Section("Caption") {
                TextField("Add caption", text: $caption)
            }
            Section {
                Button("Send to Chat") {
                    didSend = true
                    caption = ""
                }
                    .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .navigationTitle("TakePhotoForChat")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .alert("Media sent to chat.", isPresented: $didSend) {
            Button("OK") {}
        }
    }
}

struct CloneFeatureRoadmapView: View {
    var body: some View {
        List {
            Section("Ready Next") {
                Label("Live backend auth provider", systemImage: "checkmark.seal")
                Label("Real camera capture session", systemImage: "camera.metering.center.weighted")
                Label("End-to-end message sync", systemImage: "arrow.triangle.2.circlepath")
                Label("Encryption key exchange", systemImage: "lock.shield")
            }
        }
        .navigationTitle("NotImplementedYet")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}
