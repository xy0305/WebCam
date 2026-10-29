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


## 1.3.1 (build 81)

- 频道墙关闭 LIVE/波形无限动画，降低浏览发热
- 后台无录制时暂停自动录制轮询
- 静态极光背景与设置页「播放与发热」分区

## build 84

- 撤回播放画质限制：播放恢复始终锁最高画质（同 1.3 / 80）
