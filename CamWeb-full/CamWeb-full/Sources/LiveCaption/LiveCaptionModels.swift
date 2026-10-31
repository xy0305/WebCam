import Foundation

/// One finished English→Chinese live caption line.
struct LiveCaptionLine: Sendable, Equatable, Identifiable {
    let id: UUID
    let english: String
    let chinese: String
    /// Approximate media time (seconds) of the audio chunk start, when known.
    let mediaTime: TimeInterval
    let createdAt: Date

    init(
        id: UUID = UUID(),
        english: String,
        chinese: String,
        mediaTime: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.english = english
        self.chinese = chinese
        self.mediaTime = mediaTime
        self.createdAt = createdAt
    }

    /// Prefer real Chinese. English only when `allowEnglish` (「显示原文」or both MT failed).
    func displayText(allowEnglish: Bool) -> String {
        if LiveCaptionText.isPlausibleChinese(chinese, sourceEnglish: english) {
            return LiveCaptionText.fitChineseCaption(chinese)
        }
        if allowEnglish { return english }
        return ""
    }

    /// Legacy helper used by accessibility / older call sites — Chinese first, else English.
    var displayText: String {
        displayText(allowEnglish: true)
    }

    var showsChinese: Bool {
        LiveCaptionText.isPlausibleChinese(chinese, sourceEnglish: english)
    }
}

enum LiveCaptionPhase: String, Sendable, Equatable {
    case idle
    case requestingPermission
    case starting
    case running
    case stopping
    case unavailable
    case failed
}

struct LiveCaptionSource: Sendable, Equatable {
    var url: URL
    var headers: [String: String]
    var userAgent: String
    /// Play URL token is single-use (Chaturbate): the caption reader must mint its own URL
    /// via the refresher instead of re-opening the player's URL.
    var requiresFreshPlaylist: Bool

    init(
        url: URL,
        headers: [String: String] = [:],
        userAgent: String = "libmpv",
        requiresFreshPlaylist: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.userAgent = userAgent
        self.requiresFreshPlaylist = requiresFreshPlaylist
    }
}

/// Shared EN→ZH live-caption contracts. On-device Speech + Translation + FFmpeg audio reader.
protocol LiveCaptionRecognizing: Sendable {
    /// Window size fed to the recognizer (16 kHz samples).
    var chunkSamples: Int { get }
    /// Samples carried over into the next window so words on the boundary are not cut.
    var overlapSamples: Int { get }
    /// Earliest silence-flush size (defaults to ~1.5 s).
    var minFlushSamples: Int { get }
    /// Trailing silence (samples) that triggers an early flush when ≥ minFlushSamples.
    var silenceTailSamples: Int { get }
    var displayName: String { get }
    func prepare() async throws
    func transcribe(samples: [Float]) async throws -> String
}

extension LiveCaptionRecognizing {
    var chunkSamples: Int { LiveCaptionAudio.chunkSamples }
    var overlapSamples: Int { 0 }
    var minFlushSamples: Int { 16_000 }
    var silenceTailSamples: Int { Int(0.45 * LiveCaptionAudio.sampleRate) }
    var displayName: String { "Apple 语音识别" }
}

protocol LiveCaptionTranslating: Sendable {
    var displayName: String { get }
    func prepare() async throws
    func translate(_ english: String) async throws -> String
    /// `previous` = the last English line, given as context only.
    func translate(_ english: String, previous: String?) async throws -> String
    func shutdown()
}

extension LiveCaptionTranslating {
    func translate(_ english: String, previous: String?) async throws -> String {
        try await translate(english)
    }
}

