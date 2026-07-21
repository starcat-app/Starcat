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
    /// 2026-06-15：DisclosureGroup 展开/收起 0.16s 动画在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var viewModel: RepoNotesSectionViewModel?

    /// AI 草稿与正式笔记 buffer 分离；只有用户确认后才通过 `applyAIDraft()` 写库。
    @State private var aiGenerationViewModel: RepoNoteAIGenerationViewModel?

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

    /// 大窗口编辑 sheet 显隐控制（2026-06-13）。
    ///
    /// inline 输入框右下角的「展开成弹窗」按钮（`arrow.up.left.and.arrow.down.right`）翻转这个值，
    /// `NoteEditorSheet` 通过 sheet modifier 弹起，提供「编辑 / 预览」Tab 切换。
    /// 弹窗与 inline 共享同一份 `editingContent` `@State`（通过 `@Binding` 传入），关闭弹窗时
    /// 由 sheet 主动 await `flushContent()` 落库，避免 800ms 防抖 timer 在关闭瞬间未结算造成丢失。
    @State private var showEditorSheet: Bool = false

    /// 2026-06-12 向量索引改进：笔记保存后的"向量重建"二级 debounce 任务。
    ///
    /// 链路：TextEditor 输入 → 800ms 防抖落库（已有）→ 落库成功后再 1500ms 防抖 → 调
    /// `semanticSearchService.refreshIndexIfChanged(for: repo)`。
    ///
    /// 为何要两级 debounce：第一级 800ms 让 DB 写入收敛到用户停止输入；第二级 1500ms
    /// 进一步避免连续短停顿被多次触发 embedding API。1.5s 与设计文档约定一致。
    /// 切换 repo / view 销毁时取消，避免对前一个 repo 触发。
    @State private var refreshIndexTask: Task<Void, Never>? = nil

    /// 状态按钮的轻量反馈。`.using` 会自动入库，成功后用 toast 明示这个副作用。
    @State private var statusToast: String?

    enum SaveState { case idle, saving, saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            notesDisclosure
        }
        // v2.1（2026-06-13）：父容器 `RepoLocalSections` 的 `VStack(spacing: 12)` 仅设
        // `.padding(.top, 12)`,**没有 `.padding(.bottom)`** → RepoNotesSection 最外层
        // 视图底部紧贴下一个组件（README 区顶部 divider）,视觉上"输入框边线与下方分隔线重合"。
        // 这里加 6pt 底部 padding 与父容器 spacing 协同（6 + 父 spacing 12 = 18pt 间距）。
        .padding(.bottom, 6)
        .toast(message: $statusToast, icon: "heart.fill")
        .task(id: repo.id) {
            await onRepoChange(to: repo.id)
        }
        .onChange(of: isNotesExpanded) { _, expanded in
            // 折叠时中止正在进行的网络 / AI 任务；已生成的草稿仍保留在标题状态中。
            if !expanded, aiGenerationViewModel?.phase == .running {
                aiGenerationViewModel?.cancel()
            }
        }
        .onDisappear {
            // View 已离开详情层级后不再有合法的 UI 接收方，主动终止流式响应与索引防抖。
            // generationID 仍会拦截不响应取消的第三方 Provider 尾包，形成双重保护。
            aiGenerationViewModel?.cancel()
            refreshIndexTask?.cancel()
            refreshIndexTask = nil
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
        // Browser Plugin / MCP 等外部入口写入 notes 后，repository 会发出正文变更通知。
        // 当前视图没有本地未保存输入时直接同步，避免用户还要手动刷新详情页；如果本地正在编辑，
        // 以当前输入为准，避免外部更新覆盖用户尚未落库的内容。
        .task(id: repo.id) {
            let stream = NotificationCenter.default.notifications(named: .repoNoteContentDidChange)
            for await note in stream {
                guard !Task.isCancelled else { break }
                guard let payloadId = note.userInfo?["repoId"] as? Int64,
                      payloadId == repo.id,
                      !hasUnsavedChanges else { continue }
                let content = note.userInfo?["content"] as? String ?? ""
                let editedAt = note.userInfo?["editedAt"] as? String
                viewModel?.applyExternalContent(repoId: repo.id, content: content, editedAt: editedAt)
                editingContent = content
                saveState = .idle
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
        // 大窗口编辑 sheet（2026-06-13 新增）。
        //
        // 共享数据：`$editingContent` 双向绑定到 NoteEditorSheet.content，sheet 内输入直接更新 inline buffer
        // → 上方 `.onChange(of: editingContent)` 同样会触发 → `.task(id: editingContent)` 防抖照常运行。
        //
        // 关闭兜底：sheet 通过 `onFlush` 回调主动 await flushContent，避免"关闭瞬间防抖 timer 未到点"丢失。
        // flushContent 内部已经 idempotent（repository.updateContent 是 upsert），多调一次无副作用。
        .sheet(isPresented: $showEditorSheet) {
            NoteEditorSheet(
                repoName: repo.fullName,
                content: $editingContent,
                onFlush: { await flushContent() }
            )
            .appLocaleEnvironment()
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
                        Task {
                            if await vm.setStatus(repoId: repo.id, status: .using) {
                                statusToast = "library.action.added"
                            }
                        }
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
            VStack(alignment: .leading, spacing: 10) {
                notesEditor
                if aiGenerationViewModel?.phase == .idle {
                    Label("repo.notes.ai.privacyNotice", systemImage: "lock.shield")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let aiViewModel = aiGenerationViewModel,
                   aiViewModel.phase != .idle {
                    RepoNoteAIGenerationPanel(
                        viewModel: aiViewModel,
                        onRetry: startAIGeneration,
                        onCancel: { aiViewModel.cancel() },
                        onDiscard: { aiViewModel.discard() },
                        onApply: { Task { await applyAIDraft() } }
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            ZStack(alignment: .trailing) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        isNotesExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Label("repo.privateNotes", systemImage: hasNoteContent ? "note.text" : "note.text.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let edited = viewModel?.note?.editedAt {
                            Text(String(format: String.l10n("repo.lastEditedFormat"), formattedEditedAt(edited)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        SaveIndicator(state: saveState, hasUnsaved: hasUnsavedChanges)
                    }
                    .padding(.trailing, 250)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(isNotesExpanded ? Text("repo.notesCollapse") : Text("repo.notesExpand"))

                if let aiViewModel = aiGenerationViewModel {
                    RepoNoteAIGenerationHeaderControl(
                        viewModel: aiViewModel,
                        onGenerate: startAIGeneration,
                        onCancel: { aiViewModel.cancel() }
                    )
                }
            }
        }
        .disclosureGroupStyle(.automatic)
    }

    /// inline 笔记编辑器（2026-06-13 v2 重做：固定 3 行高 + 右下角「展开成弹窗」按钮）。
    ///
    /// 视觉/交互设计要点（grill 决策表 A1–A3）：
    /// - **固定 3 行高度**：`minHeight = maxHeight = 76pt`。来源精算：
    ///   - `.body` 字号 = 13pt + macOS 默认行高 ≈ 18pt → 3 行文本 ≈ 54pt
    ///   - NSTextView 自带 `textContainerInset` 顶 5pt + 底 5pt = 10pt
    ///   - 累加 64pt 仅"刚够"3 行（第 3 行光标贴底，v1 错误值）
    ///   - **v2 升到 76pt**：加 12pt buffer（约 0.7 行），保证第 3 行下方仍有视觉余量
    ///   - 不能再加大（如 80+ 会显示第 4 行 1/3 残影）
    /// - **超过 3 行内部纵向滚动**：TextEditor 在 macOS 包装 NSTextView,原生 vertical scroll 自动出现；
    ///   长笔记走右下角「展开成弹窗」按钮进入大窗口编辑。
    /// - **右下角 overlay 按钮（v2 关键修正）**：始终可见、半透明，hover 时加深。
    ///   - **重要约束**：NSScroller 绘制层级**在 SwiftUI overlay 之上**（SwiftUI 限制，与 z-index 无关），
    ///     滚动条出现时会**覆盖**按钮 → trailing padding 必须留出 ~14pt 完全避开 NSScroller 宽度 (~12pt)。
    ///   - v1 设 padding.trailing = 6 时图二复现：滚动出现时滚动条把按钮右半压住。
    /// - **vertical padding 留呼吸感**：`.padding(.vertical, 6)` 而非旧版 `.padding(8)` —— TextEditor 内部
    ///   NSTextView 自带 textContainerInset 已经吃掉一部分上下空间，外层 6pt 即可，过大会让 inline 看起来臃肿。
    private var notesEditor: some View {
        TextEditor(text: $editingContent)
            .font(.system(.body, design: .default))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 76, maxHeight: 76)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
                    // v2.2（2026-06-17）光标 ↔ placeholder 对齐修正：
                    // SwiftUI TextEditor 包装的 NSTextView 在 macOS 15+ 上首行 insertion point 的 Y
                    // 不再额外叠加 textContainerInset.height（实测与 v2.1 假设的 +5pt 不符），
                    // 光标实际落在「外层 padding」之后的第一行基线，即 (8+5, 6) = (13, 6)。
                    // placeholder 必须与 TextEditor 同字体，且只用 leading/top 偏移，避免 vertical
                    // padding 把文字整体下推导致「光标在上、提示在下」。
                    Text("repo.notesPlaceholder")
                        .font(.system(.body, design: .default))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 13)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // v2.1（2026-06-13）按钮 trailing padding 精算（v2 给的 14pt 仍重叠）：
                // - 外层 padding(.horizontal, 8) → TextEditor 内部右边距 RoundedRectangle 8pt
                // - NSScroller 宽度 ≈ 12pt（macOS overlay scroller） → NSScroller 占据距右 8-20pt 区域
                // - 按钮圆形直径 = 5(padding) + 10(icon) + 5(padding) = 20pt
                // - 旧 trailing=14 → 按钮占据距右 14-34pt → **与 NSScroller 20-14 = 6pt 重合**
                // - 新 trailing=22 → 按钮占据距右 22-42pt → 完全避开 NSScroller 20pt 边界 + 2pt 余量
                expandButton
                    .padding(.trailing, 22)
                    .padding(.bottom, 6)
            }
    }

    /// 右下角「展开成大窗口编辑」按钮。
    ///
    /// 视觉：半透明 secondary 圆背景 + `arrow.up.left.and.arrow.down.right` 图标。
    /// 交互：点击 → `showEditorSheet = true` → 触发 sheet 弹起；hover 时背景透明度加深给反馈。
    /// 不打架细节（v2 更新）：
    /// - 与 SwiftUI placeholder（topLeading 对齐）不冲突；
    /// - 与 NSScroller **会冲突**（NSScroller 在 SwiftUI overlay 上方绘制，是 SwiftUI 固有限制），
    ///   靠外层 `.padding(.trailing, 14)` 让位 ~12pt 完全避开 NSScroller 宽度。
    private var expandButton: some View {
        Button {
            showEditorSheet = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(
                    Circle().fill(Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("repo.notes.expandEditor"))
    }

    // MARK: - 行为

    private func onRepoChange(to newId: Int64) async {
        aiGenerationViewModel?.discard()
        if viewModel == nil {
            viewModel = RepoNotesSectionViewModel(repoNoteRepository: dependencies.repoNoteRepository)
        }
        aiGenerationViewModel = RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteAIReadmeProvider(
                repository: dependencies.readmeRepository,
                readmeAPI: dependencies.readmeAPI
            ),
            aiService: dependencies.repoAIInsightService,
            maxReadmeLength: dependencies.settings.aiReadmeTruncateLength
        )
        // 切换前 flush 上一个 repo 的 buffer，避免丢失
        if let prevId = previousRepoId, prevId != newId, hasUnsavedChanges {
            await viewModel?.saveContent(repoId: prevId, content: editingContent)
        }
        // 切换 repo 时，取消上一个 repo 的"向量索引重建" debounce 任务——
        // 否则前一个 repo 的 1.5s timer 还会触发一次 refreshIndexIfChanged(prevRepo)，
        // 浪费 API 配额且语义混乱（当前页面已经在新 repo 上）。
        refreshIndexTask?.cancel()
        refreshIndexTask = nil
        previousRepoId = newId
        await viewModel?.loadFor(repoId: newId)
        editingContent = viewModel?.note?.content ?? ""
        hasUnsavedChanges = false
        saveState = .idle
        isNotesExpanded = false
    }

    /// 主动落库 + 触发语义索引重建。
    ///
    /// 调用方：
    /// - inline 防抖 `.task(id: editingContent)` 到点后；
    /// - `NoteEditorSheet.onFlush` 关闭前兜底；
    /// - `onRepoChange` 切 repo 前 flush 上一个 buffer（走 saveContent 直接落，未走本函数）。
    ///
    /// **idempotent 保证**：`hasUnsavedChanges == false` 时直接 return，避免 sheet 关闭时
    /// 重复触发 `saveContent` + `scheduleSemanticIndexRefresh`（语义索引 1.5s timer 每次启动
    /// 都会推迟实际生效）。inline 防抖 timer 与 sheet onFlush 二者只要有一个先到、把 dirty
    /// 翻成 false，另一个就会自动短路。
    private func flushContent() async {
        guard let vm = viewModel, hasUnsavedChanges else { return }
        saveState = .saving
        let succeeded = await vm.saveContent(repoId: repo.id, content: editingContent)
        guard succeeded else {
            saveState = .idle
            return
        }
        hasUnsavedChanges = false
        saveState = .saved
        if vm.errorMessage == nil, !editingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NotificationCenter.default.post(name: .gettingStartedDidOrganizeRepo, object: nil)
        }
        scheduleSemanticIndexRefresh()
    }

    /// 从当前编辑 buffer 冻结原笔记后启动 AI，不要求用户先等防抖保存。
    private func startAIGeneration() {
        guard let aiGenerationViewModel else { return }
        if !isNotesExpanded {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                isNotesExpanded = true
            }
        }
        aiGenerationViewModel.start(repo: repo, existingNote: editingContent)
    }

    /// 只有通过快照冲突检查后才写入 AI 草稿，并复用原笔记的索引刷新链路。
    private func applyAIDraft() async {
        guard let vm = viewModel,
              let aiViewModel = aiGenerationViewModel,
              let draft = aiViewModel.beginApplying(currentNote: editingContent)
        else { return }

        saveState = .saving
        let succeeded = await vm.saveContent(
            repoId: repo.id,
            content: draft,
            isAIGenerated: true
        )
        aiViewModel.finishApplying(success: succeeded)
        guard succeeded else {
            saveState = .idle
            return
        }

        editingContent = draft
        hasUnsavedChanges = false
        saveState = .saved
        NotificationCenter.default.post(name: .gettingStartedDidOrganizeRepo, object: nil)
        scheduleSemanticIndexRefresh()
    }

    /// 笔记落库成功后 1.5s 防抖触发向量重建。
    ///
    /// 实现要点：
    /// - 取消上一次未完成的 task → 启动新 task → sleep 1.5s（可被 cancel）→ 检查未取消后调用；
    /// - 即便 task 中途被 cancel，sleep 抛 CancellationError 也无需特别处理（外层 try? 吞掉）；
    /// - 仅当 dependencies.semanticSearchService 真实存在时调（保留 nil safety）。
    private func scheduleSemanticIndexRefresh() {
        refreshIndexTask?.cancel()
        let repoToRefresh = repo
        let service = dependencies.semanticSearchService
        refreshIndexTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await service.refreshIndexIfChanged(for: repoToRefresh)
        }
    }

    /// 把数据库里的 ISO8601 时间戳格式化为「yyyy-MM-dd HH:mm:ss」（当前系统时区，24 小时制）。
    ///
    /// 关键约束 / 已踩过的坑：
    /// - DB 写入的是带毫秒的 ISO8601（如 `2026-06-16T07:12:01.590Z`）。默认配置的
    ///   `ISO8601DateFormatter()` **不开启 `.withFractionalSeconds`**，解析这种字符串
    ///   会返回 nil → 旧实现 fallback 直接把原字符串显示在 UI 上,所以截图里看到了带 `Z`
    ///   的 raw ISO。这里同时尝试两种 formatOptions：先带毫秒,再退回不带毫秒,
    ///   兼容历史数据 / 第三方写入。
    /// - 用 `DateFormatter` + 固定 `dateFormat` 而不是 `Date.formatted(.dateTime...)`：
    ///   后者输出会因 locale 变成「2026年6月16日 15:12:01」之类的本地化形式,无法保证
    ///   字面格式稳定。`Locale(identifier: "en_US_POSIX")` 是 Apple 推荐的"固定格式"
    ///   习惯用法,避免不同地区下 `HH` 被改写或数字使用本地数字。
    /// - `timeZone` 不显式赋值 → 默认 `.current`,即用户设备所在时区,符合需求。
    private func formattedEditedAt(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: iso)
        }
        guard let date else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return out.string(from: date)
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
    @discardableResult
    func setStatus(repoId: Int64, status: RepoStatus) async -> Bool {
        do {
            try await repoNoteRepository.updateStatus(repoId: repoId, status: status)
            await loadFor(repoId: repoId)
            postStatusDidChange(repoId: repoId)
            return true
        } catch {
            errorMessage = "repo.notes.saveStatusFailed"
            return false
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
    @discardableResult
    func saveContent(
        repoId: Int64,
        content: String,
        isAIGenerated: Bool = false
    ) async -> Bool {
        do {
            let normalized: String? = content.isEmpty ? nil : content
            try await repoNoteRepository.updateContent(
                repoId: repoId,
                content: normalized,
                isAIGenerated: isAIGenerated
            )
            await loadFor(repoId: repoId)
            return true
        } catch {
            errorMessage = "repo.notes.saveContentFailed"
            return false
        }
    }

    func applyExternalContent(repoId: Int64, content: String, editedAt: String?) {
        let normalized: String? = content.isEmpty ? nil : content
        note = RepoNote(
            repoId: repoId,
            content: normalized,
            status: note?.status ?? RepoStatus.unread.rawValue,
            isAIGenerated: note?.isAIGenerated ?? false,
            editedAt: editedAt ?? note?.editedAt
        )
        errorMessage = nil
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
