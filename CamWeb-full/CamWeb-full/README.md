# CamWeb 完整版

个人用。登录 + 频道墙 + KSPlayer + HLS 源流录制。

覆盖路径：`CamWeb-ios-shell/CamWeb-ios-shell/`

1. 删除该目录 `Sources` 下全部旧文件（含子文件夹）
2. 上传本包 `Sources` 整个目录（保留子文件夹）
3. 覆盖 `project.yml`
4. 覆盖仓库根目录 `.github/workflows/build-ipa.yml`
5. Actions 打包（首次拉 KSPlayer 较慢）

登录说明：
- 推荐「网页登录」，可过验证码
- 密码不会写入 App，只把官网 Cookie 同步到请求
- 游客可先看公开房间