/// Heuristics so we never treat an English echo as a successful EN→ZH translation.
enum LiveCaptionText {
    /// True when ASR text likely finished a spoken phrase (start MT immediately).
    static func looksLikePhraseEnd(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return false }
        return ".?!;:…。？！".contains(last)
    }

    /// True when `text` looks like a real Simplified/Traditional Chinese subtitle for `sourceEnglish`.
    static func isPlausibleChinese(_ text: String, sourceEnglish: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let norm: (String) -> String = { s in
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        // Exact / near echo of the English source (common Qwen failure mode on short cues).
        if !norm(sourceEnglish).isEmpty, norm(trimmed) == norm(sourceEnglish) { return false }
        if trimmed.compare(sourceEnglish, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return false
        }
        var cjk = 0
        var latin = 0
        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) {
                cjk += 1
            } else if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                latin += 1
            }
        }
        guard cjk > 0 else { return false }
        // Allow a little Latin (OK / LOL) but Chinese must dominate.
        if latin > 0 && cjk * 3 < latin { return false }
        return true
    }

    /// Keep on-screen Chinese readable: prefer 1–2 short sentences, ≈≤28 characters.
    static func fitChineseCaption(_ text: String, maxChars: Int = 28) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let breaks = CharacterSet(charactersIn: "。！？!?…")
        var sentences: [String] = []
        var current = ""
        for ch in trimmed {
            current.append(ch)
            if String(ch).rangeOfCharacter(from: breaks) != nil {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        if sentences.isEmpty { sentences = [trimmed] }

        var out = sentences[0]
        if out.count < 12, sentences.count > 1 {
            let combined = out + sentences[1]
            if combined.count <= maxChars + 6 { out = combined }
        }
        if out.count <= maxChars { return out }
        let idx = out.index(out.startIndex, offsetBy: maxChars)
        return String(out[..<idx]) + "…"
    }

    /// Normalize for duplicate / merge checks.
    static func normalizeEnglish(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Removes words repeated because of the window overlap ("... going to" + "to the store" → "the store").
enum LiveCaptionOverlap {
    static func dedupe(previous: String?, current: String) -> String {
        guard let previous, !previous.isEmpty else { return current }
        func norm(_ w: Substring) -> String {
            w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let prevWords = previous.split(separator: " ").suffix(4).map(norm)
        let curWords = current.split(separator: " ")
        let curNorm = curWords.map(norm)
        var best = 0
        for k in stride(from: min(prevWords.count, curNorm.count), through: 1, by: -1) {
            if Array(prevWords.suffix(k)) == Array(curNorm.prefix(k)) { best = k; break }
        }
        guard best > 0 else { return current }
        return curWords.dropFirst(best).joined(separator: " ")
    }
}

/// Accumulates short ASR fragments into one utterance before MT (readable Chinese).
struct LiveCaptionUtteranceAssembler: Sendable {
    private(set) var english: String = ""
    private(set) var mediaTime: Double = 0
    private(set) var startedAt: Date?
    /// Max wall time to hold fragments before forcing a translate.
    let maxHold: TimeInterval
    /// Soft max English characters before flush.
    let maxChars: Int

    init(pace: LiveCaptionPaceMode) {
        switch pace {
        case .accurate:
            maxHold = 3.5
            maxChars = 110
        case .fast:
            maxHold = 2.0
            maxChars = 70
        }
    }

    var isEmpty: Bool { english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    mutating func reset() {
        english = ""
        mediaTime = 0
        startedAt = nil
    }

    /// Append an ASR fragment. Returns a flushed utterance when we should translate now
    /// (phrase end, max hold, or length). Duplicate / echo fragments are merged away.
    mutating func append(_ fragment: String, mediaTime: Double, now: Date = Date()) -> (english: String, mediaTime: Double)? {
        let piece = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return nil }

        if english.isEmpty {
            english = piece
            self.mediaTime = mediaTime
            startedAt = now
        } else {
            let merged = Self.merge(existing: english, incoming: piece)
            if merged == english {
                // Pure duplicate — still check age flush below.
            } else {
                english = merged
            }
        }

        if LiveCaptionText.looksLikePhraseEnd(english) {
            return flush()
        }
        if english.count >= maxChars {
            return flush()
        }
        if let startedAt, now.timeIntervalSince(startedAt) >= maxHold {
            return flush()
        }
        return nil
    }

    /// Call when trailing silence is detected after we already have text.
    mutating func flushOnSilence() -> (english: String, mediaTime: Double)? {
        guard !isEmpty else { return nil }
        // Need a little content — skip lone "uh" / one letter.
        let words = english.split(separator: " ")
        if words.count <= 1, english.count < 4 { return nil }
        return flush()
    }

    mutating func forceFlush() -> (english: String, mediaTime: Double)? {
        flush()
    }

    private mutating func flush() -> (english: String, mediaTime: Double)? {
        let text = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = mediaTime
        reset()
        guard !text.isEmpty else { return nil }
        return (text, t)
    }

    /// Merge overlapping / repeated short cues ("come on" + "come on" → one; "hey" + "hey you" → "hey you").
    static func merge(existing: String, incoming: String) -> String {
        let a = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }

        let na = LiveCaptionText.normalizeEnglish(a)
        let nb = LiveCaptionText.normalizeEnglish(b)
        if nb.isEmpty { return a }
        if na == nb { return a }
        if na.hasSuffix(nb) { return a }
        if nb.hasPrefix(na), nb.count > na.count { return b }
        if na.hasPrefix(nb) { return a }

        // Word-level overlap at the boundary.
        let deduped = LiveCaptionOverlap.dedupe(previous: a, current: b)
        if deduped.isEmpty { return a }
        if LiveCaptionText.normalizeEnglish(deduped) == nb || !deduped.isEmpty {
            let joined = (a + " " + deduped)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Collapse immediate repeated bigrams ("come on come on").
            return collapseRepeats(joined)
        }
        return collapseRepeats(a + " " + b)
    }

    private static func collapseRepeats(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return text }
        var out: [String] = []
        var i = 0
        while i < words.count {
            // Try 2-word then 1-word repeat.
            if i + 3 < words.count,
               words[i].lowercased() == words[i + 2].lowercased(),
               words[i + 1].lowercased() == words[i + 3].lowercased() {
                out.append(words[i])
                out.append(words[i + 1])
                i += 4
                continue
            }
            if i + 1 < words.count, words[i].lowercased() == words[i + 1].lowercased() {
                out.append(words[i])
                i += 2
                continue
            }
            out.append(words[i])
            i += 1
        }
        return out.joined(separator: " ")
    }
}

/// PCM helpers used by the live caption pipeline (16 kHz mono Float32).
enum LiveCaptionAudio {
    static let sampleRate: Double = 16_000
    /// Fallback ~2.0 s window (pace-aware recognizers override).
    static let chunkSamples = 32_000
    static let silenceRMSThreshold: Float = 0.008

    static func isSilent(_ samples: ArraySlice<Float>, threshold: Float = silenceRMSThreshold) -> Bool {
        guard !samples.isEmpty else { return true }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count)) < threshold
    }

    static func isSilent(_ samples: [Float], threshold: Float = silenceRMSThreshold) -> Bool {
        isSilent(samples[...], threshold: threshold)
    }
}
