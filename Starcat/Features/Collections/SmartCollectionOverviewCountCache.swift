//
//  SmartCollectionOverviewCountCache.swift
//  Starcat
//
//  Smart Collections 总览计数的进程内 SWR 快照。
//

import Foundation

/// 按账号与用户规则版本隔离计数，让总览二次进入先显示缓存、再后台校正。
@MainActor
final class SmartCollectionOverviewCountCache {
    struct Snapshot: Sendable {
        let systemCounts: [SmartCollectionKind: Int]
        let userCounts: [String: Int]
    }

    static let shared = SmartCollectionOverviewCountCache()

    private struct Entry {
        let ruleSignature: String
        let snapshot: Snapshot
    }

    private var entries: [String: Entry] = [:]

    func snapshot(accountID: Int64?, collections: [UserSmartCollection]) -> Snapshot? {
        let account = Self.accountKey(accountID)
        guard let entry = entries[account],
              entry.ruleSignature == Self.ruleSignature(collections) else { return nil }
        return entry.snapshot
    }

    func store(
        systemCounts: [SmartCollectionKind: Int],
        userCounts: [String: Int],
        accountID: Int64?,
        collections: [UserSmartCollection]
    ) {
        let account = Self.accountKey(accountID)
        entries[account] = Entry(
            ruleSignature: Self.ruleSignature(collections),
            snapshot: Snapshot(systemCounts: systemCounts, userCounts: userCounts)
        )
        // 多账号缓存只服务进程内返回导航；保留最近少量账号即可，避免无界增长。
        if entries.count > 8, let evicted = entries.keys.first(where: { $0 != account }) {
            entries[evicted] = nil
        }
    }

    private static func ruleSignature(_ collections: [UserSmartCollection]) -> String {
        collections
            .sorted { $0.id < $1.id }
            .map { "\($0.id):\($0.updatedAt)" }
            .joined(separator: "|")
    }

    private static func accountKey(_ accountID: Int64?) -> String {
        accountID.map(String.init) ?? "anonymous"
    }
}
