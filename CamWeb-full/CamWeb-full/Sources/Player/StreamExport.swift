import Foundation
import UIKit

enum StreamExport {
    /// 给外部播放器的最高画质地址：音视频分离时用本地迷你 master 语义，导出真实 HTTP 媒体 playlist。
    static func highestURL(from stream: ResolvedStream) -> URL {
        stream.videoPlaylist
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
        if let audio = stream.audioPlaylist {
            body["audio"] = audio.absoluteString
        }
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
        var items: [Any] = [highestURL(from: stream).absoluteString]
        if let audio = stream.audioPlaylist {
            items.append("音频: \(audio.absoluteString)")
        }
        items.append("\(room.title) · Chaturbate 最高画质")
        return items
    }
}
