import Foundation
import llama
import os
import UIKit

/// llama.cpp runtime for Qwen2.5-1.5B-Instruct Q4_K_M. Actor => inference never runs on the main thread.
actor LiveCaptionQwenEngine {
    static let shared = LiveCaptionQwenEngine()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var template: String?
    private var loadedPath: String?
    private static let backend: Void = { llama_backend_init() }()

    static let systemPrompt = """
    你是直播字幕翻译。把用户给出的英文翻译成简洁、自然、口语化的简体中文字幕。\
    只输出译文一行，必须是简体中文，禁止输出英文单词或英文原句。不要解释、不要引号。\
    保留俚语、语气和真实含义，粗口照常意译。
    """

    init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { _ in
            Task { await LiveCaptionQwenEngine.shared.unload() }
        }
    }

    var isLoaded: Bool { context != nil }

    func load(path: URL) throws {
        if context != nil, loadedPath == path.path { return }
        unload()
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99 // Metal
        guard let m = llama_model_load_from_file(path.path, mp) else {
            throw LiveCaptionEngineError.unavailable("Qwen 模型加载失败")
        }
        var cp = llama_context_default_params()
        cp.n_ctx = 1024
        cp.n_batch = 512
        let threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let ctx = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw LiveCaptionEngineError.unavailable("Qwen 上下文创建失败")
        }
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        model = m
        context = ctx
        vocab = llama_model_get_vocab(m)
        sampler = chain
        template = llama_model_chat_template(m, nil).map { String(cString: $0) }
        loadedPath = path.path
    }

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
        model = nil
        vocab = nil
        loadedPath = nil
    }

    /// Greedy, short output. Checks Task cancellation every token so stale lines are dropped fast.
    func translate(_ english: String, previous: String?, maxTokens: Int = 64) throws -> String {
        guard let context, let vocab, let sampler else { throw LiveCaptionEngineError.notReady }
        var user = ""
        if let previous, !previous.isEmpty {
            user += "上一句（仅作语境参考，不要翻译）：\(previous)\n"
        }
        user += "翻译这句：\(english)"
        let prompt = renderChat(system: Self.systemPrompt, user: user)

        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)

        var tokens = tokenize(prompt, vocab: vocab)
        guard !tokens.isEmpty, tokens.count < 900 else { return "" }
        let rc = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard rc == 0 else { throw LiveCaptionEngineError.unavailable("Qwen decode \(rc)") }

        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 128)
        for _ in 0 ..< maxTokens {
            try Task.checkCancellation()
            var tok = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            let n = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
            if n > 0 {
                bytes.append(contentsOf: piece.prefix(Int(n)).map { UInt8(bitPattern: $0) })
                if bytes.contains(10), bytes.contains(where: { $0 != 10 && $0 != 32 }) { break }
            }
            let step = llama_decode(context, llama_batch_get_one(&tok, 1))
            if step != 0 { break }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」'"))
            ?? ""
    }

    private func renderChat(system: String, user: String) -> String {
        let fallback = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        guard let template else { return fallback }
        let roles = [strdup("system"), strdup("user")]
        let contents = [strdup(system), strdup(user)]
        defer { (roles + contents).forEach { free($0) } }
        var msgs = [
            llama_chat_message(role: UnsafePointer(roles[0]), content: UnsafePointer(contents[0])),
            llama_chat_message(role: UnsafePointer(roles[1]), content: UnsafePointer(contents[1])),
        ]
        var buf = [CChar](repeating: 0, count: 4096)
        var n = llama_chat_apply_template(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        }
        guard n > 0 else { return fallback }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) -> [llama_token] {
        let len = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(len) + 16)
        var n = llama_tokenize(vocab, text, len, &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, len, &tokens, Int32(tokens.count), true, true)
        }
        return n > 0 ? Array(tokens.prefix(Int(n))) : []
    }
}

/// Qwen as a `LiveCaptionTranslating` backend.
final class LiveCaptionQwenTranslator: LiveCaptionTranslating, @unchecked Sendable {
    let displayName = "Qwen2.5 1.5B"

    /// Free memory needed before we load ~1.1 GB weights + KV cache.
    static let minAvailableBytes: Int = 1_600_000_000

