import Foundation
import UIKit

enum StreamExport {
    /// 外部播放器必须使用官方 master，而不是临时 chunklist 视频子流。
    /// chunklist_* URL 带短期 session，部分 CDN 会直接返回 403；master 可重新选择
    /// 当前有效的最高档位，并正确关联独立音频轨道。
    static func highestURL(from stream: ResolvedStream) -> URL {
        stream.masterURL
    }

    static func payload(stream: ResolvedStream, room: Room) -> [String: String] {
        var body: [String: String] = [
            "url": highestURL(from: stream).absoluteString,
            "anchorName": room.title,
            "roomName": stream.username,
            "coverImage": room.thumb?.absoluteString ?? "https://thumb.live.mmcdn.com/ri/\(stream.username).jpg",
            "platform": "Chaturbate",
            "remark": "最高画质",
        ]
        // master 内已经包含 AUDIO group；不要把短期 audio chunklist 另传给外部播放器。
        return body
    }

    static func iplayer2URL(stream: ResolvedStream, room: Room) -> URL? {
        guard let json = try? JSONSerialization.data(withJSONObject: payload(stream: stream, room: room)),
              let b64 = json.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "iplayer2://import?payload=\(b64)")
    }

    static func copyHighest(_ stream: ResolvedStream) {
        UIPasteboard.general.string = highestURL(from: stream).absoluteString
    }

    static func shareItems(stream: ResolvedStream, room: Room) -> [Any] {
        [
            highestURL(from: stream).absoluteString,
            "\(room.title) · Chaturbate 自动最高画质（含音频）"
        ]
    }
}
