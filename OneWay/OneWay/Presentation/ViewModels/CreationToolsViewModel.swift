import SwiftUI
import Network
import Combine

@MainActor
final class CreationToolsViewModel: ObservableObject {
    @Published private(set) var sites: [OneWayBuilderSite]?
    @Published private(set) var cloudFiles: [PlatformCloudFile] = []
    @Published private(set) var isLoadingCloud = false
    @Published private(set) var isUploading = false
    @Published private(set) var isOffline = false
    @Published private(set) var cloudErrorMessage: String?
    @Published private(set) var uploadMessage: String?

    private let cloudService: CreationToolsCloudService
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "oneway.creation-tools.network")
    private var hasStartedMonitoring = false

    init(cloudService: CreationToolsCloudService = NetworkPlatformCapabilityService()) {
        self.cloudService = cloudService
    }

    deinit { pathMonitor.cancel() }

    var siteCount: Int? { sites?.count }
    var publishedSiteCount: Int? { sites?.filter { $0.status == .published }.count }
    var draftSiteCount: Int? { sites?.filter { $0.status == .draft }.count }

    var activities: [CreationToolsActivity] {
        let siteActivity = (sites ?? []).map { site in
            CreationToolsActivity(id: "site-\(site.id.uuidString)", title: site.name, status: site.status == .published ? "Published" : site.status.rawValue.capitalized, date: site.lastEdited, icon: "globe", tint: site.status == .published ? OneWayDS.ColorToken.success : OneWayDS.ColorToken.oneWayPurpleGlow)
        }
        let cloudActivity = cloudFiles.compactMap { file -> CreationToolsActivity? in
            guard let date = Self.date(from: file.updatedAt) else { return nil }
            return CreationToolsActivity(id: "file-\(file.id)", title: file.name, status: file.encrypted ? "Upload complete" : "Uploaded", date: date, icon: "icloud.fill", tint: OneWayDS.ColorToken.info)
        }
        return (siteActivity + cloudActivity).sorted { $0.date > $1.date }
    }

    func load() async {
        startNetworkMonitoringIfNeeded()
        loadSites()
        await loadCloudFiles()
    }

    func reload() {
        loadSites()
        Task { await loadCloudFiles() }
    }

    func loadCloudFiles() async {
        guard !isOffline else { isLoadingCloud = false; cloudErrorMessage = nil; return }
        isLoadingCloud = true
        cloudErrorMessage = nil
        do { cloudFiles = try await cloudService.fetchCloudFiles() }
        catch { cloudErrorMessage = error.localizedDescription }
        isLoadingCloud = false
    }

    func upload(url: URL) async {
        uploadMessage = nil
        cloudErrorMessage = nil
        guard !isOffline else { cloudErrorMessage = "Connect to the internet before uploading."; return }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw CreationToolsUploadError.notAFile }
            isUploading = true
            let file = try await cloudService.createCloudFile(name: url.lastPathComponent, byteCount: values.fileSize ?? 0)
            cloudFiles.removeAll { $0.id == file.id }
            cloudFiles.insert(file, at: 0)
            uploadMessage = "\(file.name) is now available in your private cloud."
        } catch { cloudErrorMessage = error.localizedDescription }
        isUploading = false
    }

    func reportImportFailure(_ error: Error) { cloudErrorMessage = error.localizedDescription }

    func clearNotice() {
        cloudErrorMessage = nil
        uploadMessage = nil
    }

    private func loadSites() {
        guard let data = UserDefaults.standard.data(forKey: "oneway.sites.localSites.v1") else { sites = []; return }
        do { sites = try JSONDecoder().decode([OneWayBuilderSite].self, from: data) }
        catch { sites = nil }
    }

    private func startNetworkMonitoringIfNeeded() {
        guard !hasStartedMonitoring else { return }
        hasStartedMonitoring = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = self.isOffline
                self.isOffline = path.status != .satisfied
                if wasOffline && !self.isOffline { await self.loadCloudFiles() }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private static func date(from value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

protocol CreationToolsCloudService {
    func fetchCloudFiles() async throws -> [PlatformCloudFile]
    func createCloudFile(name: String, byteCount: Int) async throws -> PlatformCloudFile
}

extension NetworkPlatformCapabilityService: CreationToolsCloudService {}

private enum CreationToolsUploadError: LocalizedError {
    case notAFile
    var errorDescription: String? { "Choose a regular file to upload." }
}

struct CreationToolsActivity: Identifiable {
    let id: String
    let title: String
    let status: String
    let date: Date
    let icon: String
    let tint: Color
    var relativeDate: String { RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now) }
}
