//
//  RepositorySpotlightEntity.swift
//  Starcat
//
//  Starcat 仓库在 App Intents / Core Spotlight 中的系统实体。
//

import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

/// 可被 macOS Spotlight 搜索并 deep-link 回 Starcat 的仓库实体。
///
/// `id` 只使用 GitHub 全局仓库 ID，因此仓库 rename 后重新索引会更新原条目，而不是
/// 留下旧 owner/name 的重复结果。打开动作只传递这个稳定 ID，owner/name 仅用于
/// Spotlight 展示与关键词检索，不参与 private repository 的跨进程路由。
struct RepositorySpotlightEntity: IndexedEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "spotlight.repository.entity.type"
    )
    static let defaultQuery = RepositorySpotlightEntityQuery()

    let id: String

    @Property(title: "spotlight.repository.property.repositoryID")
    var repositoryID: String

    @Property(title: "spotlight.repository.property.owner")
    var owner: String

    @Property(title: "spotlight.repository.property.name")
    var name: String

    let repositoryDescription: String?
    let language: String?
    let topics: [String]
    let note: String?

    init(
        repositoryID: Int64,
        owner: String,
        name: String,
        repositoryDescription: String?,
        language: String?,
        topics: [String],
        note: String?
    ) {
        self.id = String(repositoryID)
        self.repositoryDescription = repositoryDescription
        self.language = language
        self.topics = topics
        self.note = note
        // 先显式初始化 backing storage，再写 wrappedValue。直接给 @Property 声明默认值
        // 会触发 Xcode 26.5 Swift frontend 在批量编译模式下崩溃。
        self._repositoryID = EntityProperty(title: "spotlight.repository.property.repositoryID")
        self._owner = EntityProperty(title: "spotlight.repository.property.owner")
        self._name = EntityProperty(title: "spotlight.repository.property.name")
        // App Intents 的 EntityProperty 不接受 Int64；GitHub ID 用十进制字符串是无损映射，
        // 同时也与 AppEntity.ID、Core Spotlight stable identifier 保持同一个真值。
        self.repositoryID = String(repositoryID)
        self.owner = owner
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(owner)/\(name)")
    }

    /// 系统索引内容的单一映射点。
    ///
    /// 用户笔记放入 `textContent` 才能参与全文检索；仓库描述仍放
    /// `contentDescription`，让 Spotlight 可以按系统策略展示摘要。这里故意不读取或
    /// 拼入 token、AI 对话、诊断信息，避免 Spotlight 授权被扩大为无边界的数据导出。
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        let fullName = "\(owner)/\(name)"
        attributes.title = fullName
        attributes.displayName = fullName
        attributes.contentDescription = normalized(repositoryDescription)
        attributes.textContent = [repositoryDescription, note]
            .compactMap(normalized)
            .joined(separator: "\n\n")
        attributes.keywords = ([owner, name, fullName, language].compactMap(normalized) + topics)
            .uniquedPreservingOrder()
        attributes.creator = owner
        attributes.domainIdentifier = "starcat.repositories"
        return attributes
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element == String {
    /// Spotlight keywords 数量不大；保持原顺序比引入 Set 后随机排序更利于稳定测试。
    func uniquedPreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
