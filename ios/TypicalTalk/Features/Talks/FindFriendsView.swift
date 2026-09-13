import Contacts
import SwiftUI

/// The Friends tab: the people you already talk to, then matching device
/// contacts and invites. Falls back to an honest empty state when contact
/// access is refused.
struct FindFriendsView: View {
    @Environment(AppStore.self) private var store
    @State private var suggestions: [Suggestion] = []
    @State private var accessDenied = false
    @State private var isSyncing = false

    struct Suggestion: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var invited = false
    }

    private let inviteText = "Join me on Typical Talk for easy video messages."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if !knownPeople.isEmpty { knownPeopleList }
                actions
                if accessDenied {
                    deniedNotice
                } else if !suggestions.isEmpty {
                    suggestionList
                } else if store.contactsSynced {
                    caughtUp
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// Everyone you already have a talk with.
    private var knownPeople: [Person] {
        var seen = Set<UUID>()
        return store.talks.flatMap(\.members).filter { person in
            !person.isYou && seen.insert(person.id).inserted
        }
        .sorted { $0.name < $1.name }
    }

    private var knownPeopleList: some View {
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

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match contacts who already use Typical Talk, then invite anyone else you want here.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await sync() }
            } label: {
                Label(store.contactsSynced ? "Contacts synced" : "Sync contacts", systemImage: "person.2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            // The app tint is white, and a prominent button fills itself with
            // the tint, which put white text on a white fill.
            .tint(Palette.record)
            .controlSize(.extraLarge)
            // Once access is refused the button cannot do anything, so it
            // should not stand there looking like the next step.
            .disabled(store.contactsSynced || isSyncing || accessDenied)

            ShareLink(item: inviteText) {
                Label("Share an invite", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested contacts")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)

            ForEach(suggestions) { person in
                HStack(spacing: 12) {
                    Monogram(text: initials(person.name), size: Scale.Avatar.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.subheadline.weight(.semibold))
                        Text("In your contacts")
                            .font(.caption2)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Spacer()
                    if person.invited {
                        Label("Invited", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Palette.secondaryText)
                    } else {
                        Button("Invite") { invite(person) }
                            .buttonStyle(.glass)
                            .font(.caption.weight(.semibold))
                        Button("Skip") { skip(person) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .contentCard(padding: 12, radius: 18)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: suggestions)
    }

    private var deniedNotice: some View {
        ContentUnavailableView {
            Label("Contacts are off", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text("Typical Talk cannot see your contacts. Turn access on in Settings, or share an invite link instead.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.glass)
        }
    }

    private var caughtUp: some View {
        ContentUnavailableView(
            "You are all caught up",
            systemImage: "checkmark.circle",
            description: Text("Share an invite whenever someone new comes to mind.")
        )
    }

    // MARK: - Contacts

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        guard granted else {
            accessDenied = true
            return
        }
        let names = await Self.contactNames()
        withAnimation(.snappy(duration: 0.3)) {
            suggestions = names.map { Suggestion(name: $0) }
            store.contactsSynced = true
        }
    }

    /// Reads names on a background task. The store is created inside the task
    /// so nothing actor-isolated crosses the boundary.
    private static func contactNames() async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let store = CNContactStore()
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var names: [String] = []
            try? store.enumerateContacts(with: request) { contact, stop in
                let name = "\(contact.givenName) \(contact.familyName)"
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.append(name) }
                if names.count >= 25 { stop.pointee = true }
            }
            return names
        }.value
    }

    private func invite(_ person: Suggestion) {
        guard let index = suggestions.firstIndex(of: person) else { return }
        suggestions[index].invited = true
        store.invitedContacts.insert(person.name)
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.snappy(duration: 0.28)) {
                suggestions.removeAll { $0.id == person.id }
            }
        }
    }

    private func skip(_ person: Suggestion) {
        store.skippedContacts.insert(person.name)
        withAnimation(.snappy(duration: 0.28)) {
            suggestions.removeAll { $0.id == person.id }
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
