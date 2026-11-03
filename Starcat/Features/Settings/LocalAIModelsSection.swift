//
//  LocalAIModelsSection.swift
//  Starcat
//
//  AI 设置页的「本地 AI 模型」管理区。
//
//  结构：
//  - 顶部「下载源」Picker（Hugging Face / 魔塔 ModelScope），只影响新下载；
//  - 每个模型类别一行：类别图标 + 模型下拉（该类已收录模型）+ 选中模型的
//    大小 / 状态 / 进度（4pt 细条 + 字节 / 百分比 / 速度）与操作按钮；
//  - 底部：存储占用、检查模型、在 Finder 中显示、清除全部（二次确认）。
//
//  约束：
//  - 独立 Section，不依赖内置 profile 的验证状态——用户必须能在这里下载模型，
//    之后 profile 才会被 `LocalAIModelManager.syncBuiltInProfile()` 标记为已验证。
//  - UI 只暴露「推荐 / Lite」与下载状态，不暴露量化格式。
//  - 遵循设置页规范：独立操作按钮右对齐、`.buttonStyle(.plain)` 必须配
//    `.focusEffectDisabled()`、危险操作二次确认、颜色只用 .primary/.secondary。
//

import AppKit
import SwiftUI

struct LocalAIModelsSection: View {

    let settings: AppSettings

    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var manager = LocalAIModelManager.shared
    @State private var pendingClearAllConfirm = false
    /// 当前展开浮层下拉的类别（同一时刻至多一个）。
    @State private var expandedDropdown: LocalAIModelType?

    /// 下拉顺序固定，避免设置页刷新时选项跳动。
    private let displayedTypes: [LocalAIModelType] = [.embedding, .reranker, .llm]

    /// 本区块行内 icon 的统一口径：下载、绿色对勾、删除共用同一字号，保证同行一致。
    /// 12pt regular——`checkmark.circle.fill` 是实心填充、视觉重量大，必须比线性图标
    /// 小一档才与下拉箭头等周边图标协调（dong4j 2026-09-12 反馈「做得太大」）；
    /// 命中区保持 28×28 不影响点击。
    /// 模型下拉固定宽度：选中项变化不改变组件尺寸；右侧不留过多空白（dong4j 2026-09-12）。
    private static let modelDropdownWidth: CGFloat = 170

    /// 下拉浮层宽度：容纳名称 + 胶囊徽标，中英文均不换行。
    private static let modelPopoverWidth: CGFloat = 280

    /// 行尾状态区固定宽度：容纳两个 28pt 图标（对勾 + 删除）。
    private static let statusAreaWidth: CGFloat = 62

    /// 行内状态图标与行尾按钮统一引用设置页 icon-only 口径（15pt medium / 28×28），
    /// 不再自定 12pt 规则字重，避免和其它设置页行尾按钮大小不一。
    private static let rowIconFont = SettingsIconMetrics.standardGlyph
    private static let rowIconFrameSize: CGFloat = SettingsIconMetrics.actionFrameSize