    static var environmentAllowsLoad: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return false }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        let avail = os_proc_available_memory()
        return avail == 0 || avail >= minAvailableBytes
    }

    /// nil when not downloaded, memory/thermal too tight, or load fails (caller uses Apple Translation).
    static func makeIfReady() async -> LiveCaptionQwenTranslator? {
        guard let path = LiveCaptionModelStore.qwenPathIfPresent(), environmentAllowsLoad else { return nil }
        do {
            try await LiveCaptionQwenEngine.shared.load(path: path)
            return LiveCaptionQwenTranslator()
        } catch {
            return nil
        }
    }

    func prepare() async throws {}

    func translate(_ english: String) async throws -> String {
        try await translate(english, previous: nil)
    }

    func translate(_ english: String, previous: String?) async throws -> String {
        let first = try await LiveCaptionQwenEngine.shared.translate(english, previous: previous)
        if LiveCaptionText.isPlausibleChinese(first, sourceEnglish: english) {
            return first
        }
        // Short cues sometimes come back as an English echo — one stricter retry without context.
        let retryEnglish = "【禁止输出任何英文，只写一行简体中文翻译】\n" + english
        let retry = try await LiveCaptionQwenEngine.shared.translate(retryEnglish, previous: nil)
        return retry
    }

    func shutdown() {
        Task { await LiveCaptionQwenEngine.shared.unload() }
    }
}

/// Primary (Qwen) with automatic fallback (Apple Translation) on failure / English-echo / thermal.
final class LiveCaptionFallbackTranslator: LiveCaptionTranslating, @unchecked Sendable {
    let primary: (any LiveCaptionTranslating)?
    let fallback: (any LiveCaptionTranslating)?
    private let lock = NSLock()
    private var primaryFailures = 0
    /// Last human-readable reason we switched engines or rejected a result (UI status line).
    private(set) var lastNote: String = ""

    init(primary: (any LiveCaptionTranslating)?, fallback: (any LiveCaptionTranslating)?) {
        self.primary = primary
        self.fallback = fallback
    }

    var displayName: String {
        if usePrimary, let primary { return primary.displayName }
        return fallback?.displayName ?? primary?.displayName ?? "翻译"
    }

    /// Prefer naming both when Qwen is present but we may fall back mid-session.
    var summaryName: String {
        switch (primary, fallback) {
        case (let p?, let f?):
            return usePrimary ? "\(p.displayName)（失败时用 \(f.displayName)）" : "\(f.displayName)（已从 \(p.displayName) 回退）"
        case (let p?, nil):
            return p.displayName
        case (nil, let f?):
            return f.displayName
        default:
            return "翻译"
        }
    }

    private var usePrimary: Bool {
        lock.lock(); defer { lock.unlock() }
        guard primary != nil, primaryFailures < 3 else { return false }
        let thermal = ProcessInfo.processInfo.thermalState
        return !(thermal == .serious || thermal == .critical)
    }

    func prepare() async throws {}

    func translate(_ english: String) async throws -> String {
        try await translate(english, previous: nil)
    }

    func translate(_ english: String, previous: String?) async throws -> String {
        lastNote = ""
        var primaryRejected = false
        if usePrimary, let primary {
            do {
                let out = try await primary.translate(english, previous: previous)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if LiveCaptionText.isPlausibleChinese(out, sourceEnglish: english) {
                    return out
                }
                // Empty or English echo — do not publish; fall through to Apple.
                primaryRejected = true
                lock.lock(); primaryFailures += 1; lock.unlock()
                lastNote = out.isEmpty
                    ? "Qwen 无输出，已用苹果翻译"
                    : "Qwen 未译成中文，已用苹果翻译"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                primaryRejected = true
                lock.lock(); primaryFailures += 1; lock.unlock()
                lastNote = "Qwen 失败，已用苹果翻译"
            }
        } else if primary != nil, fallback != nil {
            // Already on Apple (thermal / too many Qwen echoes). Stay quiet — avoid HUD spam.
        }

        if let fallback {
            let out = try await fallback.translate(english, previous: previous)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if LiveCaptionText.isPlausibleChinese(out, sourceEnglish: english) {
                if !primaryRejected, lastNote.isEmpty, primary != nil, !usePrimary {
                    lastNote = "已用苹果翻译"
                }
                return out
            }
            if out.isEmpty {
                throw LiveCaptionEngineError.unavailable(lastNote.isEmpty ? "翻译失败" : lastNote)
            }
            // Apple also echoed English / packs missing → refuse so UI does not stick on English.
            lastNote = "翻译失败，已跳过原文"
            throw LiveCaptionEngineError.unavailable(lastNote)
        }
        throw LiveCaptionEngineError.notReady
    }

    func shutdown() {
        primary?.shutdown()
        fallback?.shutdown()
    }
}
