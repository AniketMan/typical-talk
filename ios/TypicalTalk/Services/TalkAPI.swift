import Foundation

/// The client for the Typical Talk Worker.
///
/// Only identity and delivery live on the server. Transcripts are made and
/// kept on the phone and never sent here.
enum TalkAPI {
    static let base = URL(string: "https://typical-talk.anibhatt.workers.dev")!

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

    private struct ServerError: Decodable { let error: String }

    enum Failure: LocalizedError {
        case server(String)
        case offline

        var errorDescription: String? {
            switch self {
            case .server(let message): message
            case .offline: "Could not reach Typical Talk."
            }
        }
    }

    /// Exchanges Apple's identity token for a session. The name is sent
    /// because Apple provides it only on the first sign-in.
    static func signIn(identityToken: String, name: String) async throws -> Session {
        try await send(
            "/v1/session",
            method: "POST",
            body: ["identityToken": identityToken, "name": name],
            token: nil
        )
    }

    static func claimHandle(_ handle: String, token: String) async throws -> String {
        struct Claimed: Codable { let handle: String }
        let result: Claimed = try await send(
            "/v1/me/handle",
            method: "PUT",
            body: ["handle": handle],
            token: token
        )
        return result.handle
    }

    static func findUser(handle: String, token: String) async throws -> RemoteUser? {
        struct Found: Codable { let user: RemoteUser? }
        var components = URLComponents(url: base.appending(path: "/v1/users"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "handle", value: handle)]
        let found: Found = try await send(url: components.url!, method: "GET", body: nil, token: token)
        return found.user
    }

    static func createInvite(token: String) async throws -> Invite {
        try await send("/v1/invites", method: "POST", body: nil, token: token)
    }

    @discardableResult
    static func redeemInvite(code: String, token: String) async throws -> String {
        struct Redeemed: Codable { let talkID: String }
        let result: Redeemed = try await send(
            "/v1/invites/\(code)/redeem",
            method: "POST",
            body: nil,
            token: token
        )
        return result.talkID
    }

    @discardableResult
    static func startTalk(with userID: String, token: String) async throws -> String {
        struct Started: Codable { let talkID: String }
        let result: Started = try await send(
            "/v1/talks",
            method: "POST",
            body: ["userID": userID],
            token: token
        )
        return result.talkID
    }

    // MARK: - Transport

    private static func send<T: Decodable>(
        _ path: String,
        method: String,
        body: [String: String]?,
        token: String?
    ) async throws -> T {
        try await send(url: base.appending(path: path), method: method, body: body, token: token)
    }

    private static func send<T: Decodable>(
        url: URL,
        method: String,
        body: [String: String]?,
        token: String?
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw Failure.server(message ?? "Something went wrong (\(http.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
