import Foundation

struct RoomListResponse: Decodable {
    let rooms: [Room]?
    let count: Int?
    let offset: Int?
}

struct Room: Decodable, Identifiable, Hashable {
    var id: String { username }
    let username: String
    let displayName: String?
    let roomSubject: String?
    let numUsers: Int?
    let imageURL: String?
    let currentShow: String?
    let isHD: Bool?
    let gender: String?
    let tags: [String]?
    var loadState: CardLoadState = .live

    var title: String {
        let n = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? username : n
    }

    var subtitle: String {
        roomSubject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? username
    }

    var tagText: String {
        if let t = tags?.first, !t.isEmpty { return t }
        switch gender {
        case "m": return "Male"
        case "c": return "Couple"
        case "t": return "Trans"
        default: return "Live"
        }
    }

    var thumb: URL? {
        if let imageURL, let u = URL(string: imageURL) { return u }
        return URL(string: "https://thumb.live.mmcdn.com/ri/\(username).jpg")
    }

    var viewersText: String {
        let n = numUsers ?? 0
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case roomSubject = "room_subject"
        case numUsers = "num_users"
        case imageURL = "img"
        case imageURL2 = "image_url"
        case currentShow = "current_show"
        case isHD = "is_hd"
        case gender, tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decode(String.self, forKey: .username)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        roomSubject = try c.decodeIfPresent(String.self, forKey: .roomSubject)
        numUsers = try c.decodeIfPresent(Int.self, forKey: .numUsers)
        currentShow = try c.decodeIfPresent(String.self, forKey: .currentShow)
        isHD = try c.decodeIfPresent(Bool.self, forKey: .isHD)
        gender = try c.decodeIfPresent(String.self, forKey: .gender)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        if let img = try c.decodeIfPresent(String.self, forKey: .imageURL) {
            imageURL = img
        } else {
            imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL2)
        }
        loadState = .live
    }

    init(username: String, displayName: String? = nil, loadState: CardLoadState = .live) {
        self.username = username.lowercased()
        self.displayName = displayName ?? username
        roomSubject = nil
        numUsers = nil
        imageURL = nil
        currentShow = nil
        isHD = nil
        gender = nil
        tags = nil
        self.loadState = loadState
    }
}

enum CardLoadState: String, Hashable {
    case live
    case timeout
    case offline
}

enum StreamSourceError: LocalizedError {
    case offline(String)
    case blocked
    case badResponse
    case needLogin
    var errorDescription: String? {
        switch self {
        case .offline(let s): return "房间不是公开状态（\(s)）"
        case .blocked: return "拿不到直播地址（地区或私密）"
        case .badResponse: return "接口请求失败"
        case .needLogin: return "需要登录后才能继续"
        }
    }
}
