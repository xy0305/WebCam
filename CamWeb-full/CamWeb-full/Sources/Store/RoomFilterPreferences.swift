import Foundation

/// 房间列表过滤偏好。只用站点自带的主播类型字段（gender），不做图像识别。
enum RoomFilterPreferences {
    /// 「只看女主播和情侣」，默认开启。沿用 95 的开关 key，原来打开的用户继续打开。
    static let hideMaleKey = "camweb.hideMaleRooms"

    static var hideMale: Bool {
        if UserDefaults.standard.object(forKey: hideMaleKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: hideMaleKey)
    }
}

extension Array where Element == Room {
    /// 开关打开时去掉单人男主播和跨性别房间；女主播、情侣、未知类型保留。
    func hidingMaleRooms(_ enabled: Bool = RoomFilterPreferences.hideMale) -> [Room] {
        guard enabled else { return self }
        return filter { !$0.isHiddenByGenderFilter }
    }
}
