# 实时翻译（英语 → 简体中文）

播放页能力：把直播流里的英语语音识别成英文，再用系统翻译成中文字幕叠在画面上。

## 技术栈

| 阶段 | 实现 |
|------|------|
| 音频 | `LiveCaptionAudioReader`：独立 FFmpeg 音频 demux。HLS master 先在 Swift 里解析（`LiveCaptionHLS`），只把独立音频 rendition / 最低码率变体交给 FFmpeg；起播/卡顿时 `holdForBandwidth` 让出带宽 |
| ASR | Apple `Speech`：`en-US`，优先本机 |
| MT | Apple `Translation`：`en` → `zh-Hans`（需 iOS 18+） |
| UI | 播放页左下角 `character.bubble`；关闭时先清字幕再异步停管道 |

**不改播放最高画质**：字幕不碰 `HLSMaster.lock` / 迷你 master /「始终最高画质」逻辑；Chaturbate 单次 token 由字幕单独申请，不复用播放器地址。

## 使用

1. 进入直播间，等画面起播。
2. 点左下角气泡按钮开启「实时翻译」。
3. 首次使用会申请**语音识别**权限；若提示下载语言包，到系统设置下载。
4. 再点一次即可关闭；关闭应立刻去掉字幕。

### 翻译语言包

1. **设置 → 通用 → 语言与地区 → 翻译语言**（有的系统叫「下载的语言」）
2. 下载 **英语** 和 **简体中文**
3. 需要 **iOS 18+**

## 代码位置

- `CamWeb-full/CamWeb-full/Sources/LiveCaption/`
- 接线：`Sources/Player/PlayerView.swift`（开关 / 叠层 / 带宽让出）
- 设置说明：`Sources/Features/Settings/SettingsView.swift`

## Chaturbate

- 播放地址 token 一次性：字幕 `makeRefresher` 重新 `StreamSource.resolve` 拿新 token，不影响播放器最高画质会话。
- 只读音频媒体 playlist；失败会有限次重连。

## 限制

- 需要 iOS 18+（Translation）。
- 第二路音频 demux 会多占一些带宽；已用最低变体 + hold 降低对播放的影响。
- 面向英语直播；非英语内容识别质量会下降。

## 验证清单

- [ ] 英语直播开启后出现中文字幕
- [ ] 关闭开关字幕立刻消失，播放不卡顿，画质仍是最高档
- [ ] Chaturbate：开启后约 5–8 秒出字幕，播放器不黑屏
- [ ] 拒绝语音识别权限时有可读错误提示
