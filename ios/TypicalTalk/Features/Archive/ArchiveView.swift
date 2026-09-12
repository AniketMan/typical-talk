import SwiftUI

/// The search tab. Everything here reads transcripts already sitting on the
/// phone, which is why none of it costs anything.
struct ArchiveView: View {
    @Binding var query: String
    @Environment(AppStore.self) private var store
    @State private var scope: Scope = .transcripts

    enum Scope: String, CaseIterable, Identifiable {
        case transcripts = "Transcripts", saved = "Saved"
        var id: Self { self }
    }

    private var matches: [TranscriptMatch] { store.search(query) }
    private var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if isSearching {
                        results
                    } else {
                        Picker("Scope", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        switch scope {
                        case .transcripts: browse
                        case .saved: saved
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(Palette.canvas)
            .navigationTitle("Archive")
            .searchable(text: $query, prompt: "Search every word spoken")
            .searchToolbarBehavior(.minimize)
            .searchScopes($scope, activation: .onSearchPresentation) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .navigationDestination(for: Talk.ID.self) { ThreadView(talkID: $0) }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if matches.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 60)
        } else {
            sectionHeader("^[\(matches.count) match](inflect: true)", symbol: "text.magnifyingglass")
            ForEach(matches) { match in
                NavigationLink(value: match.talk.id) {
                    MatchRow(match: match, query: query)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Browse

    @ViewBuilder
    private var browse: some View {
        if store.derivedHighlights.isEmpty {
            emptyArchive
        } else {
            sectionHeader("Highlights", symbol: "sparkles")
            ForEach(store.derivedHighlights) { highlight in
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(highlight.talkTitle).font(.headline)
                        Text(highlight.subtitle)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(highlight.points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(Palette.secondaryText)
                                .padding(.top, 2)
                            Text(point).font(.subheadline)
                        }
                    }
                    Label("Play this moment (\(timecode(highlight.duration)))", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentCard()
            }
        }
    }

    // MARK: - Saved

    @ViewBuilder
    private var saved: some View {
        if store.bookmarks.isEmpty {
            ContentUnavailableView(
                "Nothing saved yet",
                systemImage: "bookmark",
                description: Text("Bookmark a moment while a take is playing and it lands here.")
            )
            .padding(.top, 60)
        } else {
            sectionHeader("Bookmarks", symbol: "bookmark")
            ForEach(store.bookmarks) { bookmark in
                NavigationLink(value: bookmark.talkID) {
                    HStack(spacing: 12) {
                        Monogram(text: bookmark.author.initials, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bookmark.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(bookmark.author.name) at \(timecode(bookmark.at))")
                                .font(.caption2)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        Spacer()
                        Text(relativeLabel(bookmark.savedAt))
                            .font(.caption2)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .contentCard(padding: 12, radius: 18)
                }
                .buttonStyle(.plain)
            }
            .onDelete { store.bookmarks.remove(atOffsets: $0) }
        }
    }

    private var emptyArchive: some View {
        ContentUnavailableView(
            "Your saved moments appear here",
            systemImage: "archivebox",
            description: Text("Record a take or bookmark a moment in a conversation to build your archive.")
        )
        .padding(.top, 60)
    }

    private func sectionHeader(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.secondaryText)
    }
}

/// One transcript hit, with the matched words highlighted in place.
struct MatchRow: View {
    let match: TranscriptMatch
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Monogram(text: match.message.author.initials, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.talk.title).font(.subheadline.weight(.semibold))
                    Text(match.message.author.name)
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer()
                Text(relativeLabel(match.message.sentAt))
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryText)
            }

            Text(highlighted)
                .font(.subheadline)
                .lineLimit(3)

            Label("Jump to \(timecode(match.segment.start))", systemImage: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }

    /// Bolds the query inside the snippet so the eye lands on the hit.
    private var highlighted: AttributedString {
        var text = AttributedString(match.segment.text)
        let term = query.trimmingCharacters(in: .whitespaces)
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text[cursor...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .subheadline.weight(.bold)
            text[range].foregroundColor = .white
            cursor = range.upperBound
        }
        return text
    }
}
