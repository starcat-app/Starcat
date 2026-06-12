//
//  RepoNotesSection.swift
//  Starcat
//
//  Repo 详情页"私有笔记 + 状态"段。
//
//  组件结构（同文件内三层）：
//  - `RepoNotesSection`        UI：状态胶囊按钮 + 笔记 TextEditor + 保存状态指示
//  - `RepoNotesSectionViewModel`  @MainActor @Observable，负责读/写 repo_notes
//  - `SaveIndicator`           底部"已保存 / 保存中 / 未保存"小提示
//
//  设计取舍：
//  - 笔记保存用"UI 防抖 + ViewModel explicit save"分层：
//      UI 监听 text 变化 → task(id: text) sleep 800ms → 调 vm.saveContent
//      → 这样 ViewModel 单测可纯净，不需要 sleep / 时间假
//  - 状态按钮改动即时落库（频次低，无需防抖）
//  - 切换 repo 时强保存当前 buffer，避免内容丢失
//
//  数据流：
//  - task(id: repo.id) → vm.loadFor → editingContent 同步到本地 @State
//  - onChange(editingContent) → 标记 dirty → task(id) 防抖 → save
//  - onChange(repo.id) → 切换前 flush 旧 buffer
//
//  ────────────────────────────────────────────────────────────────────────────
//  阅读状态 v2 重新设计（2026-06-12，dong4j 反馈）
//  ────────────────────────────────────────────────────────────────────────────
//
//  原四态 Picker（unread/reading/using/deprecated）简化为三态自动状态机：
//  ```
//  unread ──(README 加载完成自动)──▶ read ──(用户点击)──▶ using
//                                     ▲                    │
//                                     └──(× 取消)──────────┘
//  ```
//
//  UI 形态变化：
//  - 旧：`Text("repo.status") + Picker(allCases)`（占两行宽，操作步骤多）
//  - 新：单个胶囊按钮 `StatusBadge`，read/using 切换 + using 态显示 × 取消
//  - 去掉"状态："前缀文字 → 按钮自解释
//
//  自动化流程：
//  - `NotificationCenter.default.notifications(named: .readmeDidLoad)`
//    监听 ReadmeViewModel 加载完成事件 → 匹配 repoId → 调
//    `vm.markAsReadIfNeeded(repoId:)` 把 unread 升级为 read（using 不动）
//  - 监听用 `task(id: repo.id)` 包裹的 async for-loop；切换 repo 时 task 自动取消
//

import SwiftUI

// MARK: - View

struct RepoNotesSection: View {

    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies

    @State private var viewModel: RepoNotesSectionViewModel?

    /// 笔记本地编辑 buffer；与 viewModel.note?.content 分离，避免边输入边重新加载。
    @State private var editingContent: String = ""

    /// 标记本地 buffer 是否相对最后一次 save 有未保存改动（驱动 SaveIndicator）。
    @State private var hasUnsavedChanges: Bool = false

    /// 保存指示态：idle / saving / saved。
    @State private var saveState: SaveState = .idle

    /// 上一个 repo.id，用于切换前 flush。
    @State private var previousRepoId: Int64? = nil

    /// 私有笔记默认折叠，避免右侧详情页顶部长期占掉大块高度。
    @State private var isNotesExpanded: Bool = false

