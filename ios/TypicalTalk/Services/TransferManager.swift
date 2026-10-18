import Foundation

/// What became of a transfer, in the terms the store cares about.
enum TransferOutcome: Sendable, Equatable {
    case success
    /// Worth trying again: no connection, a busy server, a timeout.
    case retryable(String)
    /// Trying again will not help: the server refused this take.
    case permanent(String)
    /// The session is no longer valid.
    case unauthorized
}

/// Who hears about transfers. The store adopts this.
@MainActor
protocol TransferDelegate: AnyObject, Sendable {
    func uploadDidProgress(_ takeID: UUID, fraction: Double)
    func uploadDidFinish(_ takeID: UUID, outcome: TransferOutcome)
    func downloadDidProgress(_ takeID: UUID, fraction: Double)
    func downloadDidFinish(_ takeID: UUID, fileName: String?, outcome: TransferOutcome)
}

/// Moves takes to and from the server on a background URLSession.
///
/// A background session is run by the system, not the app, so an upload keeps
/// going when you leave the app, waits for a connection when there is none,
/// and reports back even if the app was closed in the meantime. That is the
/// difference between "Sending" meaning something and not.
final class TransferManager: NSObject, @unchecked Sendable {
    static let shared = TransferManager()

    private static let identifier = "com.typicaltalk.TypicalTalk.transfers"

    private let lock = NSLock()
    private weak var delegate: (any TransferDelegate)?
    private var backgroundCompletion: (@Sendable () -> Void)?
    private var received: [Int: Data] = [:]
    private var lastReported: [Int: Double] = [:]
    /// Downloads already settled in `didFinishDownloadingTo`, so
    /// `didCompleteWithError` does not report them a second time.
    private var settled: Set<Int> = []

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Wiring

    func setDelegate(_ delegate: any TransferDelegate) {
        lock.withLock { self.delegate = delegate }
        // Touching the session reattaches to anything still in flight from a
        // previous launch.
        _ = session
    }

    /// The system's completion handler, which has to be called once every
    /// pending event has been delivered.
    func setBackgroundCompletion(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundCompletion = completion }
        _ = session
    }

    // MARK: - Starting

    struct Active: Sendable {
        var uploads: Set<UUID> = []
        var downloads: Set<UUID> = []
    }

    /// What the system is already working on, so nothing is started twice.
    func active() async -> Active {
        var result = Active()
        for task in await session.allTasks where task.state == .running || task.state == .suspended {
            guard let (kind, id) = Self.parse(task.taskDescription) else { continue }
            if kind == "up" { result.uploads.insert(id) } else { result.downloads.insert(id) }
        }
        return result
    }

    func upload(
        takeID: UUID,
        talkID: UUID,
        file: URL,
        duration: Double,
        voiceOnly: Bool,
        token: String
    ) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            notify { $0.uploadDidFinish(takeID, outcome: .permanent("That take's video is missing from this phone.")) }
            return
        }
        let path = "/v1/talks/\(talkID.uuidString.lowercased())/takes/\(takeID.uuidString.lowercased())"
        var request = URLRequest(url: TalkAPI.base.appending(path: path))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        request.setValue(String(format: "%.2f", duration), forHTTPHeaderField: "x-take-duration")
        request.setValue(voiceOnly ? "1" : "0", forHTTPHeaderField: "x-take-voice-only")

        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = "up:\(takeID.uuidString)"
        task.resume()
    }

    func download(takeID: UUID, token: String) {
        var request = URLRequest(url: TalkAPI.base.appending(path: "/v1/takes/\(takeID.uuidString.lowercased())/file"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.downloadTask(with: request)
        task.taskDescription = "down:\(takeID.uuidString)"
        task.resume()
    }

    /// Sign out and account deletion: nothing should keep running as someone
    /// who is no longer signed in.
    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    // MARK: - Helpers

    private static func parse(_ description: String?) -> (String, UUID)? {
        guard let parts = description?.split(separator: ":", maxSplits: 1),
              parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        return (String(parts[0]), id)
    }

    private func notify(_ action: @escaping @MainActor (any TransferDelegate) -> Void) {
        let target = lock.withLock { delegate }
        guard let target else { return }
        Task { @MainActor in action(target) }
    }

    private func classify(status: Int?, error: (any Error)?, body: Data?) -> TransferOutcome? {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return nil }
            return .retryable("No connection.")
        }
        guard let status else { return .retryable("No answer from Typical Talk.") }
        if (200..<300).contains(status) { return .success }
        if status == 401 { return .unauthorized }

        let message = body
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0)["error"] }
        if status == 408 || status == 429 || status >= 500 {
            return .retryable(message ?? "Typical Talk is busy. Trying again shortly.")
        }
        return .permanent(message ?? "Typical Talk refused this take (\(status)).")
    }
}

