import XCTest
@testable import CipherChat

@MainActor
final class CreationToolsViewModelTests: XCTestCase {
    func testCloudFilesComeFromServiceWithoutInventedRows() async {
        let expected = PlatformCloudFile(
            id: "file-1",
            name: "brand-kit.zip",
            mimeType: "application/zip",
            byteCount: 42,
            storageKey: "private/file-1",
            encrypted: true,
            createdAt: "2026-07-26T07:00:00Z",
            updatedAt: "2026-07-26T07:00:00Z"
        )
        let model = CreationToolsViewModel(cloudService: CreationToolsCloudServiceMock(files: [expected]))

        await model.loadCloudFiles()

        XCTAssertEqual(model.cloudFiles, [expected])
        XCTAssertNil(model.cloudErrorMessage)
    }

    func testCloudFailureProducesRetryableErrorState() async {
        let model = CreationToolsViewModel(
            cloudService: CreationToolsCloudServiceMock(error: TestError.offline)
        )

        await model.loadCloudFiles()

        XCTAssertTrue(model.cloudFiles.isEmpty)
        XCTAssertEqual(model.cloudErrorMessage, "Test connection unavailable.")
        XCTAssertFalse(model.isLoadingCloud)
    }

    func testUploadUsesSelectedFileNameAndByteCount() async throws {
        let mock = CreationToolsCloudServiceMock()
        let model = CreationToolsViewModel(cloudService: mock)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("creator-hub-test-\(UUID().uuidString).txt")
        let payload = Data("OneWay".utf8)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await model.upload(url: url)

        XCTAssertEqual(mock.createdName, url.lastPathComponent)
        XCTAssertEqual(mock.createdByteCount, payload.count)
        XCTAssertEqual(model.cloudFiles.first?.name, url.lastPathComponent)
        XCTAssertNotNil(model.uploadMessage)
    }
}

private final class CreationToolsCloudServiceMock: CreationToolsCloudService {
    var files: [PlatformCloudFile]
    var error: Error?
    var createdName: String?
    var createdByteCount: Int?

    init(files: [PlatformCloudFile] = [], error: Error? = nil) {
        self.files = files
        self.error = error
    }

    func fetchCloudFiles() async throws -> [PlatformCloudFile] {
        if let error { throw error }
        return files
    }

    func createCloudFile(name: String, byteCount: Int) async throws -> PlatformCloudFile {
        if let error { throw error }
        createdName = name
        createdByteCount = byteCount
        return PlatformCloudFile(
            id: "created",
            name: name,
            mimeType: "application/octet-stream",
            byteCount: byteCount,
            storageKey: "private/created",
            encrypted: true,
            createdAt: "2026-07-26T07:00:00Z",
            updatedAt: "2026-07-26T07:00:00Z"
        )
    }
}

private enum TestError: LocalizedError {
    case offline

    var errorDescription: String? {
        "Test connection unavailable."
    }
}
