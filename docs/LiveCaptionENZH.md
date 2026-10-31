# 实时翻译（英语 → 简体中文）

播放页能力：把直播流里的英语语音识别成英文，再用系统翻译成中文字幕叠在画面上。

## 技术栈

| 阶段 | 实现 |
|------|------|
| 音频 | `LiveCaptionAudioReader`：独立 FFmpeg 音频 demux。HLS master 先在 Swift 里解析（`LiveCaptionHLS`），只把独立音频 rendition / 最低码率变体交给 FFmpeg；起播/卡顿时 `holdForBandwidth` 让出带宽 |
| ASR（默认） | **Whisper**（WhisperKit 0.18.0，CoreML）`small.en`（约 218 MB 量化版）或 `base.en`（约 147 MB）。4 秒窗口、0.5 秒重叠，静音窗口直接跳过，过滤 `[Music]` / “Thank you.” 这类幻听。首次开启自动下载；未就绪 / 加载失败自动用 Apple Speech |
| ASR（备选） | Apple `Speech`：`en-US`，优先本机 |
| MT（默认） | **Qwen2.5-1.5B-Instruct Q4_K_M**（GGUF 约 1.12 GB，llama.cpp b12020 xcframework，Metal）。逐句翻，带上一句作语境；贪心解码，最多 64 token；新句子到达会取消还没翻完的旧句 |
| MT（备选/兜底） | Apple `Translation`：`en` → `zh-Hans`（需 iOS 18+）。Qwen 未下载、可用内存 < 1.6 GB、低电量模式、机身过热（serious）或连续失败时自动改用 |
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

## 引擎设置

**设置 →「实时翻译（英 → 中）」**：
- 语音识别：Whisper（默认）/ Apple 语音识别
- Whisper 模型：small.en（默认）/ base.en，含下载进度、删除
- 翻译引擎：Qwen（默认，下载后才生效）/ Apple 翻译；Qwen 需在这里手动下载（约 1.1 GB，有进度，可取消）

模型存放在 Application Support/LiveCaptionModels（不进 iCloud 备份）。

## 延迟估算（M1 iPad，未实测）

| 环节 | 估计 |
|------|------|
| Whisper small.en，单个 4 秒窗口 | 约 0.4–0.8 秒（ANE）；base.en 约 0.2–0.4 秒 |
| Whisper 首次加载 | CoreML 优化约 1–3 分钟，只发生一次；之后加载约 2–5 秒 |
| Qwen 1.5B Q4_K_M，一句 | 预填约 0.15–0.3 秒 + 生成 15–30 token × 约 25–40 ms ≈ 0.6–1.3 秒 |
| Qwen 加载 | 约 1–3 秒（mmap） |
| 端到端（从说话到出中文） | 约 4 秒窗口 + 1–2 秒推理 ≈ 比声音慢 5–6 秒 |

## 代码位置

- `CamWeb-full/CamWeb-full/Sources/LiveCaption/`
- 接线：`Sources/Player/PlayerView.swift`（开关 / 叠层 / 带宽让出）
- 设置说明：`Sources/Features/Settings/SettingsView.swift`

## Chaturbate

- 播放地址 token **一次性**：同一 master 第二次 GET → `w3: session_duplicated` / HTTP 403。
- **Build 88 修复**：字幕不能走 `StreamSource.resolve`（内部 `HLSMaster.lock` 会先消费掉 token 来组最高画质迷你 master）。改为 `StreamSource.mintCaptionMaster` 只申请新 token，由 `LiveCaptionSession.fetchPlaylist` **只拉一次** master，再打开独立音频 media playlist。播放器最高画质路径不动。
- 头：`APIClient.hlsHeaders`（UA + Accept + Referer；不要 Origin）。
- 失败会有限次重连（2 分钟内最多 4 次换新 token）。

## 限制

- 需要 iOS 18+（Translation）。
- 第二路音频 demux 会多占一些带宽；已用最低变体 + hold 降低对播放的影响。
- 面向英语直播；非英语内容识别质量会下降。

## 验证清单

- [ ] 英语直播开启后出现中文字幕
- [ ] 关闭开关字幕立刻消失，播放不卡顿，画质仍是最高档
- [ ] Chaturbate：开启后约 5–8 秒出字幕，播放器不黑屏
- [ ] 拒绝语音识别权限时有可读错误提示
