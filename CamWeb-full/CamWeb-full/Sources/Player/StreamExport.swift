import Foundation
import UIKit

enum StreamExport {
    /// iPlayer 的 url 字段使用最高码率视频媒体 playlist。
    /// 调用方会在导出前重新 resolve，因此这里的 session 是最新的；audio 字段
    /// 使用同一次 resolve 得到的独立音频 playlist，保证两条流的 session 一致。
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
        // iPlayer 对 LL-HLS master 的兼容性不一致；传媒体 video playlist，
        // 并显式带上同一 session 的 audio playlist。
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
        [
            highestURL(from: stream).absoluteString,
            "\(room.title) · Chaturbate 自动最高画质（含音频）"
        ]
    }
}
