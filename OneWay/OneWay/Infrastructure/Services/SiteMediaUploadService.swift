import CryptoKit
import Foundation

enum SiteMediaUploadServiceError: LocalizedError {
    case unreadableFile
    case invalidUploadSession
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "Couldn’t read the selected media file."
        case .invalidUploadSession:
            return "The media upload session was invalid."
        case .fileTooLarge:
            return "The selected media file is too large."
        }
    }
}

final class SiteMediaUploadService {
    private struct UploadSessionRequest: Encodable {
        let mediaType: String
        let fileName: String
        let mimeType: String
        let fileSizeBytes: Int
        let checksum: String
        let width: Int?
        let height: Int?
        let durationMilliseconds: Int?
    }

    private struct UploadSessionResponse: Decodable {
        let assetId: String
        let uploadURL: String?
        let uploadUrl: String?
        let maxBytes: Int
        let asset: SiteMediaAssetDTO?

        var resolvedUploadPath: String? {
            (uploadURL ?? uploadUrl)?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    private struct UploadCompletionResponse: Decodable {
        let asset: SiteMediaAssetDTO
    }

    fileprivate struct SiteMediaAssetDTO: Decodable {
        let id: String
        let siteId: String
        let mediaType: String?
        let originalFileName: String
        let mimeType: String
        let sourceMimeType: String?
        let outputMimeType: String?
        let width: Int?
        let height: Int?
        let durationMilliseconds: Int?
        let fileSizeBytes: Int
        let uploadStatus: String?
        let processingStatus: String
        let publicStatus: String
        let failureCode: String?
        let failureMessage: String?
        let altText: String
        let caption: String
        let focalPointX: Double
        let focalPointY: Double
        let usageCount: Int
        let url: String?
        let variants: [String: String]
    }

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func uploadMedia(
        site: OneWayBuilderSite,
        data: Data,
        fileName: String,
        mimeType: String,
        mediaType: SiteMediaType,
        altText: String,
        caption: String
    ) async throws -> SiteMediaAsset {
        guard !data.isEmpty else { throw SiteMediaUploadServiceError.unreadableFile }
        let domain = site.domain.subdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print(mediaType == .video ? "SITE_VIDEO_UPLOAD_SESSION_REQUESTED siteId=\(site.id.uuidString) byteCount=\(data.count)" : "SITE_IMAGE_UPLOAD_SESSION_REQUESTED siteId=\(site.id.uuidString) byteCount=\(data.count)")
        let session: UploadSessionResponse = try await client.post(
            "api/sites/\(domain)/media/upload-session",
            body: UploadSessionRequest(
                mediaType: mediaType.rawValue,
                fileName: fileName,
                mimeType: mimeType,
                fileSizeBytes: data.count,
                checksum: checksum,
                width: nil,
                height: nil,
                durationMilliseconds: nil
            )
        )
        guard let uploadPath = session.resolvedUploadPath, !uploadPath.isEmpty else {
            throw SiteMediaUploadServiceError.invalidUploadSession
        }
        print(mediaType == .video ? "SITE_VIDEO_UPLOAD_SESSION_CREATED assetId=\(session.assetId)" : "SITE_IMAGE_UPLOAD_SESSION_CREATED assetId=\(session.assetId)")
        print(mediaType == .video ? "SITE_VIDEO_UPLOAD_STARTED assetId=\(session.assetId)" : "SITE_IMAGE_UPLOAD_STARTED assetId=\(session.assetId)")
        let completion: UploadCompletionResponse = try await client.uploadMultipart(
            uploadPath,
            fileFieldName: "media",
            fileName: fileName,
            mimeType: mimeType,
            data: data,
            fields: [
                "altText": altText,
                "caption": caption
            ]
        )
        print(mediaType == .video ? "SITE_VIDEO_UPLOAD_COMPLETED assetId=\(session.assetId)" : "SITE_IMAGE_UPLOAD_COMPLETED assetId=\(session.assetId)")
        return completion.asset.toSiteMediaAsset(fallbackSiteID: site.id)
    }

    func uploadMedia(
        site: OneWayBuilderSite,
        fileURL: URL,
        fileName: String,
        mimeType: String,
        mediaType: SiteMediaType,
        altText: String,
        caption: String,
        sourceType: String,
        target: SiteMediaInsertionTarget?
    ) async throws -> SiteMediaAsset {
        let startedAt = Date()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0, FileManager.default.isReadableFile(atPath: fileURL.path) else {
            print("SITE_MEDIA_LOCAL_COPY_FAILED siteId=\(site.id.uuidString) mediaType=\(mediaType.rawValue) sourceType=\(sourceType) localFileExists=\(FileManager.default.fileExists(atPath: fileURL.path)) byteCount=\(byteCount) failureCode=unreadable_file")
            throw SiteMediaUploadServiceError.unreadableFile
        }
        guard byteCount <= (mediaType == .video ? 250 * 1024 * 1024 : 12 * 1024 * 1024) else {
            print("SITE_MEDIA_UPLOAD_REQUEST_FAILED siteId=\(site.id.uuidString) mediaType=\(mediaType.rawValue) sourceType=\(sourceType) byteCount=\(byteCount) failureCode=file_too_large")
            throw SiteMediaUploadServiceError.fileTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: mediaType == .video ? [.mappedIfSafe] : [])
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let domain = site.domain.subdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        print("SITE_MEDIA_UPLOAD_SESSION_REQUESTED siteId=\(site.id.uuidString) pageId=\(target?.pageId.uuidString ?? "nil") sectionId=\(target?.sectionId.uuidString ?? "nil") assetId=nil mediaType=\(mediaType.rawValue) sourceType=\(sourceType) localFileExists=true byteCount=\(byteCount) mimeType=\(mimeType) checksum=\(checksum.prefix(12))")
        let session: UploadSessionResponse = try await client.post(
            "api/sites/\(domain)/media/upload-session",
            body: UploadSessionRequest(
                mediaType: mediaType.rawValue,
                fileName: fileName,
                mimeType: mimeType,
                fileSizeBytes: byteCount,
                checksum: checksum,
                width: nil,
                height: nil,
                durationMilliseconds: nil
            )
        )
        guard let uploadPath = session.resolvedUploadPath, !uploadPath.isEmpty else {
            print("SITE_MEDIA_UPLOAD_SESSION_RECEIVED siteId=\(site.id.uuidString) assetId=\(session.assetId) mediaType=\(mediaType.rawValue) failureCode=missing_upload_path")
            throw SiteMediaUploadServiceError.invalidUploadSession
        }
        print("SITE_MEDIA_UPLOAD_SESSION_RECEIVED siteId=\(site.id.uuidString) pageId=\(target?.pageId.uuidString ?? "nil") sectionId=\(target?.sectionId.uuidString ?? "nil") assetId=\(session.assetId) mediaType=\(mediaType.rawValue) sourceType=\(sourceType) localFileExists=true byteCount=\(byteCount) mimeType=\(mimeType) maxBytes=\(session.maxBytes)")
        print("SITE_MEDIA_UPLOAD_REQUEST_STARTED siteId=\(site.id.uuidString) assetId=\(session.assetId) mediaType=\(mediaType.rawValue) sourceType=\(sourceType) byteCount=\(byteCount) mimeType=\(mimeType)")
        print("SITE_MEDIA_UPLOAD_REQUEST_PROGRESS siteId=\(site.id.uuidString) assetId=\(session.assetId) mediaType=\(mediaType.rawValue) progress=0.0")
        let completion: UploadCompletionResponse = try await client.uploadMultipart(
            uploadPath,
            fileFieldName: "media",
            fileName: fileName,
            mimeType: mimeType,
            data: data,
            fields: [
                "altText": altText,
                "caption": caption
            ]
        )
        print("SITE_MEDIA_UPLOAD_REQUEST_PROGRESS siteId=\(site.id.uuidString) assetId=\(session.assetId) mediaType=\(mediaType.rawValue) progress=1.0")
        print("SITE_MEDIA_UPLOAD_REQUEST_RESPONSE siteId=\(site.id.uuidString) assetId=\(session.assetId) mediaType=\(mediaType.rawValue) httpStatus=2xx duration=\(Date().timeIntervalSince(startedAt)) processingStatus=\(completion.asset.processingStatus)")
        print("SITE_MEDIA_COMPLETE_SUCCEEDED siteId=\(site.id.uuidString) assetId=\(session.assetId) mediaType=\(mediaType.rawValue) processingStatus=\(completion.asset.processingStatus)")
        return completion.asset.toSiteMediaAsset(fallbackSiteID: site.id)
    }
}

private extension SiteMediaUploadService.SiteMediaAssetDTO {
    func toSiteMediaAsset(fallbackSiteID: UUID) -> SiteMediaAsset {
        SiteMediaAsset(
            id: UUID(uuidString: id) ?? UUID(),
            siteID: UUID(uuidString: siteId) ?? fallbackSiteID,
            mediaType: SiteMediaType(rawValue: mediaType ?? "IMAGE") ?? .image,
            originalFileName: originalFileName,
            mimeType: mimeType,
            sourceMimeType: sourceMimeType,
            outputMimeType: outputMimeType,
            width: width,
            height: height,
            durationMilliseconds: durationMilliseconds,
            fileSizeBytes: fileSizeBytes,
            uploadStatus: SiteMediaUploadStatus(rawValue: uploadStatus ?? "UPLOADED") ?? .uploaded,
            processingStatus: SiteMediaProcessingStatus(rawValue: processingStatus) ?? .ready,
            publicStatus: SiteMediaPublicStatus(rawValue: publicStatus) ?? .privateAsset,
            failureCode: failureCode,
            failureMessage: failureMessage,
            altText: altText,
            caption: caption,
            focalPointX: focalPointX,
            focalPointY: focalPointY,
            variants: variants.isEmpty ? ["original": url ?? ""] : variants,
            usageCount: usageCount
        )
    }
}