    var body: some View {
        Section {
            sourcePickerRow

            ForEach(displayedTypes) { type in
                typeGroup(type)
            }

            HStack {
                Text(storageUsageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                Button {
                    revealModelsDirectory()
                } label: {
                    Text("settings.localai.storage.reveal")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(manager.modelsRootURL == nil)

                Button(role: .destructive) {
                    pendingClearAllConfirm = true
                } label: {
                    Text("settings.localai.storage.clearAll")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(manager.installedModels.isEmpty)
            }
        } header: {
            SettingsSectionHeader(
                "settings.localai.section.title",
                systemImage: "cpu"
            )
        } footer: {
            Text("settings.localai.section.footer")
        }
        // alert 同样在独立宿主呈现：文案走 String.l10n，避免popover 同款的
        // locale 环境丢失问题（EN 界面出现中文）。
        .alert(
            String.l10n("settings.localai.storage.clearAll.confirmTitle"),
            isPresented: $pendingClearAllConfirm
        ) {
            Button(String.l10n("settings.localai.storage.clearAll.confirm"), role: .destructive) {
                manager.deleteAll()
            }
            Button(String.l10n("settings.common.cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: String.l10n("settings.localai.storage.clearAll.confirmMessage"))
        }
    }

    // MARK: - 下载源

    private var sourcePickerRow: some View {
        HStack {
            Text("settings.localai.source.label")
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Picker("settings.localai.source.label", selection: sourceBinding) {
                Text("settings.localai.source.huggingface").tag(LocalAIModelSource.Kind.huggingFace)
                Text("settings.localai.source.modelscope").tag(LocalAIModelSource.Kind.modelScope)
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var sourceBinding: Binding<LocalAIModelSource.Kind> {
        Binding(
            get: { settings.localAIDownloadSource },
            set: {
                settings.localAIDownloadSource = $0
                // 断点续传文件按源隔离 + 切源即清：HF 的 part 前缀拼上魔塔的后续数据
                // 会产出损坏权重（禁止静默混流，dong4j 2026-09-12）。
                manager.cleanPartialDownloadsForSourceChange()
            })
    }

    // MARK: - 类别分组行

    @ViewBuilder
    private func typeGroup(_ type: LocalAIModelType) -> some View {
        let entry = selectedEntry(for: type)
        let state = manager.installState(for: entry.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                BusinessIcon(source: type.iconSource, pointSize: type.iconSource.isAsset ? 16 : 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(typeLabel(type))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                modelDropdown(type)

                // 状态区固定宽度：下载(1 图标)与已安装(2 图标)状态下下拉右缘保持齐平，
                // 内容不足时靠右补位（dong4j 2026-09-12：下拉全部右对齐）。
                statusView(for: entry, state: state)
                    .frame(width: Self.statusAreaWidth, alignment: .trailing)
            }

            Text(sizeCaption(for: entry))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 30)

            if case .downloading(let progress, let completedBytes, let totalBytes, let speed) = state {
                let caption = progressCaption(
                    progress: progress,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    speedBytesPerSecond: speed)
                thinProgressBar(progress)
                    .padding(.leading, 30)
                // 整行拼成一个 Text 渲染。早前把「字节 / 百分比 / 速度」拆成定宽列，
                // 列内补位在分隔符两侧各留出十几 pt，首列又是 trailing 对齐，把行首
                // 文字从 30pt 缩进线顶出去、整行看着像居中（dong4j 2026-09-15）。
                // 单串渲染后间距就是「 · 」本身，且与上方体积说明、进度条同一条缩进线。
                // 数字漂移交给 .monospacedDigit()：单字段每变一次只移动一个字宽，
                // 且同一单位贯穿全程（见 progressCaption 的 allowedUnits）。
                Text(verbatim: caption.line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(Text(verbatim: caption.accessibilityText))
                    .padding(.leading, 30)
            }

            stateMessageCaption(state)
                .padding(.leading, 30)
        }
        .padding(.vertical, 2)
        .help(String(format: String.l10n("settings.localai.model.memoryHelpFormat"),
                     ByteCountFormatter.string(fromByteCount: entry.estimatedDownloadSize, countStyle: .file),
                     ByteCountFormatter.string(fromByteCount: Int64(entry.memoryRecommendation), countStyle: .file)))
    }

    /// 固定宽度自绘下拉（dong4j 2026-09-12：系统 Picker 随选中项文字长度伸缩，
    /// 切换模型时整行组件乱跳；主窗口 toolbar 打开链接菜单即固定 label 思路）。
    /// label 固定 220pt，选中名超长走中间省略；菜单项由系统渲染，当前项带 ✓。
    /// 固定宽度自绘下拉（popover 浮层）。不用系统 Menu：NSMenu 只能渲染纯文本，
    /// 做不出 dong4j 要的推荐/轻量胶囊徽标（2026-09-12）。
    private func modelDropdown(_ type: LocalAIModelType) -> some View {
        let selected = selectedEntry(for: type)
        let isOpen = Binding(
            get: { expandedDropdown == type },
            set: { if !$0, expandedDropdown == type { expandedDropdown = nil } }
        )
        return Button {
            expandedDropdown = expandedDropdown == nil ? type : nil
        } label: {
            HStack(spacing: 6) {
                Text(selected.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.modelDropdownWidth, alignment: .trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .fixedSize()
        .popover(isPresented: isOpen, arrowEdge: .top) {
            modelOptionList(type, selected: selected)
                .frame(width: Self.modelPopoverWidth)
                .padding(.vertical, 6)
                .appLocaleEnvironment()
        }
        .accessibilityLabel(Text(typeLabel(type)))
    }

    /// 浮层选项列表：对勾 + 模型名 + 档位胶囊徽标（推荐绿色 / 轻量中性）。
    private func modelOptionList(
        _ type: LocalAIModelType, selected: LocalAIModelCatalogEntry
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(LocalAIModelCatalog.entries(of: type)) { entry in
                let isSelected = entry.id == selected.id
                Button {
                    settings.localAIModelSelections[type.rawValue] = entry.id
                    expandedDropdown = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .opacity(isSelected ? 1 : 0)
                            .frame(width: 12)
                        Text(entry.displayName)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        // 已下载标识（dong4j 2026-09-15）：与行内 `.installed` 状态共用绿色
                        // 实心对勾，让「本机已有」在下拉和行尾是同一套符号语言，复用同一个
                        // 本地化 key。放在行尾而不是紧跟模型名：行首 checkmark 已经表示
                        // 「当前选中」，名字两边各挂一个对勾会读成同一件事；行尾的实心
                        // 圆形对勾与行首线性对勾形状、颜色都不同，且选中态只会命中一行、
                        // 已下载可以命中多行，不会混淆。
                        // 字号比行首 checkmark 小一档：实心 glyph 视觉重量大（同文件
                        // rowIconFont 口径）。
                        if isInstalled(entry) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                                .help(Text("settings.localai.model.status.installed"))
                                .accessibilityLabel(Text("settings.localai.model.status.installed"))
                        }
                        badgeCapsule(entry)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
    }

    /// 档位胶囊：推荐 = 绿色调，轻量 = 中性；短文案 + 单行，中英文都不换行。
    @ViewBuilder
    private func badgeCapsule(_ entry: LocalAIModelCatalogEntry) -> some View {
        // 推荐档用黄色星星图标（dong4j 2026-09-12：Recommended 文案太长，
        // 会挤压模型全称）；轻量保留中性短文案胶囊。
        if entry.recommended {
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
                .help(Text("settings.localai.model.badge.recommended"))
                .accessibilityLabel(Text("settings.localai.model.badge.recommended"))
        } else if entry.isLite {
            Text("settings.localai.model.badge.lite")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// 当前类别选中的模型：显式选择 > 已安装 > 推荐 > 首个。
    private func selectedEntry(for type: LocalAIModelType) -> LocalAIModelCatalogEntry {
        settings.selectedLocalAIModel(for: type, installedModels: manager.installedModels)
    }

    /// 该模型是否已下载到本机。以磁盘 manifest 为准，不走 `installState`：
    /// `installState` 在容器加载失败时返回 `.loadFailed`，但权重文件确实已经落盘，
    /// 对用户来说就是「已下载」，加载态不该把这个标识抹掉。
    private func isInstalled(_ entry: LocalAIModelCatalogEntry) -> Bool {
        manager.installedModel(id: entry.id) != nil
    }

    private func typeLabel(_ type: LocalAIModelType) -> String {
        switch type {
        case .embedding: return String.l10n("settings.localai.model.type.embedding")
        case .reranker: return String.l10n("settings.localai.model.type.reranker")
        case .llm: return String.l10n("settings.localai.model.type.llm")
        }
    }

    // MARK: - 状态与操作

    /// 行尾状态区：只放 62pt 定宽内装得下的图标（dong4j 2026-09-12——
    /// 「Preparing…」等带文字状态被定宽挤压成竖排的修正）。
    /// 失败原因 / 加载中等长文案一律放到行下方整行 caption。
    @ViewBuilder
    private func statusView(
        for entry: LocalAIModelCatalogEntry,
        state: LocalAIInstallState
    ) -> some View {
        switch state {
        case .idle:
            if entry.isAvailable(on: settings.localAIDownloadSource) {
                Button {
                    manager.install(entry: entry)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(Self.rowIconFont)
                        .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("settings.localai.model.action.download")
                .accessibilityLabel(Text("settings.localai.model.action.download"))
            } else {
                // catalog 未收录该模型在当前下载源的镜像（白名单制，禁止静默换源）。
                Image(systemName: "arrow.down.circle")
                    .font(Self.rowIconFont)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                    .help(Text("settings.localai.source.unavailable"))
            }

        case .preparing:
            // 点击与首个进度回调之间的瞬态：转圈 + 可暂停，不需要文字。
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                pauseButton(entry)
            }

        case .downloading:
            pauseButton(entry)

        case .loading:
            // MLX 不暴露权重加载的字节进度：只给薄荷色不确定细条，宽度对齐状态区。
            indeterminateBar
                .frame(width: Self.statusAreaWidth - 4)
                .help(Text("settings.localai.model.status.loading"))

        case .deleting:
            ProgressView()
                .controlSize(.small)
                .help(Text("settings.localai.model.action.delete"))

        case .failed:
            Button {
                manager.install(entry: entry)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
                    .font(Self.rowIconFont)
                    .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("settings.localai.model.action.retry")
            .accessibilityLabel(Text("settings.localai.model.action.retry"))

        case .loadFailed:
            Button {
                manager.retryLoad(entry: entry)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
                    .font(Self.rowIconFont)
                    .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("settings.localai.model.action.retryLoad")
            .accessibilityLabel(Text("settings.localai.model.action.retryLoad"))

        case .deleteFailed:
            deleteButton(entry)

        case .installed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(Self.rowIconFont)
                    .foregroundStyle(.green)
                    .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                    .accessibilityLabel(Text("settings.localai.model.status.installed"))
                deleteButton(entry)
            }
        }
    }

    /// 行下方整行 caption：下载 / 加载失败的原因（状态区放不下长文案）。
    @ViewBuilder
    private func stateMessageCaption(_ state: LocalAIInstallState) -> some View {
        switch state {
        case .failed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        case .loadFailed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        case .deleteFailed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }

    private func pauseButton(_ entry: LocalAIModelCatalogEntry) -> some View {
        Button {
            manager.pause(entryID: entry.id)
        } label: {
            Image(systemName: "pause.circle")
                .font(Self.rowIconFont)
                .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("settings.localai.model.action.pause")
        .accessibilityLabel(Text("settings.localai.model.action.pause"))
    }

    private func deleteButton(_ entry: LocalAIModelCatalogEntry) -> some View {
        DestructiveIconButton(
            help: Text("settings.localai.model.action.delete"),
            font: Self.rowIconFont,
            frameSize: Self.rowIconFrameSize
        ) {
            manager.delete(entryID: entry.id)
        }
    }

    // MARK: - 进度展示

    /// 加载中的不确定进度条：薄荷色滑块往复运动；开启「减弱动态效果」时静态半格。
    @ViewBuilder
    private var indeterminateBar: some View {
        if reduceMotion {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.mint).frame(width: geo.size.width * 0.5)
                }
            }
            .frame(height: 4)
        } else {
            IndeterminateCapsuleBar()
        }
    }

    /// 4pt 细进度条：macOS 默认 `.linear` 样式过粗；自定义 Capsule 保证粗细一致。
    private func thinProgressBar(_ progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.25), value: progress)
        .accessibilityLabel(Text("settings.localai.section.title"))
        .accessibilityValue(Text("\(Int(progress * 100))%"))
    }

    /// 生成进度行文案：`行内容`（整行渲染）+ `无障碍文案`。
    /// 首个速度采样完成前用破折号占位，避免整行突然变长。
    private func progressCaption(
        progress: Double,
        completedBytes: Int64,
        totalBytes: Int64,
        speedBytesPerSecond: Double?
    ) -> (line: String, accessibilityText: String) {
        // 不用 String(format:) 的位置参数格式串：%1$@ 与 %% 混用会把参数错位读成
        // 指针垃圾（曾显示 849191526%，dong4j 2026-09-12）。数字+单位本身语言中立，
        // 直接插值拼装。
        let progressFormatter = ByteCountFormatter()
        progressFormatter.countStyle = .file
        progressFormatter.zeroPadsFractionDigits = true
        // 已下载量与总量始终使用同一单位，避免跨过 1 GB 时从 MB 切成 GB 导致行内抖动。
        progressFormatter.allowedUnits = totalBytes >= 1_000_000_000 ? .useGB : .useMB
        let completed = progressFormatter.string(fromByteCount: completedBytes)
        let total = progressFormatter.string(fromByteCount: totalBytes)
        let byteText = "\(completed) / \(total)"
        let percentText = "\(Int((max(0, min(1, progress)) * 100).rounded()))%"
        let speedText: String
        let accessibilityText: String
        if let speed = speedBytesPerSecond, speed > 0 {
            let formattedSpeed = ByteCountFormatter.string(
                fromByteCount: Int64(speed), countStyle: .file)
            speedText = "\(formattedSpeed)/s"
            accessibilityText = "\(byteText) · \(percentText) · \(speedText)"
        } else {
            speedText = "—"
            // 破折号只是视觉占位，念出来没有意义。
            accessibilityText = "\(byteText) · \(percentText)"
        }
        return ("\(byteText) · \(percentText) · \(speedText)", accessibilityText)
    }

    private func sizeCaption(for entry: LocalAIModelCatalogEntry) -> String {
        // 直接显示体积，不加「下载约」前缀（dong4j 2026-09-12 反馈）。
        var parts: [String] = [
            ByteCountFormatter.string(fromByteCount: entry.estimatedDownloadSize, countStyle: .file)
        ]
        if let dimension = entry.embeddingDimension {
            parts.append(String(
                format: String.l10n("settings.localai.model.dimensionFormat"), dimension))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 其它动作

    private var storageUsageText: String {
        let usage = ByteCountFormatter.string(fromByteCount: manager.totalDiskUsage, countStyle: .file)
        return String(format: String.l10n("settings.localai.storage.usageFormat"), usage)
    }

    private func revealModelsDirectory() {
        guard let url = manager.modelsRootURL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}


/// 薄荷色往复滑块：加载阶段 MLX 不暴露字节进度，用不确定动画表达「正在进行」。
private struct IndeterminateCapsuleBar: View {
    @State private var trailing: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.mint)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: trailing ? geo.size.width * 0.65 : 0)
            }
        }
        .frame(height: 4)
        .accessibilityLabel(Text("settings.localai.model.status.loading"))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                trailing = true
            }
        }
    }
}
