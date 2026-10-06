import SwiftUI

/// Profile and every app setting. There is no Settings tab by design.
struct YouView: View {
    @Environment(AppStore.self) private var store
    @Environment(AccountStore.self) private var account
    @State private var nameField = ""
    @State private var nameError: String?
    @State private var showStorage = false

    private var storageUsed: String {
        let bytes = store.talks
            .flatMap(\.messages)
            .compactMap(\.localVideoURL)
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
        guard bytes > 0 else { return "Nothing yet" }
        return ByteCountFormatStyle(style: .file).format(Int64(bytes))
    }

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Monogram(text: String(account.displayName.prefix(1)).uppercased(), size: Scale.Avatar.profile)
                        VStack(alignment: .leading, spacing: 4) {
                            // Apple sends a name only on first sign-in, so it
                            // has to be editable rather than fixed forever.
                            TextField("Your name", text: $nameField)
                                .font(.headline)
                                .onChange(of: nameField) { _, new in
                                    // The server caps names at 40 characters.
                                    if new.count > 40 { nameField = String(new.prefix(40)) }
                                }
                                .submitLabel(.done)
                                .onSubmit {
                                    Task { nameError = await account.rename(to: nameField) }
                                }
                            Text(nameError ?? account.account?.email ?? "Signed in with Apple")
                                .font(.caption)
                                .foregroundStyle(nameError == nil ? Palette.secondaryText : Palette.record)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Palette.raised)

                Section("Playback") {
                    Toggle("Always show captions", isOn: $store.alwaysShowCaptions)
                    Toggle("Autoplay new takes", isOn: $store.autoplayNewTakes)
                }
                .listRowBackground(Palette.raised)

                Section("Notifications") {
                    Toggle("Reactions, mentions and receipts", isOn: $store.notificationsEnabled)
                }
                .listRowBackground(Palette.raised)

                Section("Storage") {
                    LabeledContent("Takes on this device", value: storageUsed)
                    Button("Manage storage") { showStorage = true }
                }
                .listRowBackground(Palette.raised)

                Section {
                    Button("Sign out", role: .destructive) { account.signOut() }
                }
                .listRowBackground(Palette.raised)

                Section("About") {
                    LabeledContent("Transcription", value: "On device")
                    LabeledContent("Version", value: "1.0")
                }
                .listRowBackground(Palette.raised)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("You")
            .task { nameField = account.displayName }
            .navigationSubtitle("\(store.talks.count) talks")
            .sheet(isPresented: $showStorage) {
                StorageView()
                    .presentationDetents([.medium])
                    .presentationBackground(Palette.canvas)
            }
        }
    }
}

/// Storage is the one thing that could ever cost server money, so it gets an
/// honest, per-thread breakdown rather than a single opaque number.
struct StorageView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.talks) { talk in
                    let local = talk.messages.filter { $0.localVideoURL != nil }
                    LabeledContent(talk.title) {
                        Text("^[\(local.count) take](inflect: true) on device")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .listRowBackground(Palette.raised)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