    enum SaveState { case idle, saving, saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            notesDisclosure
        }
        .task(id: repo.id) {
            await onRepoChange(to: repo.id)
        }
        // 监听 README 加载完成事件 → 把 unread 升级为 read（仅匹配当前 repo.id）。
        //
        // task(id: repo.id) 让切换 repo 时自动取消旧监听，新 task 立即接管。
        // for-await-in 是 AsyncSequence 的标准模式，对应 NotificationCenter.notifications。
        // markAsReadIfNeeded 在 repository 层是幂等的（using/read 行 no-op），
        // 所以即便缓存命中 + 网络刷新两次 post 也无副作用。
        .task(id: repo.id) {
            let stream = NotificationCenter.default.notifications(named: .readmeDidLoad)
            for await note in stream {
                guard !Task.isCancelled else { break }
                guard let payloadId = note.userInfo?["repoId"] as? Int64,
                      payloadId == repo.id else { continue }
                await viewModel?.markAsReadIfNeeded(repoId: repo.id)
            }
        }
        // 文本变化 → 标记 dirty → 进入下方 debounce 流程
        .onChange(of: editingContent) { _, _ in
            guard viewModel != nil else { return }
            // 若内容等于已加载 note，不视为 dirty（避免初始 load 触发误判）
            let stored = viewModel?.note?.content ?? ""
            hasUnsavedChanges = (editingContent != stored)
            if hasUnsavedChanges { saveState = .idle }
        }
        // 防抖保存：editingContent 变化后 800ms 内无新输入 → 保存
        .task(id: editingContent) {
            guard hasUnsavedChanges else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, hasUnsavedChanges else { return }
            await flushContent()
        }
    }

    // MARK: - 状态行

    /// 状态胶囊按钮（v2，2026-06-12）。
    ///
    /// 显示与交互规则：
    /// - 当前态 `.unread` / `.read`（或未写过 repo_notes 行）：按钮文案为当前状态本地化，
    ///   点击切到 `.using`
    /// - 当前态 `.using`：按钮变高亮，右侧露出 × 图标，点击 × 降回 `.read`
    ///
    /// 设计取舍：
    /// - 不显示"状态："前缀 → 按钮自解释（dong4j 要求）
    /// - 用 RoundedRectangle 胶囊 + buttonStyle(.plain) + focusEffectDisabled 符合
    ///   项目 UI 规范（详见 CLAUDE.md "Focus Ring 蓝框"章节）
    @ViewBuilder
    private var statusRow: some View {
        if let vm = viewModel {
            HStack(spacing: 10) {
                StatusBadge(
                    status: vm.status ?? .unread,
                    onPrimaryTap: {
                        Task { await vm.setStatus(repoId: repo.id, status: .using) }
                    },
                    onCancelUsing: {
                        Task { await vm.setStatus(repoId: repo.id, status: .read) }
                    }
                )
                Spacer()
            }
        }
    }

    // MARK: - 笔记 Editor

    @ViewBuilder
    private var notesDisclosure: some View {
        DisclosureGroup(isExpanded: $isNotesExpanded) {
            notesEditor
                .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Label("repo.privateNotes", systemImage: hasNoteContent ? "note.text" : "note.text.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let edited = viewModel?.note?.editedAt {
                    Text(String(format: String(localized: "repo.lastEditedFormat"), relativeDate(edited)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                SaveIndicator(state: saveState, hasUnsaved: hasUnsavedChanges)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isNotesExpanded.toggle()
                }
            }
            .accessibilityAddTraits(.isButton)
            .help(isNotesExpanded ? Text("repo.notesCollapse") : Text("repo.notesExpand"))
        }
        .disclosureGroupStyle(.automatic)
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $editingContent)
                .font(.system(.body, design: .default))
                .frame(minHeight: 80, maxHeight: 160)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
                .overlay(alignment: .topLeading) {
                    if editingContent.isEmpty {
                        Text("repo.notesPlaceholder")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - 行为

    private func onRepoChange(to newId: Int64) async {
        if viewModel == nil {
            viewModel = RepoNotesSectionViewModel(repoNoteRepository: dependencies.repoNoteRepository)
        }
        // 切换前 flush 上一个 repo 的 buffer，避免丢失
        if let prevId = previousRepoId, prevId != newId, hasUnsavedChanges {
            await viewModel?.saveContent(repoId: prevId, content: editingContent)
        }
        previousRepoId = newId
        await viewModel?.loadFor(repoId: newId)
        editingContent = viewModel?.note?.content ?? ""
        hasUnsavedChanges = false
        saveState = .idle
        isNotesExpanded = false
    }

    private func flushContent() async {
        guard let vm = viewModel else { return }
        saveState = .saving
        await vm.saveContent(repoId: repo.id, content: editingContent)
        hasUnsavedChanges = false
        saveState = .saved
    }

    private func relativeDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(.relative(presentation: .named))
    }

    private var hasNoteContent: Bool {
        !editingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class RepoNotesSectionViewModel {

    /// 当前 repo 的笔记；不存在时为 nil。
    /// 状态字段也走它（note?.status），不另起字段避免双源。
    private(set) var note: RepoNote?

    /// 派生：把 status 字符串还原为 enum；缺失（never written）返回 nil（UI 端按 unread 处理）。
    ///
    /// 用 `RepoStatus.parse(_:)` 做 lenient 解析：v1 旧值 `reading` / `deprecated`
    /// 会被回落到 `.read`（与 v2 状态机三态对齐）。
    var status: RepoStatus? {
        guard let s = note?.status else { return nil }
        return RepoStatus.parse(s)
    }

    private(set) var errorMessage: String?

    private let repoNoteRepository: any RepoNoteRepositoryProtocol

    init(repoNoteRepository: any RepoNoteRepositoryProtocol) {
        self.repoNoteRepository = repoNoteRepository
    }

    func loadFor(repoId: Int64) async {
        do {
            note = try await repoNoteRepository.find(repoId: repoId)
            errorMessage = nil
        } catch {
            note = nil
            errorMessage = "repo.notes.loadFailed"
        }
    }

    /// 单独修改状态（即时落库；走 upsert，缺行自动创建）。
    ///
    /// 落库 + 重新加载 `note` 后 post `.repoStatusDidChange` 通知，
    /// 让 `HomeViewModel` 的主列表 row 角标即时刷新（v2，2026-06-12）。
    func setStatus(repoId: Int64, status: RepoStatus) async {
        do {
            try await repoNoteRepository.updateStatus(repoId: repoId, status: status)
            await loadFor(repoId: repoId)
            postStatusDidChange(repoId: repoId)
        } catch {
            errorMessage = "repo.notes.saveStatusFailed"
        }
    }

    /// 自动状态机：unread → read（v2，2026-06-12）。
    ///
    /// 由 `RepoNotesSection.body` 的 `task(id:)` 监听 `.readmeDidLoad` 通知后调用。
    /// repository 层 SQL 保证幂等：行不存在 → 插入 read；行 status='unread' → 升级 read；
    /// 其他状态（read / using）no-op。本方法 await 完成后刷新 `note`，UI 立即反映。
    ///
    /// **不抛错**：自动升级失败不打断用户操作，仅记录 errorMessage（debug 用）。
    ///
    /// 即便 SQL no-op（using/read 命中），仍会 post `.repoStatusDidChange` —— 订阅方
    /// `HomeViewModel.applyStatusChange` 有 `guard statusMap[id] != status` 守卫，
    /// 二次幂等，重复 post 不产生副作用，但能保证 trending → manage 切换等"先看了 README
    /// 再切回 manage"的场景里 row 角标也能即时刷新。
    func markAsReadIfNeeded(repoId: Int64) async {
        do {
            try await repoNoteRepository.markAsReadIfNeeded(repoId: repoId)
            await loadFor(repoId: repoId)
            postStatusDidChange(repoId: repoId)
        } catch {
            errorMessage = "repo.notes.saveStatusFailed"
        }
    }

    /// 发射状态变更通知。
    ///
    /// 用 `loadFor(...)` 之后的真实 `note?.status` 作为 payload —— 这样订阅方收到的
    /// 是"落库后实际生效的值"，避免乐观更新 / 真实状态不一致。
    /// `note == nil` 的边界（loadFor 失败）回落到 `.unread`，让订阅方至少能保持一致性。
    private func postStatusDidChange(repoId: Int64) {
        let effective: RepoStatus = status ?? .unread
        NotificationCenter.default.post(
            name: .repoStatusDidChange,
            object: nil,
            userInfo: [
                "repoId": repoId,
                "status": effective.rawValue
            ]
        )
    }

    /// 单独修改正文（防抖之后调用）。
    /// 空字符串视为"无内容"（content=nil），但保留行（status 仍存在）。
    func saveContent(repoId: Int64, content: String) async {
        do {
            let normalized: String? = content.isEmpty ? nil : content
            try await repoNoteRepository.updateContent(repoId: repoId, content: normalized)
            await loadFor(repoId: repoId)
        } catch {
            errorMessage = "repo.notes.saveContentFailed"
        }
    }
}

// MARK: - 保存指示

private struct SaveIndicator: View {

    let state: RepoNotesSection.SaveState
    let hasUnsaved: Bool

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle where hasUnsaved:
            Image(systemName: "pencil.circle")
                .foregroundStyle(.orange)
                .font(.caption2)
        case .saving:
            ProgressView().controlSize(.mini)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case .idle:
            EmptyView()
        }
    }

    private var text: LocalizedStringKey {
        switch state {
        case .idle:    return hasUnsaved ? "repo.notes.saveIdle" : ""
        case .saving:  return "repo.notes.saving"
        case .saved:   return "repo.notes.saved"
        }
    }
}

// MARK: - 阅读状态胶囊按钮（v2，2026-06-12）

/// 阅读状态展示 + 切换控件。
///
/// 渲染规则（与 `RepoStatus` 三态对齐）：
/// - `.unread` / `.read` → 普通胶囊：图标 + 文案；整按钮点击触发 `onPrimaryTap`（升级到 using）
/// - `.using` → 高亮胶囊：图标 + 文案 + 末尾 × 图标；点击 × 触发 `onCancelUsing`（降回 read）
///
/// 关键约束：
/// - 主按钮 + × 是**两个独立 Button**（不是嵌套）；嵌套点击事件冲突会导致 × 不响应。
///   外层用 HStack 横排两个 plain Button，背景用 RoundedRectangle 共享视觉。
/// - 全部 `.buttonStyle(.plain) + .focusEffectDisabled()`（项目强制规范，详见 CLAUDE.md）。
/// - 文案 / 图标 / 颜色都按 `status` switch；no associated state（保持 stateless 控件）。
private struct StatusBadge: View {

    let status: RepoStatus
    let onPrimaryTap: () -> Void
    let onCancelUsing: () -> Void

    var body: some View {
        // using 态把主按钮 + × 拼成一个胶囊（共享背景）；read/unread 态只有单个主按钮。
        switch status {
        case .using:
            HStack(spacing: 0) {
                primaryButton
                    .padding(.trailing, 4)
                cancelButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5)
            )
        case .unread, .read:
            primaryButton
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        }
    }

    private var primaryButton: some View {
        Button(action: onPrimaryTap) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.caption)
                Text(status.displayName)
                    .font(.caption)
            }
            .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpText)
    }

    private var cancelButton: some View {
        Button(action: onCancelUsing) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor.opacity(0.7))
                .padding(3)
                .background(
                    Circle().fill(Color.accentColor.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("repo.status.cancelUsing"))
    }

    private var iconName: String {
        switch status {
        case .unread: return "envelope.badge"
        case .read:   return "envelope.open"
        case .using:  return "checkmark.seal.fill"
        }
    }

    private var foreground: Color {
        switch status {
        case .unread, .read: return .secondary
        case .using:         return .accentColor
        }
    }

    private var helpText: LocalizedStringKey {
        switch status {
        case .unread, .read: return "repo.status.markUsingHint"
        case .using:         return "repo.status.usingHint"
        }
    }
}
