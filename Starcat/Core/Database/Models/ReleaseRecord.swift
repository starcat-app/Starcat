//
//  ReleaseRecord.swift
//  Starcat
//
//  Release 缓存记录（HOM-47）。对应 `releases` 表。
//
//  设计取舍：
//  - assets 用 JSON 字符串存（assets_json）。Release.assets 数量稳定 ≤ 10，
//    没有"按平台跨 Release 反查所有资产"的查询场景；不开关联表避免 N+1
//  - body 截断后再存（最多 600 字符），避免几 MB 的发版日志撑大数据库
//  - is_read 是用户已读状态。和 RepoNote.status 的"未读/在读"不同：这里是 Release-level
//

import Foundation
import GRDB

struct ReleaseRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "releases"

    /// GitHub Release 的全局唯一 id（不是 tag）。
    var id: Int64

    /// 关联 repos.id（ON DELETE CASCADE，repo 取消 star 时一起删除）。
    var repoId: Int64

    /// 例如 `v1.2.3`。
    var tagName: String

    /// Release 标题，可空。GitHub 允许 Release 不写名字（仅有 tag_name）。
    var name: String?

    /// 截取后的 release notes（Markdown 原文，限 600 字符）。
    var bodyTruncated: String?

    /// Release 在 GitHub 上的网页地址。
    var htmlUrl: String

    /// 是否预发布版（pre-release）。
    var isPrerelease: Bool

    /// 是否草稿（不会通过 GET releases 默认返回，但保留字段以兼容未来过滤）。
    var isDraft: Bool

    /// Release 发布时间（ISO8601 原文）。可空：草稿态没有 published_at。
    var publishedAt: String?

    /// Release 创建时间（ISO8601 原文，与 publishedAt 区分：作者可以先创建再发布）。
    var createdAtRemote: String?

    /// 资产数组的 JSON 字符串（编解码由业务层处理）。
    /// 详见 `ReleaseAssetCodec`。
    var assetsJson: String?

    /// 用户已读状态。默认 false（未读）。
    var isRead: Bool

    /// 本地拉取时间（ISO8601）。仅作 debug，不参与同步。
    var fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case repoId = "repo_id"
        case tagName = "tag_name"
        case name
        case bodyTruncated = "body_truncated"
        case htmlUrl = "html_url"
        case isPrerelease = "is_prerelease"
        case isDraft = "is_draft"
        case publishedAt = "published_at"
        case createdAtRemote = "created_at_remote"
        case assetsJson = "assets_json"
        case isRead = "is_read"
        case fetchedAt = "fetched_at"
    }
}

// MARK: - Asset

/// Release 单个资产（构件）。
///
/// 与 GitHub `assets` 数组中元素字段对齐，但只保留 UI 真正会展示的几列，
/// 避免在 JSON 中存大段无用字段。
struct ReleaseAsset: Codable, Equatable, Hashable, Identifiable {

    /// GitHub asset 的全局 id（用作 SwiftUI 列表 Identifiable）。
    var id: Int64

    /// 资产文件名，如 `Starcat-1.0.0-arm64.dmg`。
    var name: String

    /// MIME 类型，可空。
    var contentType: String?

    /// 文件大小（字节）。
    var size: Int

    /// 直接下载 URL（GitHub 的 browser_download_url）。
    var browserDownloadUrl: String

    /// GitHub 统计的下载次数。
    var downloadCount: Int

    /// Asset 创建时间。
    var createdAt: String?
}

// MARK: - Asset JSON 编解码

/// 集中处理 `assets` 数组与 `assets_json` 字符串字段的相互转换。
///
/// 抽出来的理由：编解码场景在 Repository 写入与 ViewModel 读取两处都会用到，
/// 避免在业务层反复 try-catch + JSONEncoder。
enum ReleaseAssetCodec {

    /// 把 assets 数组编码为 JSON 字符串（写库前调用）。
    /// nil / 空数组都编码成 nil 入库（节省一行 `[]` 字符）。
    static func encode(_ assets: [ReleaseAsset]?) -> String? {
        guard let assets, !assets.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(assets),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// 解析数据库中的 assets_json 字段。
    /// 解析失败回落空数组，避免单行损坏导致整个时间线崩溃。
    static func decode(_ raw: String?) -> [ReleaseAsset] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ReleaseAsset].self, from: data) else { return [] }
        return decoded
    }
}
