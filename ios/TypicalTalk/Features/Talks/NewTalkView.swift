import SwiftUI

/// Start a talk with someone, or with several people as a group. Choosing
/// opens the recorder pointed at that thread, because a talk with no take in
/// it is not a talk yet.
struct NewTalkView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var start: (Talk.ID) -> Void

    @State private var search = ""
    @State private var selected: Set<UUID> = []
    @State private var groupName = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    /// Everyone you already talk to. People you have not talked to yet are
    /// added from the Friends tab first; a talk starts from a connection.
    private var people: [Person] {
        var seen = Set<UUID>()
        var result: [Person] = []
        for person in store.talks.flatMap(\.members) where !person.isYou {
            if seen.insert(person.id).inserted { result.append(person) }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !search.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var chosen: [Person] {
        people.filter { selected.contains($0.id) }
            + store.talks.flatMap(\.members).filter { selected.contains($0.id) && !people.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.talks.flatMap(\.members).allSatisfy(\.isYou) {
                    ContentUnavailableView {
                        Label("No one here yet", systemImage: "person.2")
                    } description: {
                        Text("Add someone from the Friends tab first, then start a talk with them.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(people) { person in
                                Button { toggle(person) } label: {
                                    HStack(spacing: 12) {
                                        Monogram(text: person.initials, size: Scale.Avatar.medium)
                                        Text(person.name).font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(person.id) ? Palette.record : Palette.secondaryText)
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Palette.raised)
                            }
                        } header: {
                            Text("Pick one person, or several for a group")
                        } footer: {
                            if let errorMessage {
                                Text(errorMessage).foregroundStyle(Palette.record)
                            }
                        }

                        if selected.count > 1 {
                            Section("Group name") {
                                TextField("Optional", text: $groupName)
                                    .onChange(of: groupName) { _, new in
                                        // The server caps names at 40 characters.
                                        if new.count > 40 { groupName = String(new.prefix(40)) }
                                    }
                            }
                            .listRowBackground(Palette.raised)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .searchable(text: $search, prompt: "Search people")
                    .safeAreaInset(edge: .bottom) { startButton }
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

    private var startButton: some View {
        Button {
            Task { await begin() }
        } label: {
            Group {
                if isWorking {
                    ProgressView()
                } else {
                    Text(selected.count > 1 ? "Start group" : "Start talk")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .disabled(selected.isEmpty || isWorking)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func toggle(_ person: Person) {
        errorMessage = nil
        if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
    }

    private func begin() async {
        isWorking = true
        defer { isWorking = false }

        let result: (Talk.ID?, String?)
        if selected.count == 1, let person = chosen.first {
            result = await store.openTalk(with: person)
        } else {
            result = await store.createGroup(with: chosen, title: groupName)
        }

        if let id = result.0 {
            dismiss()
            start(id)
        } else {
            errorMessage = result.1
        }
    }
}
