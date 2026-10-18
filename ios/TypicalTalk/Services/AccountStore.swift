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
        /// Our own id for this person, which is what the server and other
        /// phones know them by. Apple's `userID` above never leaves sign in.
        var serverID: String?
    }

    private(set) var account: Account?
    private(set) var failure: String?
    private(set) var isWorking = false

    var isSignedIn: Bool { account != nil }
    /// The id other phones know you by, as a UUID.
    var serverUUID: UUID? { account?.serverID.flatMap(UUID.init(uuidString:)) }
    var displayName: String { account?.name ?? "You" }

    private static let keychainKey = "com.typicaltalk.account"

    init() {
        #if DEBUG
        // Debug only: stand in for a signed-in account so the tabs can be
        // screenshotted without signing in to Apple.
        let environment = ProcessInfo.processInfo.environment
        if let token = environment["TT_PREVIEW_TOKEN"], let user = environment["TT_PREVIEW_USER"] {
            // Debug only: a session minted by a local server, so the whole
            // sync path can be driven without signing in to Apple.
            account = Account(
                userID: "preview",
                name: environment["TT_PREVIEW_NAME"] ?? "Preview",
                email: nil,
                sessionToken: token,
                handle: nil,
                serverID: user
            )
            return
        }
        if ProcessInfo.processInfo.arguments.contains("preview:signedin") {
            account = Account(userID: "preview", name: "Aniket", email: nil)
            return
        }
        #endif
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

    /// Fills in what an older sign in did not store, and notices a session
    /// that has ended.
    func ensureProfile() async throws {
        guard let token = account?.sessionToken else { return }
        do {
            let user = try await TalkAPI.me(token: token)
            account?.serverID = user.id
            account?.name = user.name
            account?.handle = user.handle
            save()
        } catch TalkAPI.Failure.unauthorized {
            sessionEnded()
            throw TalkAPI.Failure.unauthorized
        }
    }

    /// The server no longer accepts this session. Signing in again makes a
    /// new one.
    func sessionEnded() {
        signOut()
        failure = TalkAPI.Failure.unauthorized.errorDescription
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
            let authorizationCode = credential.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
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
                let session = try await TalkAPI.signIn(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    name: resolved.name
                )
                account?.sessionToken = session.token
                account?.serverID = session.user.id
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

    /// Accepts an invite code, from a link or pasted by hand.
    func redeem(inviteCode code: String) async -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "That invite link had no code in it." }
        guard let token = account?.sessionToken else { return "Sign in first." }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await TalkAPI.redeemInvite(code: trimmed, token: token)
            return "You are connected. The talk is in Talks."
        } catch {
            return error.localizedDescription
        }
    }

    /// Changes the name shown to other people.
    func rename(to name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "A name cannot be empty." }
        guard let token = account?.sessionToken else { return "Sign in first." }
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await TalkAPI.updateName(trimmed, token: token)
            account?.name = updated.name
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

    /// Deletes the account on the server, then forgets it here. Apple wants a
    /// fresh authorization code with this so the Sign in with Apple link is
    /// revoked as well.
    func deleteAccount(authorizationCode: String?) async -> String? {
        guard let token = account?.sessionToken else { return "Sign in first." }
        isWorking = true
        defer { isWorking = false }
        do {
            try await TalkAPI.deleteAccount(authorizationCode: authorizationCode, token: token)
            signOut(unregisteringPush: false)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signOut(unregisteringPush: Bool = true) {
        if unregisteringPush, let token = account?.sessionToken {
            // Without this the phone would keep getting this person's pushes.
            Task { await PushRegistrar.shared.unregister(sessionToken: token) }
        }
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
