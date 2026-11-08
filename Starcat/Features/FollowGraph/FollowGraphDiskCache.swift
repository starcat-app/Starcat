//
//  FollowGraphDiskCache.swift
//  Starcat
//
//  双方向关系都是可重建缓存，不进用户数据库。actor 隔离编码与文件 IO，
//  原子写入避免退出时留下半份 JSON；测试必须注入临时根目录。
//

import Foundation

/// 展示范围独立于完整关系缓存；分页游标仍由快照持有，不保存视角或选中状态。
struct FollowGraphSavedRange: Codable, Equatable, Sendable {
    var formatVersion = 1
    let expandedSources: [String: Int]

    /// 拒绝损坏或无界的展示预算，避免恢复时绕过图谱容量保护。
    var isValid: Bool {
        formatVersion == 1 && expandedSources.count <= 10_000 &&
            expandedSources.allSatisfy { id, count in
                Int64(id).map { $0 > 0 && String($0) == id } == true && (0...10_000).contains(count)
            }
    }
}

/// 缓存只接受正数账户 ID，不能用任意用户名构造磁盘路径。
actor FollowGraphDiskCache {
    static let shared = FollowGraphDiskCache()
    private let root: URL
    private let maximumBytes = 20 * 1024 * 1024

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.starcat.app/follow-graph-cache", isDirectory: true)
    }

    private func file(_ account: String, relation: FollowGraphRelation = .following) -> URL? {
        guard let id = Int64(account), id > 0, String(id) == account else { return nil }
        return root.appendingPathComponent(account, isDirectory: true).appendingPathComponent(relation == .following ? "snapshot.json" : "followers-snapshot.json")
    }

    func load(account: String, relation: FollowGraphRelation = .following) -> FollowGraphSnapshot? {
        guard let url = file(account, relation: relation),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(FollowGraphSnapshot.self, from: data),
              snapshot.formatVersion == 1, snapshot.relation == relation, snapshot.accountID == account, snapshot.rootID == account,
              snapshot.nodes.count <= 10_000, snapshot.edges.count <= 30_000,
              snapshot.nodes[account] != nil,
              snapshot.edges.allSatisfy({ snapshot.nodes[$0.source] != nil && snapshot.nodes[$0.target] != nil })
        else { return nil }
        return snapshot
    }

    func save(_ snapshot: FollowGraphSnapshot) throws {
        guard let url = file(snapshot.accountID, relation: snapshot.relation) else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func bytes(account: String, relation: FollowGraphRelation = .following) -> Int64 {
        guard let url = file(account, relation: relation),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    /// 使用独立 sidecar，网络分页写入快照时不会覆盖用户刚调整的展示范围。
    private func rangeFile(_ account: String, relation: FollowGraphRelation) -> URL? {
        file(account, relation: relation)?.deletingLastPathComponent()
            .appendingPathComponent("\(relation.rawValue)-range.json")
    }

    func loadRange(account: String, relation: FollowGraphRelation) -> FollowGraphSavedRange? {
        guard let url = rangeFile(account, relation: relation),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1024 * 1024, let data = try? Data(contentsOf: url),
              let range = try? JSONDecoder().decode(FollowGraphSavedRange.self, from: data),
              range.isValid else { return nil }
        return range
    }

    /// 与快照相同的原子落盘约束；初始化写入空预算，而不是删除关系缓存。
    func saveRange(_ range: FollowGraphSavedRange, account: String, relation: FollowGraphRelation) throws {
        guard range.isValid, let url = rangeFile(account, relation: relation) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // 恢复出厂可能先于排队的关闭保存执行；没有关系快照时不重建已删除的账户目录。
        // 检查和写入在同一个 actor 同步方法内，与 remove 不能交错。
        guard let snapshotURL = file(account, relation: relation),
              FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        let data = try JSONEncoder().encode(range)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// 关注写入跨两种视角共享，但各自的分页完整性和探索方向仍独立。
    func setFollowing(_ following: Bool, node: FollowGraphNode, accountID: String) throws {
        for relation in FollowGraphRelation.allCases {
            guard var value = load(account: accountID, relation: relation) else { continue }
            // 未出现在 followers 图中的普通关注对象不能凭写操作成为关注者。
            if relation == .followers, value.nodes[node.id] == nil { continue }
            value.setFollowing(following, node: node)
            try save(value)
        }
    }

    /// 仅供已有的恢复出厂流程调用，不暴露图谱专用清理入口。
    func remove(account: String) throws {
        guard let folder = file(account)?.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}
