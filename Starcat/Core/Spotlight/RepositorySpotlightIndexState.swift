//
//  RepositorySpotlightIndexState.swift
//  Starcat
//
//  Core Spotlight 全量索引的持久化内容指纹。
//

import CryptoKit
import Foundation

/// 记录“系统索引当前对应哪个账号、哪份内容”，让未变化的启动跳过全量 replaceAll。
///
/// Core Spotlight index 是进程外的单一具名索引，因此这里只保存一份 marker，而不是
/// 每账号各存一份。登出/切库清空系统索引后也必须清掉 marker，避免再次登录时误判命中。
@MainActor
final class RepositorySpotlightIndexState {
    private struct Marker: Codable, Equatable {
        let account: String
        let fingerprint: String
    }

    private static let markerKey = "starcat.repositorySpotlight.indexMarker.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 只比较账号归属，供冷启动从 anonymous 占位库恢复同一账号时复用现有系统索引。
    func belongs(to accountID: Int64) -> Bool {
        marker?.account == Self.accountKey(accountID)
    }

    func matches(accountID: Int64?, fingerprint: String) -> Bool {
        marker == Marker(account: Self.accountKey(accountID), fingerprint: fingerprint)
    }

    func record(accountID: Int64?, fingerprint: String) {
        let marker = Marker(account: Self.accountKey(accountID), fingerprint: fingerprint)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        defaults.set(data, forKey: Self.markerKey)
    }

    func invalidate() {
        defaults.removeObject(forKey: Self.markerKey)
    }

    private var marker: Marker? {
        guard let data = defaults.data(forKey: Self.markerKey) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// 生成跨进程稳定的 SHA-256；Swift Hasher 带随机种子，不能用作持久化判断。
    nonisolated static func fingerprint(for snapshots: [RepositorySpotlightSnapshot]) -> String {
        // Entity 映射字段或索引语义变化时递增版本，使升级后的首次启动强制重建一次。
        var canonical = Data("spotlight-index-schema-v1".utf8)
        for snapshot in snapshots.sorted(by: { $0.repositoryID < $1.repositoryID }) {
            append(String(snapshot.repositoryID), to: &canonical)
            append(snapshot.owner, to: &canonical)
            append(snapshot.name, to: &canonical)
            append(snapshot.repositoryDescription, to: &canonical)
            append(snapshot.language, to: &canonical)
            append(snapshot.topicsJSON, to: &canonical)
            append(snapshot.note, to: &canonical)
        }
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 长度前缀避免字段内容本身包含普通分隔符时产生同一 canonical byte stream。
    nonisolated private static func append(_ value: String?, to data: inout Data) {
        guard let value else {
            var nilMarker = UInt64.max.bigEndian
            Swift.withUnsafeBytes(of: &nilMarker) { data.append(contentsOf: $0) }
            return
        }
        let bytes = Data(value.utf8)
        var byteCount = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    nonisolated private static func accountKey(_ accountID: Int64?) -> String {
        accountID.map(String.init) ?? "anonymous"
    }
}
