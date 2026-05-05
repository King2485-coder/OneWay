import Foundation

/// Holds the project URL and anon key used to talk to Supabase.
///
/// Configure via Info.plist keys (preferred) or the in-code defaults.
/// Fill these in before you use `Supabase…Service` implementations.
///
/// Info.plist keys:
///   SUPABASE_URL         (String, e.g. https://YOUR_PROJECT.supabase.co)
///   SUPABASE_ANON_KEY    (String, your anon JWT)
enum SupabaseConfig {
    static var url: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
           let url = URL(string: s) {
            return url
        }
        return nil
    }

    static var anonKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
    }

    static var isConfigured: Bool {
        url != nil && (anonKey?.isEmpty == false)
    }
}

#if canImport(Supabase)
import Supabase

/// Lazily-initialised shared client. Call `SupabaseClientProvider.shared.client`
/// from infrastructure services. Returns `nil` if `SupabaseConfig` is incomplete.
final class SupabaseClientProvider {
    static let shared = SupabaseClientProvider()

    let client: SupabaseClient?

    private init() {
        guard let url = SupabaseConfig.url, let key = SupabaseConfig.anonKey else {
            self.client = nil
            return
        }
        self.client = SupabaseClient(supabaseURL: url, supabaseKey: key)
    }
}
#endif
