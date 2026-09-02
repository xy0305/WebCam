import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var username = ""
    @State private var password = ""
    @State private var showWeb = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("登录")
                    .font(.system(size: 34, weight: .bold))
                Text("登录后可同步关注，并带上账号 Cookie 解析直播。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 48)

            VStack(spacing: 12) {
                field("用户名", text: $username, secret: false)
                field("密码", text: $password, secret: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.top, 10)
            }

            Button {
                Task { await tryPasswordThenWeb() }
            } label: {
                Text("登录")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(Color.black, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .disabled(username.isEmpty || password.isEmpty || auth.busy)

            Button {
                showWeb = true
            } label: {
                Text(auth.busy ? "正在打开登录页…" : "网页登录（推荐，可过验证码）")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(Color.pink, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Button("先随便看看") {
                auth.enterGuest()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 16)

            Text("站点若弹出验证码，必须走网页登录。账号密码只提交给官网，不会存进这个 App。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 24)

            Spacer()
        }
        .background(Color.white.ignoresSafeArea())
        .sheet(isPresented: $showWeb) {
            WebLoginView { name in
                showWeb = false
                if let name {
                    auth.markLoggedIn(username: name)
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, secret: Bool) -> some View {
        Group {
            if secret {
                SecureField(title, text: text)
            } else {
                TextField(title, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .padding(14)
        .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tryPasswordThenWeb() async {
        errorText = nil
        auth.busy = true
        defer { auth.busy = false }
        do {
            let name = try await PasswordLogin.attempt(username: username, password: password)
            auth.markLoggedIn(username: name)
        } catch {
            errorText = "直接登录失败，已改为网页登录（多半是验证码）"
            showWeb = true
        }
    }
}
