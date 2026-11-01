import Foundation

/// 房间列表过滤偏好。只用站点自带的主播类型字段（gender），不做图像识别。
enum RoomFilterPreferences {
    /// 「隐藏男主播房间」，默认开启。
    static let hideMaleKey = "camweb.hideMaleRooms"

    static var hideMale: Bool {
        if UserDefaults.standard.object(forKey: hideMaleKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: hideMaleKey)
    }
}

extension Array where Element == Room {
    /// 开关打开时去掉单人男主播房间；情侣、女、跨性别、未知类型保留。
    func hidingMaleRooms(_ enabled: Bool = RoomFilterPreferences.hideMale) -> [Room] {
        guard enabled else { return self }
        return filter { !$0.isMaleRoom }
    }
}
