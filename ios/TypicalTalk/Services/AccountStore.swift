import AuthenticationServices
import Observation
import Security

/// The signed-in account.
///
/// Sign in with Apple gives a stable user identifier and, only on the very
/// first sign-in, a name. Apple never sends the name again, so it is stored
/// alongside the identifier rather than fetched later.
@MainActor
@Observable
final class AccountStore {
    struct Account: Codable, Equatable {
        var userID: String
        var name: String
        var email: String?
        /// The session token from our server, and the handle it knows about.
        var sessionToken: String?
        var handle: String?
    }

    private(set) var account: Account?
    private(set) var failure: String?
    private(set) var isWorking = false

    var isSignedIn: Bool { account != nil }
    var displayName: String { account?.name ?? "You" }

    private static let keychainKey = "com.typicaltalk.account"

    init() {
        account = Keychain.read(Self.keychainKey).flatMap {
            try? JSONDecoder().decode(Account.self, from: $0)
        }
    }

    /// Confirms the account is still valid. Apple revokes a credential when
    /// the user removes the app from their Apple ID, and a stale sign-in
    /// should not silently keep working.
    func refresh() async {
        guard let account else { return }
        let provider = ASAuthorizationAppleIDProvider()
        let state = try? await provider.credentialState(forUserID: account.userID)
        if state == .revoked || state == .notFound { signOut() }
    }

    /// Apple identifies the person; the server then issues our own session.
    func completeSignIn(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case .failure(let error):
            // Cancelling is a choice, not a failure worth reporting.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            failure = error.localizedDescription

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                failure = "That sign-in did not come back from Apple."
                return
            }
            // The name arrives only on first sign-in; keep any existing one.
            let provided = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            let resolved = Account(
                userID: credential.user,
                name: provided.isEmpty ? (account?.name ?? "You") : provided,
                email: credential.email ?? account?.email
            )
            account = resolved
            failure = nil
            save()

            guard let identityToken = credential.identityToken
                .flatMap({ String(data: $0, encoding: .utf8) }) else {
                failure = "Apple did not return a sign-in token."
                return
            }

            isWorking = true
            defer { isWorking = false }
            do {
                let session = try await TalkAPI.signIn(identityToken: identityToken, name: resolved.name)
                account?.sessionToken = session.token
                account?.handle = session.user.handle
                account?.name = session.user.name
                save()
            } catch {
                // Signed in with Apple but not with our server: say so rather
                // than pretending the account is ready.
                failure = error.localizedDescription
            }
        }
    }

    /// Claims or changes the handle people can find you by.
    func claimHandle(_ handle: String) async -> String? {
        guard let token = account?.sessionToken else { return "Not signed in to Typical Talk." }
        isWorking = true
        defer { isWorking = false }
        do {
            account?.handle = try await TalkAPI.claimHandle(handle, token: token)
            save()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func save() {
        guard let account, let data = try? JSONEncoder().encode(account) else { return }
        Keychain.write(data, for: Self.keychainKey)
    }

    func signOut() {
        account = nil
        Keychain.delete(Self.keychainKey)
    }
}

/// Minimal Keychain access. The credential belongs here rather than in
/// UserDefaults because it identifies the account.
enum Keychain {
    static func write(_ data: Data, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
