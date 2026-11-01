import Foundation

enum LiveCaptionEngineError: LocalizedError, Sendable {
    case speechUnauthorized
    case translationUnsupported
    case translationNeedsDownload
    case unavailable(String)
    case notReady

    var errorDescription: String? {
        switch self {
        case .speechUnauthorized:
            return "需要语音识别权限才能开启实时翻译"
        case .translationUnsupported:
            return "此设备不支持英语→简体中文系统翻译"
        case .translationNeedsDownload:
            return "请先下载英语和简体中文翻译语言包（设置 → App → 翻译 → 语言）"
        case .unavailable(let message):
            return message
        case .notReady:
            return "实时翻译尚未就绪"
        }
    }
}
