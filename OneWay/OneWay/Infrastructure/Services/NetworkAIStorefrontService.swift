import Foundation

final class NetworkAIStorefrontService: AIStorefrontService {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let storefrontMapper: (NetworkBusinessService.APIStorefront) -> Storefront

    init(baseURL: URL, session: URLSession = .shared, mapper: @escaping (NetworkBusinessService.APIStorefront) -> Storefront) {
        self.baseURL = baseURL
        self.session = session
        self.storefrontMapper = mapper
        #if DEBUG
        print("[AI Service] Base URL: \(PrivacyLog.redact(baseURL.absoluteString))")
        #endif
    }

    convenience init(baseURL: URL, session: URLSession = .shared) {
        let business = NetworkBusinessService(baseURL: baseURL, session: session)
        self.init(baseURL: baseURL, session: session, mapper: business.mapStorefront)
    }

    func generate(from request: AIStorefrontRequest) async throws -> AIStorefrontResult {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("ai")
            .appendingPathComponent("storefronts")
            .appendingPathComponent("generate")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Keep auth/dev identity in one place: the backend uses x-dev-user-id
        // today, and will accept JWT via Authorization once enabled.
        req.setValue(AuthTokenStore.shared.currentUserID(), forHTTPHeaderField: "x-dev-user-id")
        req.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "prompt": request.prompt,
            "businessName": request.businessName,
            "category": request.category,
            "tone": request.tone,
            "goals": request.goals,
            "preferredColors": request.preferredColors,
            "includeSections": request.includeSections.map { $0.rawValue }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        #if DEBUG
        print("[AI Request] \(req.httpMethod ?? "POST") \(PrivacyLog.redactURL(req.url))")
        print("[AI Request] Headers: \(PrivacyLog.redact(req.allHTTPHeaderFields ?? [:]))")
        print("[AI Request] Payload: \(PrivacyLog.redact(payload))")
        #endif
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
#if DEBUG
            let nserr = error as NSError
            print("[AI Error] \(PrivacyLog.redact(error.localizedDescription)) domain=\(PrivacyLog.redact(nserr.domain)) code=\(nserr.code)")
#endif
            throw error
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "NetworkAIStorefrontService",
                          code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "AI generation failed (\(http.statusCode)): \(snippet.prefix(200))"])
        }
        let apiResponse = try decoder.decode(APIAIResponse.self, from: data)
        let mappedStore = storefrontMapper(apiResponse.storefront)
        let copyPairs: [(StorefrontSectionType, String)] = (apiResponse.generatedCopy ?? [:]).compactMap { key, value in
            guard let type = StorefrontSectionType(rawValue: key) else { return nil }
            return (type, value)
        }
        return AIStorefrontResult(storefront: mappedStore, generatedCopy: Dictionary(uniqueKeysWithValues: copyPairs))
    }

    func improve(storefrontID: UUID, prompt: String) async throws -> AIStorefrontResult {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("ai")
            .appendingPathComponent("storefronts")
            .appendingPathComponent(storefrontID.uuidString)
            .appendingPathComponent("improve")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AuthTokenStore.shared.currentUserID(), forHTTPHeaderField: "x-dev-user-id")
        req.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])

        #if DEBUG
        print("[AI Improve] \(req.httpMethod ?? "POST") \(PrivacyLog.redactURL(req.url))")
        #endif

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "NetworkAIStorefrontService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "AI improve failed (\(http.statusCode)): \(snippet.prefix(200))"]
            )
        }
        let apiResponse = try decoder.decode(APIAIResponse.self, from: data)
        let mappedStore = storefrontMapper(apiResponse.storefront)
        let copyPairs: [(StorefrontSectionType, String)] = (apiResponse.generatedCopy ?? [:]).compactMap { key, value in
            guard let type = StorefrontSectionType(rawValue: key) else { return nil }
            return (type, value)
        }
        return AIStorefrontResult(storefront: mappedStore, generatedCopy: Dictionary(uniqueKeysWithValues: copyPairs))
    }

    func regenerateSection(storefront: Storefront, section: StorefrontSectionType) async throws -> StorefrontSection {
        // Not yet supported by backend; return simple passthrough
        return StorefrontSection(type: section, title: section.rawValue.capitalized, body: nil, items: storefront.sections.first(where: { $0.type == section })?.items ?? [], mediaURLs: [])
    }

    func storefrontHelp(type: StorefrontAIHelpType, context: StorefrontAIHelpContext) async throws -> String {
        struct Payload: Encodable {
            let type: String
            let context: StorefrontAIHelpContext
        }

        struct Response: Decodable {
            let text: String
        }

        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("ai")
            .appendingPathComponent("storefront-help")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AuthTokenStore.shared.currentUserID(), forHTTPHeaderField: "x-dev-user-id")
        req.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try encoder.encode(Payload(type: type.rawValue, context: context))

        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let decoded = try decoder.decode(Response.self, from: data)
                if !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return decoded.text
                }
            }
        } catch {
            // Fall through to the local fallback so AI help never becomes a no-op.
        }

        return StorefrontAIFallback.text(for: type, context: context)
    }

    private struct APIAIResponse: Codable {
        let storefront: NetworkBusinessService.APIStorefront
        let generatedCopy: [String: String]?
    }
}
