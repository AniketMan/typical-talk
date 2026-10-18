import AuthenticationServices
import SwiftUI

/// Profile and every app setting. There is no Settings tab by design.
struct YouView: View {
    @Environment(AppStore.self) private var store
    @Environment(AccountStore.self) private var account
    @State private var nameField = ""
    @State private var nameError: String?
    @State private var showStorage = false
    @State private var showBlocked = false
    @State private var showDelete = false

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

                Section {
                    Toggle("Notify me of new takes", isOn: $store.notificationsEnabled)
                        .onChange(of: store.notificationsEnabled) { _, enabled in
                            store.scheduleSave()
                            Task {
                                if enabled { await PushRegistrar.shared.enable() }
                                else { await PushRegistrar.shared.disable() }
                            }
                        }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Turning this off stops pushes on this phone. Takes still arrive when you open the app.")
                }
                .listRowBackground(Palette.raised)

                Section("Privacy and safety") {
                    Button("Blocked people") { showBlocked = true }
                }
                .listRowBackground(Palette.raised)

                Section("Storage") {
                    LabeledContent("Takes on this device", value: storageUsed)
                    Button("Manage storage") { showStorage = true }
                }
                .listRowBackground(Palette.raised)

                Section {
                    Button("Sign out", role: .destructive) { account.signOut() }
                    Button("Delete account", role: .destructive) { showDelete = true }
                } footer: {
                    Text("Deleting removes your takes, your talks and your account from Typical Talk for good.")
                }
                .listRowBackground(Palette.raised)

                Section("About") {
                    LabeledContent("Transcription", value: "On device")
                    LabeledContent("Version", value: Bundle.main.appVersion)
                }
                .listRowBackground(Palette.raised)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("You")
            .task { nameField = account.displayName }
            .navigationSubtitle("\(store.talks.count) talks")
            .sheet(isPresented: $showBlocked) {
                BlockedPeopleView()
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Palette.canvas)
            }
            .sheet(isPresented: $showDelete) {
                DeleteAccountView()
                    .presentationDetents([.medium])
                    .presentationBackground(Palette.canvas)
            }
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


extension Bundle {
    /// "1.0 (6)": the marketing version and the build.
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// People you have blocked, with a way back.
struct BlockedPeopleView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var people: [TalkAPI.BlockedPerson] = []
    @State private var isLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoaded, people.isEmpty {
                    ContentUnavailableView(
                        "No one blocked",
                        systemImage: "hand.raised",
                        description: Text("People you block cannot find you or send you takes.")
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(people) { person in
                    HStack {
                        Text(person.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Unblock") {
                            Task {
                                errorMessage = await store.unblock(person.id)
                                if errorMessage == nil { people.removeAll { $0.id == person.id } }
                            }
                        }
                        .buttonStyle(.glass)
                        .font(.caption.weight(.semibold))
                    }
                    .listRowBackground(Palette.raised)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Palette.record)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Blocked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                people = await store.blockedPeople()
                isLoaded = true
            }
        }
    }
}

/// Deleting an account asks you to confirm with Apple again. That proves it is
/// you and not someone holding an unlocked phone, and it gives the server the
/// code it needs to revoke Sign in with Apple as part of the deletion.
struct DeleteAccountView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Palette.record)

            Text("Delete your account?")
                .font(.title3.weight(.bold))

            Text("Your takes, your talks and your account are removed from Typical Talk for good. Other people keep the takes they already received from you only until they delete them. This cannot be undone.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                Task { await confirm(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(Capsule())
            .disabled(account.isWorking)

            if account.isWorking { ProgressView() }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Palette.record)
            }

            Button("Keep my account") { dismiss() }
                .font(.subheadline.weight(.semibold))
        }
        .padding(24)
    }

    private func confirm(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = error.localizedDescription
            }
        case .success(let authorization):
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential
            // Only the person who owns this account can confirm it.
            guard credential?.user == account.account?.userID else {
                errorMessage = "That is not the Apple ID this account uses."
                return
            }
            let code = credential?.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            errorMessage = await account.deleteAccount(authorizationCode: code)
            if errorMessage == nil { dismiss() }
        }
    }
}
