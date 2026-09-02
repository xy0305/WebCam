import Foundation

enum RoomAPI {
    static func fetchRooms(offset: Int = 0, gender: String? = nil, keywords: String? = nil) async throws -> [Room] {
        var comp = URLComponents(string: "https://chaturbate.com/api/ts/roomlist/room-list/")!
        var items = [
            URLQueryItem(name: "limit", value: "80"),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let gender, !gender.isEmpty {
            items.append(URLQueryItem(name: "genders", value: gender))
        }
        if let keywords, !keywords.isEmpty {
            items.append(URLQueryItem(name: "keywords", value: keywords))
        }
        comp.queryItems = items
        var req = URLRequest(url: comp.url!)
        let (data, http) = try await APIClient.data(for: req)
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.badResponse }
        let decoded = try JSONDecoder().decode(RoomListResponse.self, from: data)
        return decoded.rooms ?? []
    }

    static func fetchFollowed() async throws -> [Room] {
        var comp = URLComponents(string: "https://chaturbate.com/api/ts/roomlist/room-list/")!
        comp.queryItems = [
            URLQueryItem(name: "limit", value: "80"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "follow", value: "1"),
        ]
        var req = URLRequest(url: comp.url!)
        let (data, http) = try await APIClient.data(for: req)
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamSourceError.needLogin }
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.badResponse }
        let decoded = try JSONDecoder().decode(RoomListResponse.self, from: data)
        return decoded.rooms ?? []
    }
}
