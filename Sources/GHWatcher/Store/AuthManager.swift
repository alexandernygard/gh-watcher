import Foundation
import Observation
import Security

enum Keychain {
    static let service = "dev.nygard.GHWatcher"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Reads the token the GitHub CLI already has, so there is nothing to paste.
enum GHCLI {
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    static var path: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func token() async -> String? {
        guard let path else { return nil }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["auth", "token"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch { return nil }
            guard process.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        }.value
    }
}

@MainActor
@Observable
final class AuthManager {
    enum Source: String { case ghCLI, manual }

    private(set) var source: Source? {
        didSet { UserDefaults.standard.set(source?.rawValue, forKey: "authSource") }
    }
    var isWorking = false
    var error: String?

    init() {
        source = UserDefaults.standard.string(forKey: "authSource").flatMap(Source.init(rawValue:))
    }

    var ghCLIAvailable: Bool { GHCLI.path != nil }

    /// Token to use at launch, without user interaction.
    func resolveToken() async -> String? {
        switch source {
        case .manual:
            return Keychain.load(account: "token")
        case .ghCLI:
            return await GHCLI.token()
        case nil:
            if UserDefaults.standard.bool(forKey: "signedOut") { return nil }
            if let token = await GHCLI.token() {
                source = .ghCLI
                return token
            }
            return nil
        }
    }

    func useGHCLI() async -> String? {
        guard let token = await GHCLI.token() else {
            error = ghCLIAvailable
                ? "The GitHub CLI is installed but not signed in. Run `gh auth login` first."
                : "The GitHub CLI (gh) was not found."
            return nil
        }
        source = .ghCLI
        UserDefaults.standard.set(false, forKey: "signedOut")
        return token
    }

    func useManual(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(trimmed, account: "token")
        source = .manual
        UserDefaults.standard.set(false, forKey: "signedOut")
        return trimmed
    }

    func signOut() {
        Keychain.delete(account: "token")
        source = nil
        UserDefaults.standard.set(true, forKey: "signedOut")
    }
}
