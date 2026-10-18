import Foundation

/// The client for the Typical Talk Worker.
///
/// Only identity and delivery live on the server. Transcripts are made and
/// kept on the phone and never sent here. Moving the video files themselves is
/// `TransferManager`'s job, because those must survive the app being closed.
enum TalkAPI {
    static let base: URL = {
        #if DEBUG
        // Debug only: aim at a server running on this Mac.
        if let override = ProcessInfo.processInfo.environment["TT_API_BASE"], let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://typical-talk.anibhatt.workers.dev")!
    }()

    // MARK: - Shapes

    struct RemoteUser: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var email: String?
        var handle: String?
    }

    struct Session: Codable {
        var token: String
        var user: RemoteUser
    }

    struct Invite: Codable {
        var code: String
        var url: String
    }

    struct RemoteMember: Codable {
        let id: String
        let name: String
        let handle: String?
    }

    struct RemoteTake: Codable {
        let id: String
        let authorID: String
        let duration: Double
        let voiceOnly: Bool
        /// Milliseconds since 1970.
        let sentAt: Double
        let expired: Bool
        let watchedBy: [String]
    }

    struct RemoteTalk: Codable {
        let id: String
        let title: String?
        let isGroup: Bool
        let createdAt: Double
        let members: [RemoteMember]
        let takes: [RemoteTake]
    }

    struct TalksResponse: Codable {
        let talks: [RemoteTalk]
        let serverTime: Double
    }

    struct BlockedPerson: Codable, Identifiable {
        let id: String
        let name: String
    }

    enum ReportReason: String, CaseIterable, Identifiable, Sendable {
        case harassment, nudity, violence, spam, other
        var id: Self { self }

        var label: String {
            switch self {
            case .harassment: "Harassment or bullying"
            case .nudity: "Nudity or sexual content"
            case .violence: "Violence or threats"
            case .spam: "Spam"
            case .other: "Something else"
            }
        }
    }

    private struct ServerError: Decodable { let error: String }
    private struct Ack: Decodable { let ok: Bool }

    enum Failure: LocalizedError {
        case server(String)
        case offline
        /// The session is no longer valid: it expired, or the account is gone.
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .server(let message): message
            case .offline: "Could not reach Typical Talk."
            case .unauthorized: "Your session ended. Sign in again."
            }
        }
    }

    // MARK: - Identity

    /// Exchanges Apple's identity token for a session. The name is sent
    /// because Apple provides it only on the first sign-in; the authorization
    /// code lets the server remember how to revoke the link at deletion.
    static func signIn(identityToken: String, authorizationCode: String?, name: String) async throws -> Session {
        struct Body: Encodable { let identityToken: String; let authorizationCode: String?; let name: String }
        return try await send(
            "/v1/session", method: "POST",
            body: Body(identityToken: identityToken, authorizationCode: authorizationCode, name: name),
            token: nil
        )
    }

    static func me(token: String) async throws -> RemoteUser {
        struct Wrapper: Decodable { let user: RemoteUser }
        let result: Wrapper = try await send("/v1/me", method: "GET", token: token)
        return result.user
    }

    /// Apple sends a name only on the very first sign-in, so it has to be
    /// correctable afterwards.
    static func updateName(_ name: String, token: String) async throws -> RemoteUser {
        struct Body: Encodable { let name: String }
        struct Updated: Decodable { let user: RemoteUser }
        let result: Updated = try await send("/v1/me", method: "PUT", body: Body(name: name), token: token)
        return result.user
    }

    static func claimHandle(_ handle: String, token: String) async throws -> String {
        struct Body: Encodable { let handle: String }
        struct Claimed: Decodable { let handle: String }
        let result: Claimed = try await send("/v1/me/handle", method: "PUT", body: Body(handle: handle), token: token)
        return result.handle
    }

    /// Deletes the account and everything in it. A fresh Apple authorization
    /// code lets the server revoke Sign in with Apple as well.
    static func deleteAccount(authorizationCode: String?, token: String) async throws {
        struct Body: Encodable { let authorizationCode: String? }
        let _: Ack = try await send(
            "/v1/me", method: "DELETE", body: Body(authorizationCode: authorizationCode), token: token
        )
    }

    // MARK: - Friends

    static func findUser(handle: String, token: String) async throws -> RemoteUser? {
        struct Found: Decodable { let user: RemoteUser? }
        var components = URLComponents(url: base.appending(path: "/v1/users"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "handle", value: handle)]
        let found: Found = try await send(url: components.url!, method: "GET", token: token)
        return found.user
    }

    static func createInvite(token: String) async throws -> Invite {
        try await send("/v1/invites", method: "POST", token: token)
    }

    @discardableResult
    static func redeemInvite(code: String, token: String) async throws -> String {
        struct Redeemed: Decodable { let talkID: String }
        let result: Redeemed = try await send("/v1/invites/\(code)/redeem", method: "POST", token: token)
        return result.talkID
    }

    // MARK: - Talks

    @discardableResult
    static func startTalk(with userID: String, token: String) async throws -> String {
        struct Body: Encodable { let userID: String }
        struct Started: Decodable { let talkID: String }
        let result: Started = try await send("/v1/talks", method: "POST", body: Body(userID: userID), token: token)
        return result.talkID
    }

    @discardableResult
    static func startGroup(with userIDs: [String], title: String?, token: String) async throws -> String {
        struct Body: Encodable { let userIDs: [String]; let title: String? }
        struct Started: Decodable { let talkID: String }
        let result: Started = try await send(
            "/v1/talks", method: "POST", body: Body(userIDs: userIDs, title: title), token: token
        )
        return result.talkID
    }

    static func addMember(_ userID: String, to talkID: String, token: String) async throws {
        struct Body: Encodable { let userID: String }
        let _: Ack = try await send(
            "/v1/talks/\(talkID.lowercased())/members", method: "POST", body: Body(userID: userID), token: token
        )
    }

    static func leave(talk talkID: String, token: String) async throws {
        let _: Ack = try await send("/v1/talks/\(talkID.lowercased())/membership", method: "DELETE", token: token)
    }

    /// Everything that changed since `since`, which is the `serverTime` of the
    /// previous call (0 for everything).
    static func talks(since: Double, token: String) async throws -> TalksResponse {
        var components = URLComponents(url: base.appending(path: "/v1/talks"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: String(Int64(since)))]
        return try await send(url: components.url!, method: "GET", token: token)
    }

    static func markWatched(take takeID: String, token: String) async throws {
        let _: Ack = try await send("/v1/takes/\(takeID.lowercased())/watched", method: "POST", token: token)
    }

    // MARK: - Push

    static func registerDevice(token deviceToken: String, environment: String, token: String) async throws {
        struct Body: Encodable { let token: String; let environment: String }
        let _: Ack = try await send(
            "/v1/devices", method: "PUT", body: Body(token: deviceToken, environment: environment), token: token
        )
    }

    static func unregisterDevice(token deviceToken: String, token: String) async throws {
        let _: Ack = try await send("/v1/devices/\(deviceToken)", method: "DELETE", token: token)
    }

    // MARK: - Safety

    static func blocked(token: String) async throws -> [BlockedPerson] {
        struct Wrapper: Decodable { let blocked: [BlockedPerson] }
        let result: Wrapper = try await send("/v1/blocks", method: "GET", token: token)
        return result.blocked
    }

    static func block(user userID: String, token: String) async throws {
        struct Body: Encodable { let userID: String }
        let _: Ack = try await send("/v1/blocks", method: "POST", body: Body(userID: userID), token: token)
    }

    static func unblock(user userID: String, token: String) async throws {
        let _: Ack = try await send("/v1/blocks/\(userID.lowercased())", method: "DELETE", token: token)
    }

    static func report(take takeID: String, reason: ReportReason, details: String?, token: String) async throws {
        struct Body: Encodable { let takeID: String; let reason: String; let details: String? }
        let _: Ack = try await send(
            "/v1/reports", method: "POST",
            body: Body(takeID: takeID.lowercased(), reason: reason.rawValue, details: details),
            token: token
        )
    }

    // MARK: - Transport

    private struct NoBody: Encodable {}

    private static func send<T: Decodable>(
        _ path: String,
        method: String,
        token: String?
    ) async throws -> T {
        try await send(url: base.appending(path: path), method: method, token: token)
    }

    private static func send<T: Decodable, B: Encodable>(
        _ path: String,
        method: String,
        body: B,
        token: String?
    ) async throws -> T {
        try await send(url: base.appending(path: path), method: method, body: body, token: token)
    }

    private static func send<T: Decodable>(
        url: URL,
        method: String,
        token: String?
    ) async throws -> T {
        try await send(url: url, method: method, body: Optional<NoBody>.none, token: token)
    }

    private static func send<T: Decodable, B: Encodable>(
        url: URL,
        method: String,
        body: B?,
        token: String?
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.offline
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.offline }
        guard (200..<300).contains(http.statusCode) else {
            // A bad token on an authenticated call means the session is over.
            // On sign in the same status means Apple's token was refused.
            if http.statusCode == 401, token != nil { throw Failure.unauthorized }
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw Failure.server(message ?? "Something went wrong (\(http.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
