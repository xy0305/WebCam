import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var username = ""
    @State private var password = ""
    @State private var showWeb = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(intensity: 0.75)
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 8) {
                            Text("CamWeb")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.ink)
                            Text("登录后可同步关注列表")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.inkSecondary)
                        }
                        .padding(.top, 36)
                        .staggerAppear(index: 0)

                        VStack(spacing: 12) {
                            fieldRow(icon: "person") {
                                TextField("用户名", text: $username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(AppTheme.ink)
                            }
                            fieldRow(icon: "lock") {
                                SecureField("密码", text: $password)
                                    .foregroundStyle(AppTheme.ink)
                            }
                        }
                        .padding(14)
                        .appCard()
                        .staggerAppear(index: 1)

                        if let errorText {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .transition(.opacity)
                        }

                        VStack(spacing: 10) {
                            Button {
                                Task { await tryPasswordThenWeb() }
                            } label: {
                                Text("登录")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .glassButton(prominent: true)
                            }
                            .buttonStyle(SoftPress())
                            .disabled(username.isEmpty || password.isEmpty || auth.busy)
                            .opacity(username.isEmpty || password.isEmpty || auth.busy ? 0.45 : 1)

                            Button {
                                showWeb = true
                            } label: {
                                Text(auth.busy ? "正在打开登录页…" : "网页登录（推荐，可过验证码）")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                    .glassButton()
                            }
                            .buttonStyle(SoftPress())

                            Button {
                                auth.enterGuest()
                            } label: {
                                Text("先随便看看")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AppTheme.inkSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(SoftPress())
                        }
                        .staggerAppear(index: 2)

                        Text("站点若弹出验证码，必须走网页登录。账号密码只提交给官网，不会存进这个 App。")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 24)
                            .staggerAppear(index: 3)
                    }
                    .padding(.horizontal, 24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showWeb) {
                WebLoginView { name in
                    showWeb = false
                    if let name {
                        auth.markLoggedIn(username: name)
                    }
                }
            }
        }
        .brandScreen()
    }

    @ViewBuilder
    private func fieldRow<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.inkSecondary)
                .frame(width: 22)
            content()
        }
        .padding(.vertical, 4)
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
