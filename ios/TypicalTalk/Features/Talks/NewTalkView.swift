import SwiftUI

/// Start a talk with someone. Picking a person opens the recorder pointed at
/// that thread, because a talk with no take in it is not a talk yet.
struct NewTalkView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var start: (Talk.ID) -> Void

    @State private var search = ""

    /// Everyone you already talk to, plus anyone invited from contacts.
    private var people: [Person] {
        var seen = Set<UUID>()
        var result: [Person] = []
        for person in store.talks.flatMap(\.members) where !person.isYou {
            if seen.insert(person.id).inserted { result.append(person) }
        }
        for name in store.invitedContacts.sorted() where !result.contains(where: { $0.name == name }) {
            result.append(Person(name: name))
        }
        guard !search.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    ContentUnavailableView {
                        Label("No one here yet", systemImage: "person.2")
                    } description: {
                        Text("Find friends from your contacts first, then start a talk with them.")
                    }
                } else {
                    List {
                        Section("Start a talk with") {
                            ForEach(people) { person in
                                Button { begin(with: person) } label: {
                                    HStack(spacing: 12) {
                                        Monogram(text: person.initials, size: Scale.Avatar.medium)
                                        Text(person.name).font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Image(systemName: "video.fill")
                                            .font(.caption)
                                            .foregroundStyle(Palette.record)
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Palette.raised)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .searchable(text: $search, prompt: "Search people")
                }
            }
            .background(Palette.canvas)
            .navigationTitle("New Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Reuses an existing one to one thread rather than making a duplicate.
    private func begin(with person: Person) {
        let existing = store.talks.first {
            $0.members.count == 2 && $0.members.contains { $0.name == person.name }
        }
        let id = existing?.id ?? store.startTalk(with: person)
        dismiss()
        start(id)
    }
}
