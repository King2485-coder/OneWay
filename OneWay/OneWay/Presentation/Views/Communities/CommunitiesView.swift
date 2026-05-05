import SwiftUI

struct CommunitiesView: View {
    private enum Route: Hashable {
        case examples
        case newCommunity
        case detail(UUID)
    }

    @State private var communities: [Community] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var path: [Route] = []
    private let communityService: CommunityService
    private let messagingService: MessagingService
    private let cryptoService: CryptoService

    init(communityService: CommunityService, messagingService: MessagingService, cryptoService: CryptoService) {
        self.communityService = communityService
        self.messagingService = messagingService
        self.cryptoService = cryptoService
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    heroCard
                    communityList
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 22)
            }
            .background { SideMenuBackground() }
            .oneWayMenuBar()
            .navigationBarHidden(true)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .examples:
                    ExampleCommunitiesView()
                case .newCommunity:
                    NewCommunityView { name, description in
                        Task { await createCommunity(name: name, description: description) }
                    }
                case .detail(let id):
                    CommunityDetailView(
                        communityID: id,
                        communityService: communityService,
                        messagingService: messagingService,
                        cryptoService: cryptoService
                    )
                }
            }
            .task {
                await loadCommunities()
            }
            .alert("Communities", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Communities")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
                .truncationMode(.tail)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Circle()
                .fill(Theme.primaryBlue)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .shadow(color: Theme.primaryBlue.opacity(0.28), radius: 8, x: 0, y: 3)
                .onTapGesture {
                    path.append(.newCommunity)
                }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.glassSurface)
                .frame(height: 210)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 58))
                            .foregroundStyle(Theme.primaryBlue)
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                Text("Stay connected with a community")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Communities bring members together in topic-based groups. Any community you are added to appears here.")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)

            Button("See example communities") {
                path.append(.examples)
            }
            .font(.headline.weight(.semibold))
            .foregroundStyle(Theme.primaryBlue)
        }

        Button {
            path.append(.newCommunity)
        } label: {
                Label("New community", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.primaryBlue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .shadow(color: Theme.primaryBlue.opacity(0.3), radius: 10, x: 0, y: 5)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var communityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Communities")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            ForEach(Array(communities.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.glassSurface)
                        .frame(width: 56, height: 56)
                        .overlay(Image(systemName: "person.3.fill").foregroundStyle(Theme.textPrimary))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(item.members.count) members")
                            .font(.title3)
                            .foregroundStyle(Theme.textSecondary)
                        Text(item.description)
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textMuted)
                        .onTapGesture { path.append(.detail(item.id)) }
                }

                if index < communities.count - 1 {
                    Divider().overlay(Theme.divider).padding(.leading, 72)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Theme.glassSurface)
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.divider, lineWidth: 1))
    }

    private func loadCommunities() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            communities = try await communityService.listCommunities()
            errorMessage = nil
        } catch {
            errorMessage = "Unable to load communities."
        }
    }

    private func createCommunity(name: String, description: String) async {
        let community = Community(
            id: UUID(),
            name: name,
            description: description,
            coverImageURL: nil,
            avatarURL: nil,
            ownerID: UUID(),
            admins: [],
            moderators: [],
            members: [],
            linkedGroupIDs: []
        )
        do {
            let created = try await communityService.createCommunity(community)
            communities.append(created)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to create community."
        }
    }
}

private struct ExampleCommunitiesView: View {
    var body: some View {
        List {
            Section("Examples") {
                Label("Campus Builders", systemImage: "person.3")
                Label("Neighborhood Watch", systemImage: "shield")
                Label("Weekend Sports", systemImage: "sportscourt")
            }
        }
        .navigationTitle("Example Communities")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

private struct NewCommunityView: View {
    var onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""

    var body: some View {
        Form {
            Section("Details") {
                TextField("Community name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Button("Create Community") {
                    onCreate(name, description)
                    dismiss()
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("New Community")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

private struct CommunityDetailView: View {
    let communityID: UUID
    let communityService: CommunityService
    let messagingService: MessagingService
    let cryptoService: CryptoService

    @State private var groups: [GroupChat] = []
    @State private var members: [CommunityMember] = []
    @State private var isLoading = false
    @State private var newMemberHandle = ""

    var body: some View {
        List {
            Section("Groups") {
                ForEach(groups) { group in
                    NavigationLink(group.name) {
                        GroupDetailView(group: group, members: members)
                    }
                }
            }

            Section("Members") {
                ForEach(members) { member in
                    HStack {
                        Text(member.displayName)
                        Spacer()
                        Text(member.role.rawValue.capitalized)
                            .font(.caption)
                        Button(role: .destructive) {
                            Task { try? await communityService.removeMember(communityID: communityID, memberID: member.id); await load() }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                }
                HStack {
                    TextField("@handle", text: $newMemberHandle)
                        .textInputAutocapitalization(.never)
                    Button("Add") {
                        Task {
                            guard !newMemberHandle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            _ = try? await communityService.addMember(communityID: communityID, handle: newMemberHandle, role: .member)
                            newMemberHandle = ""
                            await load()
                        }
                    }
                }
            }
        }
        .navigationTitle("Community")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .task { await load() }
        .overlay {
            if isLoading {
                ProgressView("Loading…")
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let groupsTask = communityService.listGroups(in: communityID)
        async let membersTask = communityService.members(of: communityID)
        groups = (try? await groupsTask) ?? []
        members = (try? await membersTask) ?? []
    }
}

private struct GroupDetailView: View {
    let group: GroupChat
    let members: [CommunityMember]

    var body: some View {
        List {
            Section("Info") {
                Text(group.topic ?? "No topic")
                Text("Members: \(group.memberIDs.count)")
            }

            Section("Members") {
                ForEach(members.filter { group.memberIDs.contains($0.id) }) { member in
                    Text(member.displayName)
                }
            }
        }
        .navigationTitle(group.name)
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}
