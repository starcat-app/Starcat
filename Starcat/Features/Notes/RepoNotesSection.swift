//
//  RepoNotesSection.swift
//  Starcat
//
//  Repo 详情页"私有笔记 + 状态"段。
//
//  组件结构（同文件内三层）：
//  - `RepoNotesSection`        UI：状态 Picker + 笔记 TextEditor + 保存状态指示
//  - `RepoNotesSectionViewModel`  @MainActor @Observable，负责读/写 repo_notes
//  - `SaveIndicator`           底部"已保存 / 保存中 / 未保存"小提示
//
//  设计取舍：
//  - 笔记保存用"UI 防抖 + ViewModel explicit save"分层：
//      UI 监听 text 变化 → task(id: text) sleep 800ms → 调 vm.saveContent
//      → 这样 ViewModel 单测可纯净，不需要 sleep / 时间假
//  - 状态 Picker 改动即时落库（频次低，无需防抖）
//  - 切换 repo 时强保存当前 buffer，避免内容丢失
//
//  数据流：
//  - task(id: repo.id) → vm.loadFor → editingContent 同步到本地 @State
//  - onChange(editingContent) → 标记 dirty → task(id) 防抖 → save
//  - onChange(repo.id) → 切换前 flush 旧 buffer
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

    @ViewBuilder
    private var statusRow: some View {
        if let vm = viewModel {
            HStack(spacing: 10) {
                Text("repo.status")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { vm.status ?? .unread },
                    set: { newStatus in
                        Task { await vm.setStatus(repoId: repo.id, status: newStatus) }
                    }
                )) {
                    ForEach(RepoStatus.allCases, id: \.self) { s in
                        Label(s.displayName, systemImage: icon(for: s))
                            .tag(s)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)

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
                    Text("repo.lastEdited \(relativeDate(edited))", bundle: .main)
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

    private func icon(for status: RepoStatus) -> String {
        switch status {
        case .unread:     return "envelope.badge"
        case .reading:    return "book"
        case .using:      return "checkmark.seal"
        case .deprecated: return "archivebox"
        }
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

    /// 派生：把 status 字符串还原为 enum；非法值 / 缺失返回 nil。
    var status: RepoStatus? {
        guard let s = note?.status else { return nil }
        return RepoStatus(rawValue: s)
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
    func setStatus(repoId: Int64, status: RepoStatus) async {
        do {
            try await repoNoteRepository.updateStatus(repoId: repoId, status: status)
            await loadFor(repoId: repoId)
        } catch {
            errorMessage = "repo.notes.saveStatusFailed"
        }
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
