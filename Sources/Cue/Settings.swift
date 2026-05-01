import Foundation
import Combine

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private static let endpointKey = "cue.endpoint"
    private static let apiKeyAccount = "anthropic-api-key"
    private static let hasLaunchedBeforeKey = "cue.hasLaunchedBefore"

    static let defaultEndpoint = "https://api.anthropic.com"

    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: Self.endpointKey) }
    }

    /// Mirrored in Keychain. Assign to update both.
    @Published var apiKey: String {
        didSet {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != apiKey { apiKey = trimmed; return }
            if apiKey.isEmpty {
                Keychain.delete(account: Self.apiKeyAccount)
            } else {
                Keychain.save(account: Self.apiKeyAccount, value: apiKey)
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.endpoint = defaults.string(forKey: Self.endpointKey) ?? Self.defaultEndpoint
        self.apiKey = Keychain.read(account: Self.apiKeyAccount) ?? ""
    }

    var isConfigured: Bool {
        !apiKey.isEmpty && URL(string: endpoint) != nil
    }

    var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey)
    }

    func markLaunched() {
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
    }
}
