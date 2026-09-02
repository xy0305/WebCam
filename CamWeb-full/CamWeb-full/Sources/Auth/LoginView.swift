import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var username = ""
    @State private var password = ""
    @State private var showWeb = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task { await tryPasswordThenWeb() }
                    } label: {
                        Text("登录")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(username.isEmpty || password.isEmpty || auth.busy)

                    Button {
                        showWeb = true
                    } label: {
                        Text(auth.busy ? "正在打开登录页…" : "网页登录（推荐，可过验证码）")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        auth.enterGuest()
                    } label: {
                        Text("先随便看看")
                            .frame(maxWidth: .infinity)
                    }
                }

                Section {
                    Text("站点若弹出验证码，必须走网页登录。账号密码只提交给官网，不会存进这个 App。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("登录")
            .sheet(isPresented: $showWeb) {
                WebLoginView { name in
                    showWeb = false
                    if let name {
                        auth.markLoggedIn(username: name)
                    }
                }
            }
        }
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
