//
//  TagManagementViewModel.swift
//  Starcat
//
//  标签管理面板（TagManagementView）的状态机。
//
//  职责：
//  - 加载全部标签 + 每标签的 repo 计数（一次性，loadAll）
//  - CRUD：create / update / delete，含名字 trim + 唯一性检查 + 错误回显
//  - 合并：把多个 source 合到一个 target，事务由 TagRepository.merge 保证
//
//  设计约束：
//  - @MainActor + @Observable：UI 直接观察属性变化
//  - 所有可变状态用 `private(set) var` 限制写入入口，UI 只读
//    （selection 例外：SwiftUI 多选 List 需要双向 binding）
//  - errorMessage 用字符串而非自定义 Error 类型，UI 直接显示
//

import Foundation
import Observation

@MainActor
@Observable
final class TagManagementViewModel {

    // MARK: - UI 可观察状态

    private(set) var tags: [Tag] = []
    /// tagId → starred repo count；UI 显示在列表行右侧。
    private(set) var counts: [String: Int] = [:]
    private(set) var isLoading: Bool = false
    /// 失败提示，nil 表示无错。每次写入操作开始时清空。
    private(set) var errorMessage: String?

    /// 多选 List 的选择集合（SwiftUI 双向绑定）。
    /// - 单选编辑 ↔ count == 1
    /// - 多选合并 ↔ count >= 2
    var selection: Set<String> = []

    // MARK: - 派生

    /// 当前编辑面板要显示的标签（仅在单选时）。
    var singleSelected: Tag? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return tags.first { $0.id == id }
    }

    /// 是否允许"合并"按钮：至少选了 2 个。
    var canMerge: Bool { selection.count >= 2 }

    // MARK: - 依赖

    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol

    init(
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) {
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
    }

    // MARK: - 加载

    /// 拉取全部标签 + 计数。任何 CRUD 之后都应再次调用以保持 UI 一致。
    func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let tagsTask = tagRepository.fetchAll()
            async let countsTask = repoTagRepository.repoCountsByTag()
            tags = try await tagsTask
            counts = try await countsTask
            errorMessage = nil
        } catch {
            errorMessage = String(format: String(localized: "tagManagement.error.loadFailedFormat"), error.localizedDescription)
        }
    }

    // MARK: - 创建

    /// 创建标签。
    /// - Returns: 成功 true（UI 关掉新建 sheet）；失败 false（errorMessage 已写）。
    @discardableResult
    func create(name: String, color: String?, icon: String?) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "tagManagement.error.emptyName")
            return false
        }
        do {
            // UNIQUE 唯一性先查，UI 友好（避免直接抛 GRDB 错）
            if try await tagRepository.findByName(trimmed) != nil {
                errorMessage = String(format: String(localized: "tagManagement.error.duplicateNameFormat"), trimmed)
                return false
            }
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let tag = Tag(
                id: UUID().uuidString,
                name: trimmed,
                color: color,
                icon: icon,
                sortOrder: 0,
                isPreset: false,
                parentId: nil,
                createdAt: now,
                updatedAt: now
            )
            try await tagRepository.create(tag)
            await loadAll()
            // 自动选中新建项，便于用户立刻编辑细节
            selection = [tag.id]
            return true
        } catch {
            errorMessage = String(format: String(localized: "tagManagement.error.createFailedFormat"), error.localizedDescription)
            return false
        }
    }

    // MARK: - 更新

    /// 更新已存在标签的 name / color / icon。
    /// 改名时若 name 与他人重名会拒绝（保持唯一性）。
    @discardableResult
    func update(_ tag: Tag, name: String, color: String?, icon: String?) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "tagManagement.error.emptyName")
            return false
        }
        do {
            // 名字变化时才查重；保持原名直接放行
            if trimmed != tag.name,
               try await tagRepository.findByName(trimmed) != nil {
                errorMessage = String(format: String(localized: "tagManagement.error.duplicateNameFormat"), trimmed)
                return false
            }
            var updated = tag
            updated.name = trimmed
            updated.color = color
            updated.icon = icon
            updated.updatedAt = ISO8601DateFormatter.shared.string(from: Date())
            try await tagRepository.update(updated)
            await loadAll()
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(format: String(localized: "tagManagement.error.updateFailedFormat"), error.localizedDescription)
            return false
        }
    }

    // MARK: - 删除

    /// 批量删除选中的标签。ON DELETE CASCADE 会自动清掉 repo_tags 关联。
    func delete(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try await tagRepository.delete(id: id)
            }
            await loadAll()
            selection.subtract(ids)
            errorMessage = nil
        } catch {
            errorMessage = String(format: String(localized: "tagManagement.error.deleteFailedFormat"), error.localizedDescription)
        }
    }

    // MARK: - 合并

    /// 把 sources 中除 target 外的所有标签合并到 target。
    /// 合并完成后 selection 收敛到 target 一个。
    func merge(sources: Set<String>, into target: String) async {
        guard sources.contains(target) || sources.count >= 2 else { return }
        do {
            for source in sources where source != target {
                try await tagRepository.merge(source: source, into: target)
            }
            await loadAll()
            selection = [target]
            errorMessage = nil
        } catch {
            errorMessage = String(format: String(localized: "tagManagement.error.mergeFailedFormat"), error.localizedDescription)
        }
    }

    // MARK: - UI 辅助

    /// UI 主动清错（用户点关闭横幅时调用）。
    func dismissError() {
        errorMessage = nil
    }
}
