import AuthenticationServices
import SwiftUI

/// The first screen. Sign in with Apple only: no passwords to manage, no
/// phone numbers to verify, and no account details to store on a server.
struct SignInView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "video.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(Palette.record, in: .circle)

                Text("Typical Talk")
                    .font(.largeTitle.weight(.bold))

                Text("Record a take, send it, and they watch whenever they can. Transcripts stay on your phone.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    Task { await account.completeSignIn(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(Capsule())

                if account.isWorking {
                    ProgressView().tint(.white)
                }

                if let failure = account.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(Palette.record)
                        .multilineTextAlignment(.center)
                }

                Text("Apple shares your name once. Nothing else is collected.")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