extension TransferManager: URLSessionDataDelegate, URLSessionDownloadDelegate {
    // The response body of an upload, kept only to read an error out of.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            var body = received[dataTask.taskIdentifier] ?? Data()
            if body.count < 4096 { body.append(data) }
            received[dataTask.taskIdentifier] = body
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let (_, id) = Self.parse(task.taskDescription), totalBytesExpectedToSend > 0 else { return }
        report(task.taskIdentifier, fraction: Double(totalBytesSent) / Double(totalBytesExpectedToSend)) { delegate, fraction in
            delegate.uploadDidProgress(id, fraction: fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let (_, id) = Self.parse(downloadTask.taskDescription), totalBytesExpectedToWrite > 0 else { return }
        report(downloadTask.taskIdentifier, fraction: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) { delegate, fraction in
            delegate.downloadDidProgress(id, fraction: fraction)
        }
    }

    /// Progress is reported in steps of two percent, so a fast upload does not
    /// flood the main thread with redraws.
    private func report(
        _ taskID: Int,
        fraction: Double,
        _ action: @escaping @MainActor (any TransferDelegate, Double) -> Void
    ) {
        let shouldReport = lock.withLock { () -> Bool in
            let last = lastReported[taskID] ?? -1
            guard fraction - last >= 0.02 || fraction >= 1 else { return false }
            lastReported[taskID] = fraction
            return true
        }
        if shouldReport { notify { action($0, fraction) } }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let (_, id) = Self.parse(downloadTask.taskDescription) else { return }
        lock.withLock { _ = settled.insert(downloadTask.taskIdentifier) }

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        // A refusal is a small JSON error saved as if it were the video.
        guard let status, (200..<300).contains(status) else {
            let body = try? Data(contentsOf: location)
            let outcome: TransferOutcome
            if status == 410 {
                outcome = .permanent("expired")
            } else {
                outcome = classify(status: status, error: nil, body: body) ?? .retryable("")
            }
            notify { $0.downloadDidFinish(id, fileName: nil, outcome: outcome) }
            return
        }

        // The temporary file is deleted when this method returns, so it is
        // moved into place here, not later.
        if let name = TakeFiles.install(download: location, as: id) {
            notify { $0.downloadDidFinish(id, fileName: name, outcome: .success) }
        } else {
            notify { $0.downloadDidFinish(id, fileName: nil, outcome: .retryable("Could not save the take.")) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (body, alreadySettled) = lock.withLock { () -> (Data?, Bool) in
            lastReported[task.taskIdentifier] = nil
            return (received.removeValue(forKey: task.taskIdentifier), settled.remove(task.taskIdentifier) != nil)
        }
        guard let (kind, id) = Self.parse(task.taskDescription), !alreadySettled else { return }

        let status = (task.response as? HTTPURLResponse)?.statusCode
        guard let outcome = classify(status: status, error: error, body: body) else { return }
        if kind == "up" {
            notify { $0.uploadDidFinish(id, outcome: outcome) }
        } else {
            notify { $0.downloadDidFinish(id, fileName: nil, outcome: outcome) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
}
