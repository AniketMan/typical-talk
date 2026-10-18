import Foundation
import Observation
import UserNotifications

/// Single source of truth for the app.
///
/// Talks live on the server so they reach other people, and are mirrored to a
/// file on the phone so the app opens instantly and works without a
/// connection. Transcripts are made here and never leave.
@MainActor
@Observable
final class AppStore: TransferDelegate {
    var talks: [Talk]
    var bookmarks: [Bookmark]
    var highlights: [Highlight]
    var notifications: [AppNotification]

    // Preferences surfaced in the You tab.
    var alwaysShowCaptions = false
    var autoplayNewTakes = false
    var notificationsEnabled = true

    /// Where the user got to in each take. Leaving a thread, recording a
    /// reply, or switching takes all come back to the same second.
    private var playbackPositions: [Message.ID: Double] = [:]

    // MARK: Sync state

    private(set) var isSyncing = false
    /// True when the last attempt could not reach the server, so the list
    /// shown is what the phone remembers.
    private(set) var lastSyncFailed = false
    /// False until the first answer from the server, so an empty list can be
    /// told apart from one that has not loaded yet.
    private(set) var hasSynced = false

    /// 0...1 for takes being sent or fetched right now.
    private(set) var uploadProgress: [Message.ID: Double] = [:]
    private(set) var downloadProgress: [Message.ID: Double] = [:]
    /// Why a take could not be sent, when the server said.
    private(set) var failureNotes: [Message.ID: String] = [:]

    @ObservationIgnored private weak var account: AccountStore?
    @ObservationIgnored private var cursor: Double = 0
    @ObservationIgnored private var pendingWatched: Set<UUID> = []
    @ObservationIgnored private var retries: [UUID: Int] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionChain: Task<Void, Never>?
    @ObservationIgnored private var loadedSnapshotFor: UUID?

    init() {
        talks = []
        bookmarks = []
        highlights = []
        notifications = []
    }

    // MARK: - Identity

    /// You, as the author of your own takes.
    var me: Person {
        Person(
            id: account?.serverUUID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: account?.account?.name ?? "You",
            isYou: true
        )
    }

    private var token: String? { account?.account?.sessionToken }

    /// Connects the store to the signed-in account and restores what the
    /// phone remembers of it.
    func attach(_ account: AccountStore) {
        self.account = account
        TransferManager.shared.setDelegate(self)
        loadSnapshot()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var userID: String
        var cursor: Double
        var talks: [Talk]
        var bookmarks: [Bookmark]
        var positions: [String: Double]
        var pendingWatched: [String]
        var clearedAt: Date?
        var alwaysShowCaptions: Bool
        var autoplayNewTakes: Bool
        var notificationsEnabled: Bool
    }

