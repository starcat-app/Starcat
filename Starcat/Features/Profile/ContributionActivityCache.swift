//
//  ContributionActivityCache.swift
//  Starcat
//
//  将每日贡献明细保存为短小的本地快照。草坪概览仍由 ContributionService 单独持久化。
//

import Foundation

/// 以 UTC 日期为下标的连续数组，避免每一天在内存和磁盘上重复存用户名、日期与字段名。
struct ContributionActivityCache: Codable, Equatable {
    static let maximumDayCount = 366

    private var firstDay = 0
    private var days: [ContributionDayActivity] = []

    /// 最近几天的明细已与哪个草坪快照一起核对；新快照只重查这几天和缺失的数据。
    var recentSnapshotAt: TimeInterval?

    static func dayIndex(_ date: String) -> Int? {
        ContributionGrid.date(date).map { Int($0.timeIntervalSince1970 / 86_400) }
    }

    /// 新概览跨日后平移窗口，仅保留仍落在新范围内的计数。
    mutating func align(to range: ClosedRange<Int>) {
        guard firstDay != range.lowerBound || days.count != range.count else { return }
        let aligned = range.map { self[$0] ?? .missing }
        firstDay = range.lowerBound
        days = aligned
    }

    subscript(day: Int) -> ContributionDayActivity? {
        get {
            let index = day - firstDay
            guard days.indices.contains(index), days[index].calendarCount >= 0 else { return nil }
            return days[index]
        }
        set {
            let index = day - firstDay
            guard days.indices.contains(index) else { return }
            days[index] = newValue ?? .missing
        }
    }

    /// 草坪总数改变时不能把旧的分类占比与新总数一起展示。
    func activity(on day: Int, matching calendarCount: Int) -> ContributionDayActivity? {
        guard let record = self[day], record.calendarCount == calendarCount else { return nil }
        return record
    }

    static func restore(from file: URL) -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        do {
            let compressed = try Data(contentsOf: file)
            let data = try (compressed as NSData).decompressed(using: .zlib) as Data
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            AppLog.network.warning("Contribution activity cache restore failed: \(error.localizedDescription, privacy: .public)")
            return Self()
        }
    }

    /// 每批覆盖一个小文件，使用原子替换以保住上一次已写完的快照。
    func save(to file: URL) {
        do {
            let data = try JSONEncoder().encode(self)
            let compressed = try (data as NSData).compressed(using: .zlib) as Data
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try compressed.write(to: file, options: .atomic)
        } catch {
            AppLog.network.warning("Contribution activity cache save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension ContributionDayActivity: Codable {
    /// 负数只在内存中作为占位，使一个日期始终占五个 Int32；落盘用 null 区分未拉取与全零。
    fileprivate static let missing = Self(calendarCount: -1, commits: 0, pullRequests: 0, reviews: 0, issues: 0)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .missing
            return
        }
        let counts = try container.decode([Int32].self)
        guard counts.count == 5, counts.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid contribution activity counts")
        }
        self.init(calendarCount: counts[0], commits: counts[1], pullRequests: counts[2], reviews: counts[3], issues: counts[4])
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if calendarCount < 0 {
            try container.encodeNil()
        } else {
            try container.encode([calendarCount, commits, pullRequests, reviews, issues])
        }
    }
}
