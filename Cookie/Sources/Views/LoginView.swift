import SwiftUI

struct LoginView: View {
    @Environment(AuthenticationManager.self) private var auth
    @State private var isLoggingIn = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Cookie")
                    .font(.largeTitle.bold())
            }

            Spacer()

            if let errorMessage = auth.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                Task {
                    isLoggingIn = true
                    await auth.login()
                    isLoggingIn = false
                }
            } label: {
                if isLoggingIn {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Sign In")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoggingIn)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }
}

#Preview {
    LoginView()
        .environment(AuthenticationManager())
}