    private static let stateURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.json")
    }()

    private func loadSnapshot() {
        guard let id = account?.serverUUID, loadedSnapshotFor != id else { return }
        loadedSnapshotFor = id
        guard let data = try? Data(contentsOf: Self.stateURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.userID == id.uuidString else { return }

        talks = snapshot.talks
        bookmarks = snapshot.bookmarks
        cursor = snapshot.cursor
        playbackPositions = Dictionary(uniqueKeysWithValues: snapshot.positions.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
        pendingWatched = Set(snapshot.pendingWatched.compactMap(UUID.init(uuidString:)))
        notificationsClearedAt = snapshot.clearedAt
        alwaysShowCaptions = snapshot.alwaysShowCaptions
        autoplayNewTakes = snapshot.autoplayNewTakes
        notificationsEnabled = snapshot.notificationsEnabled
    }

    /// Writes soon, not on every change: playback position alone changes
    /// many times a second.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let id = account?.serverUUID else { return }
        let snapshot = Snapshot(
            userID: id.uuidString,
            cursor: cursor,
            talks: talks,
            bookmarks: bookmarks,
            positions: Dictionary(uniqueKeysWithValues: playbackPositions.map { ($0.key.uuidString, $0.value) }),
            pendingWatched: pendingWatched.map(\.uuidString),
            clearedAt: notificationsClearedAt,
            alwaysShowCaptions: alwaysShowCaptions,
            autoplayNewTakes: autoplayNewTakes,
            notificationsEnabled: notificationsEnabled
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = Self.stateURL
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Forgets everything: sign out, and account deletion. The next person to
    /// sign in on this phone starts from nothing.
    func reset() {
        TransferManager.shared.cancelAll()
        saveTask?.cancel()
        TakeFiles.removeAll()
        try? FileManager.default.removeItem(at: Self.stateURL)
        talks = []
        bookmarks = []
        highlights = []
        notifications = []
        playbackPositions = [:]
        pendingWatched = []
        retries = [:]
        uploadProgress = [:]
        downloadProgress = [:]
        failureNotes = [:]
        notificationsClearedAt = nil
        cursor = 0
        hasSynced = false
        lastSyncFailed = false
        loadedSnapshotFor = nil
        PushRegistrar.shared.setBadge(0)
    }

    // MARK: - Sync

    /// Brings this phone in line with the server and finishes anything that
    /// was waiting: uploads, downloads, and watch receipts. Safe to call as
    /// often as you like; a call while one is running does nothing.
    func sync() async {
        guard !isSyncing, let account, let token else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            if account.serverUUID == nil {
                try await account.ensureProfile()
                loadSnapshot()
            }
            let response = try await TalkAPI.talks(since: cursor, token: token)
            merge(response)
            cursor = response.serverTime
            lastSyncFailed = false
            hasSynced = true
            scheduleSave()
            updateBadge()
            await flushWatched()
            await resumeTransfers()
        } catch TalkAPI.Failure.unauthorized {
            account.sessionEnded()
        } catch {
            lastSyncFailed = true
        }
    }

    private func merge(_ response: TalkAPI.TalksResponse) {
        guard let myID = account?.serverUUID else { return }
        var known = Dictionary(talks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var present = Set<UUID>()

        for remote in response.talks {
            guard let talkID = UUID(uuidString: remote.id) else { continue }
            present.insert(talkID)

            let members = remote.members.compactMap { member -> Person? in
                UUID(uuidString: member.id).map { Person(id: $0, name: member.name, isYou: $0 == myID) }
            }
            var talk = known[talkID] ?? Talk(
                id: talkID,
                title: "",
                members: members,
                messages: [],
                isGroupTalk: remote.isGroup,
                createdAt: Date(timeIntervalSince1970: remote.createdAt / 1000)
            )
            talk.members = members
            talk.isGroupTalk = remote.isGroup
            talk.title = Self.title(of: remote, members: members)

            for take in remote.takes {
                guard let takeID = UUID(uuidString: take.id),
                      let authorID = UUID(uuidString: take.authorID) else { continue }
                let sentAt = Date(timeIntervalSince1970: take.sentAt / 1000)
                let watchers = take.watchedBy.compactMap(UUID.init(uuidString:))

                if let index = talk.messages.firstIndex(where: { $0.id == takeID }) {
                    talk.messages[index].watchedBy = watchers
                    if authorID == myID {
                        talk.messages[index].delivery = .sent
                        talk.messages[index].sentAt = sentAt
                    } else if watchers.contains(myID) {
                        talk.messages[index].watched = true
                    }
                    // Gone from the server and never downloaded: nothing to show.
                    if take.expired, talk.messages[index].fileName == nil {
                        talk.messages.remove(at: index)
                    }
                } else if !take.expired {
                    let author = members.first { $0.id == authorID }
                        ?? Person(id: authorID, name: "Former member")
                    talk.messages.append(Message(
                        id: takeID,
                        author: author,
                        sentAt: sentAt,
                        duration: take.duration,
                        isVoiceOnly: take.voiceOnly,
                        watched: authorID == myID || watchers.contains(myID),
                        watchedBy: watchers
                    ))
                }
            }

            talk.messages.sort { $0.sentAt > $1.sentAt }
            // Names change; the copy stored on each take should follow.
            for index in talk.messages.indices {
                if let current = members.first(where: { $0.id == talk.messages[index].author.id }) {
                    talk.messages[index].author = current
                }
            }
            known[talkID] = talk
        }

        // Anything the server no longer lists was left, blocked or deleted.
        let removed = talks.filter { !present.contains($0.id) }
        for talk in removed { deleteFiles(of: talk.messages) }
        talks = known.values
            .filter { present.contains($0.id) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func title(of remote: TalkAPI.RemoteTalk, members: [Person]) -> String {
        let others = members.filter { !$0.isYou }
        guard remote.isGroup else { return others.first?.name ?? "Just you" }
        if let title = remote.title, !title.isEmpty { return title }

        let names = others.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
        switch names.count {
        case 0: return "Group"
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) & \(names.count - 2) more"
        }
    }

    private func updateBadge() {
        PushRegistrar.shared.setBadge(talks.reduce(0) { $0 + $1.unreadCount })
    }

    // MARK: - Transfers

    /// Starts whatever should be moving and is not: takes waiting to upload,
    /// and takes that have not been downloaded yet.
    private func resumeTransfers() async {
        guard let token else { return }
        let active = await TransferManager.shared.active()

        for talk in talks {
            for message in talk.messages {
                if message.author.isYou, message.delivery != .sent {
                    guard !active.uploads.contains(message.id), retries[message.id, default: 0] < 4 else { continue }
                    retries[message.id, default: 0] += 1
                    startUpload(message.id, in: talk.id)
                } else if message.fileName == nil, message.delivery == .sent {
                    guard !active.downloads.contains(message.id),
                          downloadProgress[message.id] == nil,
                          retries[message.id, default: 0] < 4 else { continue }
                    retries[message.id, default: 0] += 1
                    downloadProgress[message.id] = 0
                    TransferManager.shared.download(takeID: message.id, token: token)
                }
            }
        }
    }

    private func startUpload(_ messageID: Message.ID, in talkID: Talk.ID) {
        guard let token, let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }),
              let name = talks[t].messages[m].fileName else { return }
        let message = talks[t].messages[m]
        talks[t].messages[m].delivery = .sending
        failureNotes[messageID] = nil
        uploadProgress[messageID] = 0
        TransferManager.shared.upload(
            takeID: messageID,
            talkID: talkID,
            file: TakeFiles.url(for: name),
            duration: message.duration,
            voiceOnly: message.isVoiceOnly,
            token: token
        )
    }

    /// The person tapped Retry.
    func retry(_ messageID: Message.ID, in talkID: Talk.ID) {
        retries[messageID] = 0
        Task {
            guard !(await TransferManager.shared.active()).uploads.contains(messageID) else { return }
            startUpload(messageID, in: talkID)
        }
    }

    /// The person asked for a take that has not arrived to be fetched again.
    func retryDownload(_ messageID: Message.ID) {
        retries[messageID] = 0
        Task { await sync() }
    }

    /// Gives up on a take that could not be sent.
    func discard(_ messageID: Message.ID, in talkID: Talk.ID) {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }) else { return }
        deleteFiles(of: [talks[t].messages[m]])
        talks[t].messages.remove(at: m)
        uploadProgress[messageID] = nil
        failureNotes[messageID] = nil
        scheduleSave()
    }

    nonisolated func uploadDidProgress(_ takeID: UUID, fraction: Double) {
        Task { @MainActor in self.uploadProgress[takeID] = fraction }
    }

    nonisolated func uploadDidFinish(_ takeID: UUID, outcome: TransferOutcome) {
        Task { @MainActor in self.handleUpload(takeID, outcome) }
    }

    nonisolated func downloadDidProgress(_ takeID: UUID, fraction: Double) {
        Task { @MainActor in self.downloadProgress[takeID] = fraction }
    }

    nonisolated func downloadDidFinish(_ takeID: UUID, fileName: String?, outcome: TransferOutcome) {
        Task { @MainActor in self.handleDownload(takeID, fileName: fileName, outcome) }
    }

    private func handleUpload(_ takeID: UUID, _ outcome: TransferOutcome) {
        uploadProgress[takeID] = nil
        guard let (t, m) = locate(takeID) else { return }
        switch outcome {
        case .success:
            talks[t].messages[m].delivery = .sent
            failureNotes[takeID] = nil
        case .retryable(let note):
            talks[t].messages[m].delivery = .failed
            failureNotes[takeID] = note
        case .permanent(let note):
            talks[t].messages[m].delivery = .failed
            failureNotes[takeID] = note
            // Retrying a refusal only repeats it.
            retries[takeID] = 99
        case .unauthorized:
            talks[t].messages[m].delivery = .failed
            failureNotes[takeID] = TalkAPI.Failure.unauthorized.errorDescription
        }
        scheduleSave()
    }

    private func handleDownload(_ takeID: UUID, fileName: String?, _ outcome: TransferOutcome) {
        downloadProgress[takeID] = nil
        guard let (t, m) = locate(takeID) else {
            if let fileName { TakeFiles.remove(fileName) }
            return
        }
        switch outcome {
        case .success:
            talks[t].messages[m].fileName = fileName
            retries[takeID] = nil
            queueTranscription(takeID, in: talks[t].id)
        case .permanent:
            // Expired on the server before this phone fetched it.
            talks[t].messages.remove(at: m)
        case .retryable, .unauthorized:
            break
        }
        scheduleSave()
    }

    private func locate(_ messageID: Message.ID) -> (Int, Int)? {
        for t in talks.indices {
            if let m = talks[t].messages.firstIndex(where: { $0.id == messageID }) { return (t, m) }
        }
        return nil
    }

    private func deleteFiles(of messages: [Message]) {
        for message in messages {
            if let name = message.fileName { TakeFiles.remove(name) }
        }
    }

    // MARK: - Watch receipts

    private func flushWatched() async {
        guard let token else { return }
        for id in pendingWatched {
            do {
                try await TalkAPI.markWatched(take: id.uuidString, token: token)
                pendingWatched.remove(id)
            } catch TalkAPI.Failure.server {
                // The take is gone or was never ours to mark; stop asking.
                pendingWatched.remove(id)
            } catch {
                break
            }
        }
    }

    var unreadNotificationCount: Int { derivedNotifications.count }

    /// Highlights are built from transcripts already on the phone, never
    /// written in advance. A thread with nothing transcribed produces nothing.
    var derivedHighlights: [Highlight] {
        talks.compactMap { talk in
            let lines = talk.messages
                .filter { !$0.transcript.isEmpty }
                .prefix(4)
                .compactMap { $0.transcript.first?.text }
            guard lines.count >= 2 else { return nil }
            return Highlight(
                talkTitle: talk.title,
                subtitle: "^[\(talk.messages.count) take](inflect: true) on this device",
                points: Array(lines),
                duration: talk.messages.prefix(4).map(\.duration).reduce(0, +)
            )
        }
    }

    /// Notifications come from the model's own state: reactions that exist,
    /// and takes of yours that have been watched.
    /// Everything at or before this moment has been cleared by the user.
    var notificationsClearedAt: Date?

    func clearNotifications() {
        notificationsClearedAt = .now
        scheduleSave()
    }

    var derivedNotifications: [AppNotification] {
        var result: [AppNotification] = []
        for talk in talks {
            for message in talk.messages where message.author.isYou {
                if !message.reactions.isEmpty {
                    result.append(AppNotification(
                        kind: .reaction,
                        text: "\(message.reactions.joined()) on your take",
                        detail: talk.title,
                        at: message.sentAt
                    ))
                }
                if !message.watchedBy.isEmpty {
                    let names = message.watchedBy.compactMap { id in talk.members.first { $0.id == id }?.name }
                    result.append(AppNotification(
                        kind: .watchReceipt,
                        text: names.isEmpty
                            ? "Your take was watched"
                            : "\(names.joined(separator: ", ")) watched your take",
                        detail: talk.title,
                        at: message.sentAt
                    ))
                }
            }
        }
        if let cleared = notificationsClearedAt {
            result.removeAll { $0.at <= cleared }
        }
        return result.sorted { $0.at > $1.at }
    }

    func talk(id: Talk.ID) -> Talk? { talks.first { $0.id == id } }

    func binding(for id: Talk.ID) -> Int? { talks.firstIndex { $0.id == id } }

    private var transcribing: Set<Message.ID> = []

    /// Transcribes one take on device, once. Safe to call repeatedly.
    func ensureTranscript(for messageID: Message.ID, in talkID: Talk.ID) async {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }),
              talks[t].messages[m].transcript.isEmpty,
              let url = talks[t].messages[m].localVideoURL,
              transcribing.insert(messageID).inserted else { return }
        defer { transcribing.remove(messageID) }

        let duration = talks[t].messages[m].duration
        let segments = await Transcriber.segments(for: url)
        guard !segments.isEmpty else { return }

        // The store may have changed while that ran, so find the take again.
        guard let t2 = binding(for: talkID),
              let m2 = talks[t2].messages.firstIndex(where: { $0.id == messageID }) else { return }
        talks[t2].messages[m2].transcript = segments
        talks[t2].messages[m2].chapters = Self.chapters(from: segments, duration: duration)
        scheduleSave()
    }

    /// Transcribes a whole thread, newest first, one at a time.
    func ensureTranscripts(in talkID: Talk.ID) async {
        guard let t = binding(for: talkID) else { return }
        for message in talks[t].messages {
            await ensureTranscript(for: message.id, in: talkID)
        }
    }

    // MARK: - Resume

    func resumePosition(for messageID: Message.ID) -> Double {
        playbackPositions[messageID] ?? 0
    }

    /// Saves progress, unless the take is essentially finished, in which case
    /// it should start again from the top next time.
    func saveProgress(_ time: Double, for messageID: Message.ID, duration: Double) {
        defer { scheduleSave() }
        guard time > 0.4, duration > 0 else {
            playbackPositions[messageID] = nil
            return
        }
        // Scaled to the clip: a ten second take should not count as finished
        // with a second and a half still to run.
        let endZone = min(1.5, max(0.4, duration * 0.06))
        if time >= duration - endZone {
            playbackPositions[messageID] = nil
        } else {
            playbackPositions[messageID] = time
        }
    }

    func clearProgress(for messageID: Message.ID) {
        playbackPositions[messageID] = nil
    }

    // MARK: - Mutations

    func markWatched(messageID: Message.ID, in talkID: Talk.ID) {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }),
              !talks[t].messages[m].watched else { return }
        talks[t].messages[m].watched = true
        noteWatched(talks[t].messages[m])
    }

    func markAllWatched(in talkID: Talk.ID) {
        guard let t = binding(for: talkID) else { return }
        for i in talks[t].messages.indices where !talks[t].messages[i].watched {
            talks[t].messages[i].watched = true
            noteWatched(talks[t].messages[i])
        }
    }

    /// Queues the receipt for the sender, then tries to deliver it.
    private func noteWatched(_ message: Message) {
        if !message.author.isYou { pendingWatched.insert(message.id) }
        scheduleSave()
        updateBadge()
        Task { await flushWatched() }
    }

    func toggleReaction(_ emoji: String, messageID: Message.ID, in talkID: Talk.ID) {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }) else { return }
        if let existing = talks[t].messages[m].reactions.firstIndex(of: emoji) {
            talks[t].messages[m].reactions.remove(at: existing)
        } else {
            talks[t].messages[m].reactions.append(emoji)
        }
        scheduleSave()
    }

    /// Bookmarks a moment and files it in the Archive shelf in one step.
    func addBookmark(at time: Double, messageID: Message.ID, in talkID: Talk.ID) {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard !talks[t].messages[m].bookmarkedAt.contains(where: { abs($0 - time) < 0.5 }) else { return }
        talks[t].messages[m].bookmarkedAt.append(time)

        let message = talks[t].messages[m]
        let label = message.transcript
            .last(where: { $0.start <= time })?
            .text ?? "Saved moment"
        bookmarks.insert(
            Bookmark(
                title: String(label.prefix(42)),
                talkID: talkID,
                messageID: messageID,
                author: message.author,
                at: time,
                savedAt: .now
            ),
            at: 0
        )
        scheduleSave()
    }

    /// Files a freshly recorded take at the top of a thread and starts
    /// sending it. The file is taken into the takes folder first, because the
    /// recorder's copy is temporary and the upload has to outlive it.
    func send(take url: URL, duration: Double, transcript: [TranscriptSegment], voiceOnly: Bool, to talkID: Talk.ID) {
        guard let t = binding(for: talkID) else { return }
        let id = UUID()
        guard let fileName = TakeFiles.adopt(url, as: id) else { return }

        talks[t].messages.insert(
            Message(
                id: id,
                author: me,
                sentAt: .now,
                duration: duration,
                isVoiceOnly: voiceOnly,
                watched: true,
                delivery: .sending,
                transcript: transcript,
                chapters: Self.chapters(from: transcript, duration: duration),
                fileName: fileName
            ),
            at: 0
        )
        // Newest thread floats to the top of the Talks list.
        let moved = talks.remove(at: t)
        talks.insert(moved, at: 0)

        scheduleSave()
        startUpload(id, in: talkID)
    }

    // MARK: - Talks, groups and people

    /// Opens the one to one talk with someone, creating it on the server if
    /// there is not one yet.
    func openTalk(with person: Person) async -> (Talk.ID?, String?) {
        if let existing = talks.first(where: { !$0.isGroup && $0.members.contains { $0.id == person.id } }) {
            return (existing.id, nil)
        }
        guard let token else { return (nil, "Sign in first.") }
        do {
            let raw = try await TalkAPI.startTalk(with: person.id.uuidString, token: token)
            guard let id = UUID(uuidString: raw) else { return (nil, "Something went wrong.") }
            if talk(id: id) == nil {
                talks.insert(Talk(id: id, title: person.name, members: [me, person], messages: []), at: 0)
            }
            Task { await sync() }
            return (id, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    func createGroup(with people: [Person], title: String?) async -> (Talk.ID?, String?) {
        guard let token else { return (nil, "Sign in first.") }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let raw = try await TalkAPI.startGroup(
                with: people.map { $0.id.uuidString },
                title: trimmed?.isEmpty == false ? trimmed : nil,
                token: token
            )
            guard let id = UUID(uuidString: raw) else { return (nil, "Something went wrong.") }
            if talk(id: id) == nil {
                talks.insert(
                    Talk(id: id, title: trimmed ?? "Group", members: [me] + people, messages: [], isGroupTalk: true),
                    at: 0
                )
            }
            await sync()
            return (id, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    func addPeople(_ people: [Person], to talkID: Talk.ID) async -> String? {
        guard let token else { return "Sign in first." }
        do {
            for person in people {
                try await TalkAPI.addMember(person.id.uuidString, to: talkID.uuidString, token: token)
            }
            await sync()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func leave(_ talkID: Talk.ID) async -> String? {
        guard let token else { return "Sign in first." }
        do {
            try await TalkAPI.leave(talk: talkID.uuidString, token: token)
            if let talk = talk(id: talkID) { deleteFiles(of: talk.messages) }
            talks.removeAll { $0.id == talkID }
            scheduleSave()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Blocking and reporting

    /// Blocking hides their talk with you, and their takes in groups, and
    /// stops them finding you or sending you anything.
    func block(_ person: Person) async -> String? {
        guard let token else { return "Sign in first." }
        do {
            try await TalkAPI.block(user: person.id.uuidString, token: token)
        } catch {
            return error.localizedDescription
        }
        for talk in talks where !talk.isGroup && talk.members.contains(where: { $0.id == person.id }) {
            deleteFiles(of: talk.messages)
        }
        talks.removeAll { !$0.isGroup && $0.members.contains { $0.id == person.id } }
        for index in talks.indices {
            deleteFiles(of: talks[index].messages.filter { $0.author.id == person.id })
            talks[index].messages.removeAll { $0.author.id == person.id }
        }
        scheduleSave()
        updateBadge()
        return nil
    }

    func unblock(_ userID: String) async -> String? {
        guard let token else { return "Sign in first." }
        do {
            try await TalkAPI.unblock(user: userID, token: token)
            cursor = 0   // takes hidden while blocked need fetching again
            await sync()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func blockedPeople() async -> [TalkAPI.BlockedPerson] {
        guard let token else { return [] }
        return (try? await TalkAPI.blocked(token: token)) ?? []
    }

    /// Reports a take to the developer and removes it from this phone.
    func report(_ message: Message, in talkID: Talk.ID, reason: TalkAPI.ReportReason, details: String?) async -> String? {
        guard let token else { return "Sign in first." }
        do {
            try await TalkAPI.report(take: message.id.uuidString, reason: reason, details: details, token: token)
        } catch {
            return error.localizedDescription
        }
        discard(message.id, in: talkID)
        updateBadge()
        return nil
    }

    // MARK: - Transcription

    /// One transcription at a time: several downloads finishing together
    /// should not start several speech recognisers.
    private func queueTranscription(_ messageID: Message.ID, in talkID: Talk.ID) {
        let previous = transcriptionChain
        transcriptionChain = Task {
            await previous?.value
            await ensureTranscript(for: messageID, in: talkID)
        }
    }

    /// Cheap on-device segmentation: a chapter every time the speaker pauses
    /// for long enough that the next segment starts a new idea.
    static func chapters(from transcript: [TranscriptSegment], duration: Double) -> [Chapter] {
        guard !transcript.isEmpty else { return [] }
        var result: [Chapter] = [Chapter(start: 0, title: "Opening")]
        var lastCut = 0.0
        for segment in transcript.dropFirst() where segment.start - lastCut > 20 {
            result.append(Chapter(start: segment.start, title: String(segment.text.prefix(24))))
            lastCut = segment.start
        }
        return result
    }

    // MARK: - Search

    /// Full-text search across on-device transcripts. Case and diacritic
    /// insensitive so "cafe" finds "café".
    func search(_ query: String) -> [TranscriptMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var results: [TranscriptMatch] = []
        for talk in talks {
            for message in talk.messages {
                for segment in message.transcript
                where segment.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    results.append(TranscriptMatch(talk: talk, message: message, segment: segment))
                }
            }
        }
        return results.sorted { $0.message.sentAt > $1.message.sentAt }
    }
}
