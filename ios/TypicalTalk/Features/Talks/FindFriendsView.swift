import SwiftUI

/// The Friends tab: the people you already talk to, your handle, and the two
/// ways to add someone.
///
/// Contact matching is gone. Sign in with Apple provides no phone number, so
/// there is nothing to match a contact against; a handle or an invite link is
/// how someone reaches you now.
struct FindFriendsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AccountStore.self) private var account

    @State private var handleField = ""
    @State private var handleError: String?
    @State private var search = ""
    @State private var found: TalkAPI.RemoteUser?
    @State private var searchNote: String?
    @State private var invite: TalkAPI.Invite?
    @State private var inviteCode = ""
    @State private var redeemNote: String?
    @State private var isBusy = false

    private var knownPeople: [Person] {
        var seen = Set<UUID>()
        return store.talks.flatMap(\.members)
            .filter { !$0.isYou && seen.insert($0.id).inserted }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                yourHandle
                addByHandle
                addByInvite
                if !knownPeople.isEmpty { people }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .task { handleField = account.account?.handle ?? "" }
    }

    // MARK: - Your handle

    private var yourHandle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your handle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)

            HStack(spacing: 8) {
                Text("@")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                TextField("handle", text: $handleField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.weight(.semibold))
                    .onChange(of: handleField) { _, new in
                        handleField = Self.sanitizeHandle(new)
                    }

                Button(account.account?.handle == nil ? "Claim" : "Save") {
                    Task {
                        handleError = await account.claimHandle(handleField)
                    }
                }
                .buttonStyle(.glass)
                .font(.caption.weight(.semibold))
                .disabled(handleField.isEmpty || account.isWorking)
            }
            .contentCard(padding: 12, radius: 18)

            Text(handleError ?? "This is how people find you. Three to twenty characters.")
                .font(.caption2)
                .foregroundStyle(handleError == nil ? Palette.secondaryText : Palette.record)
        }
    }

    // MARK: - Add by handle

    private var addByHandle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add by handle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)

            HStack(spacing: 8) {
                Text("@")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                TextField("their handle", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline)
                    .onChange(of: search) { _, new in
                        search = Self.sanitizeHandle(new)
                    }
                    .onSubmit { Task { await lookUp() } }

                Button("Find") { Task { await lookUp() } }
                    .buttonStyle(.glass)
                    .font(.caption.weight(.semibold))
                    .disabled(search.isEmpty || isBusy)
            }
            .contentCard(padding: 12, radius: 18)

            if let found {
                HStack(spacing: 12) {
                    Monogram(text: initials(found.name), size: Scale.Avatar.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(found.name).font(.subheadline.weight(.semibold))
                        Text("@\(found.handle ?? search)")
                            .font(.caption2)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Spacer()
                    Button("Start a talk") { Task { await startTalk(with: found) } }
                        .buttonStyle(.glassProminent)
                        .font(.caption.weight(.semibold))
                        .disabled(isBusy)
                }
                .contentCard(padding: 12, radius: 18)
            }

            if let searchNote {
                Text(searchNote)
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    // MARK: - Add by invite

    private var addByInvite: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invite someone")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)

            if let invite {
                ShareLink(item: URL(string: invite.url)!) {
                    Label("Share your invite link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)

                Text("Single use, and it expires in a week.")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                Button {
                    Task { await makeInvite() }
                } label: {
                    Label("Create an invite link", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(isBusy)
            }

            HStack(spacing: 8) {
                TextField("Paste an invite code", text: $inviteCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline)
                Button("Join") { Task { await redeem() } }
                    .buttonStyle(.glass)
                    .font(.caption.weight(.semibold))
                    .disabled(inviteCode.isEmpty || isBusy)
            }
            .contentCard(padding: 12, radius: 18)

            if let redeemNote {
                Text(redeemNote)
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On Typical Talk")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)

            ForEach(knownPeople) { person in
                HStack(spacing: 12) {
                    Monogram(text: person.initials, size: Scale.Avatar.small)
                    Text(person.name).font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .contentCard(padding: 12, radius: 18)
            }
        }
    }

    // MARK: - Actions

    private func lookUp() async {
        guard let token = account.account?.sessionToken else {
            searchNote = "Sign in again to search."
            return
        }
        isBusy = true
        defer { isBusy = false }
        found = nil
        searchNote = nil
        do {
            let match = try await TalkAPI.findUser(handle: search, token: token)
            found = match
            if match == nil { searchNote = "Nobody has that handle." }
        } catch {
            searchNote = error.localizedDescription
        }
    }

    private func startTalk(with user: TalkAPI.RemoteUser) async {
        guard let token = account.account?.sessionToken else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await TalkAPI.startTalk(with: user.id, token: token)
            store.startTalk(with: Person(name: user.name))
            searchNote = "Talk started with \(user.name)."
            found = nil
            search = ""
        } catch {
            searchNote = error.localizedDescription
        }
    }

    private func makeInvite() async {
        guard let token = account.account?.sessionToken else { return }
        isBusy = true
        defer { isBusy = false }
        invite = try? await TalkAPI.createInvite(token: token)
    }

    private func redeem() async {
        guard let token = account.account?.sessionToken else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await TalkAPI.redeemInvite(
                code: inviteCode.trimmingCharacters(in: .whitespaces),
                token: token
            )
            redeemNote = "You are connected. The talk is in Talks."
            inviteCode = ""
        } catch {
            redeemNote = error.localizedDescription
        }
    }

    /// Lower case letters, digits and underscores, 20 at most. Emoji, spaces
    /// and punctuation simply cannot be typed into a handle.
    static func sanitizeHandle(_ raw: String) -> String {
        String(raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(20))
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
