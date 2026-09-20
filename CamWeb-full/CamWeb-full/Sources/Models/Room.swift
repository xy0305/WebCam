import Foundation

enum CamPlatform: String, Codable, Hashable, CaseIterable {
    case chaturbate, stripchat, panda
    var title: String {
        switch self {
        case .chaturbate: return "Chaturbate"
        case .stripchat: return "Stripchat"
        case .panda: return "PandaTV"
        }
    }
}

struct RoomListResponse: Decodable {
    let rooms: [Room]?
    let count: Int?
    let offset: Int?
}

struct Room: Decodable, Identifiable, Hashable {
    var id: String { "\(platform.rawValue):\(platformRoomID ?? username)" }
    let platform: CamPlatform
    let platformRoomID: String?
    let presets: [String]?
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
        if platform == .stripchat, let id = platformRoomID {
            return URL(string: "https://img.doppiocdn.com/thumbs/\(id)/\(id)")
        }
        return URL(string: "https://thumb.live.mmcdn.com/ri/\(username).jpg")
    }

    var pageURL: URL? {
        switch platform {
        case .stripchat:
            return URL(string: "https://zh.stripchat.com/\(username)/")
        case .panda:
            return URL(string: "https://www.pandalive.co.kr/play/\(username)")
        case .chaturbate:
            return URL(string: "https://chaturbate.com/\(username)/")
        }
    }

    var viewersText: String {
        let n = numUsers ?? 0
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    /// API tags + 房间标题里的 #hashtag
    var hashtags: [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
                .lowercased()
            guard t.count >= 2 else { return }
            guard t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return }
            if seen.insert(t).inserted { out.append(t) }
        }
        tags?.forEach(add)
        if let subject = roomSubject {
            for part in subject.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
                if part.hasPrefix("#") { add(String(part)) }
            }
        }
        return out
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
        platform = .chaturbate
        platformRoomID = nil
        presets = nil
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

    init(
        platform: CamPlatform = .chaturbate,
        platformRoomID: String? = nil,
        username: String,
        displayName: String? = nil,
        roomSubject: String? = nil,
        numUsers: Int? = nil,
        imageURL: String? = nil,
        tags: [String]? = nil,
        presets: [String]? = nil,
        loadState: CardLoadState = .live
    ) {
        self.platform = platform
        self.platformRoomID = platformRoomID
        self.presets = presets
        self.username = platform == .panda ? username : username.lowercased()
        self.displayName = displayName ?? username
        self.roomSubject = roomSubject
        self.numUsers = numUsers
        self.imageURL = imageURL
        currentShow = nil
        isHD = nil
        gender = nil
        self.tags = tags
        self.loadState = loadState
    }

    func withHeat(_ live: Room) -> Room {
        Room(
            platform: platform,
            platformRoomID: live.platformRoomID ?? platformRoomID,
            username: username,
            displayName: live.displayName ?? displayName,
            roomSubject: live.roomSubject ?? roomSubject,
            numUsers: live.numUsers ?? numUsers,
            imageURL: live.imageURL ?? imageURL,
            tags: live.tags ?? tags,
            presets: live.presets ?? presets,
            loadState: live.loadState
        )
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
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .offline(let s): return "房间不是公开状态（\(s)）"
        case .blocked: return "拿不到直播地址（地区或私密）"
        case .badResponse: return "接口请求失败"
        case .needLogin: return "需要登录后才能继续"
        case .httpStatus(let c): return "接口请求失败 (\(c))"
        }
    }
}
