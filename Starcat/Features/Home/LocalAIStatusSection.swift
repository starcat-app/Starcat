//
//  LocalAIStatusSection.swift
//  Starcat
//
//  Toolbar 状态面板里的本地模型驻留与快捷操作。只画出当前会进 MLX 的模型槽，
//  并标出对应业务；知识库问答 / Agent 不用本地对话模型。只在面板可见时采样，
//  每秒刷新值快照；不把高频内存变化传到整个主窗口，也不因打开面板加载模型。
//

import SwiftUI

/// 模型状态与释放入口保持在同一分区，让用户区分「卸载内存」与「删除下载文件」。
struct LocalAIStatusSection: View {
    var onOpenSettings: () -> Void = {}
    var onOpenLayaSettings: () -> Void = {}
    var onOpenLogs: (String) -> Void = { _ in }

    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var manager = LocalAIModelManager.shared
    @State private var layaManager = LayaDecisionModelManager.shared
    @State private var snapshot = LocalAIRuntimeSnapshot()
    @State private var layaSnapshot = LayaDecisionRuntimeSnapshot()
    @State private var pending: Set<String> = []
    @State private var error: String?

    var body: some View {
        let models = settings.localAIStatusModels(installedModels: manager.installedModels)
        let showsLaya = settings.decisionEngineEnabled && settings.decisionEngineID == .laya
        if LocalAIHardwareSupport.isLocalAIAvailable, !models.isEmpty || showsLaya {
            AppStatusGroupCard {
                statusContent(models, showsLaya: showsLaya)
            }
            .task {
                while !Task.isCancelled {
                    await refreshSnapshots()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    private func statusContent(
        _ models: [LocalAIStatusModel],
        showsLaya: Bool
    ) -> some View {
        let totalQueued = snapshot.queuedCount + layaSnapshot.queuedCount
        return VStack(alignment: .leading, spacing: 10) {
            header
            metricRow
            if totalQueued > 0 {
                Text(String(format: String.l10n("toolbar.localai.queued"), totalQueued))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(Array(models.enumerated()), id: \.element.id) { index, row in
                modelRow(row)
                    .listRowSurface(index: index)
            }
            if showsLaya {
                layaModelRow
                    .listRowSurface(index: models.count)
            }
            Text("toolbar.localai.memoryHelp")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = error ?? snapshot.notice {
                Text(verbatim: message)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(interfaceScale.font(.iconMedium, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("toolbar.localai.title")
                .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
            HStack(spacing: 5) {
                Circle()
                    .fill(isRuntimeActive ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(isRuntimeActive ? "toolbar.status.localai.running" : "toolbar.status.localai.stopped")
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: {
                run("all", operation: unloadAllModels)
            }) {
                HStack(spacing: 4) {
                    Text("toolbar.localai.unloadAll")
                    Image(systemName: "chevron.right")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                }
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(pending.contains("all") || !hasResidentModels)
        }
    }

    private var metricRow: some View {
        HStack(spacing: 8) {
            metricTile(
                title: "toolbar.localai.active",
                bytes: snapshot.activeBytes,
                systemImage: "square.3.layers.3d",
                tint: .blue
            )
            metricTile(
                title: "toolbar.localai.cache",
                bytes: snapshot.cacheBytes,
                systemImage: "clock.arrow.circlepath",
                tint: .orange
            )
            metricTile(
                title: "toolbar.localai.budget",
                bytes: snapshot.budgetBytes,
                systemImage: "memorychip",
                tint: .secondary
            )
        }
    }

    private func metricTile(
        title: LocalizedStringKey,
        bytes: Int,
        systemImage: String,
        tint: Color
    ) -> some View {
        // 和第二行概览卡同一套：图标独占一列，数值跟标题左缘对齐，不跟图标对齐。
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: format(bytes))
                    .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func modelRow(_ row: LocalAIStatusModel) -> some View {
        let model = row.entry
        let installed = manager.installedModel(id: model.id)
        let resident = snapshot.models[model.type].flatMap {
            $0.directory.lastPathComponent == installed?.idWithRevision ? $0 : nil
        }
        let phase = resident?.phase ?? .notLoaded
        let canUnload = [.ready, .running, .loading].contains(phase)
        let actionKey = canUnload ? "toolbar.localai.unload" : "toolbar.localai.load"
        let typeTint = modelTypeTint(model.type)
        return HStack(spacing: 8) {
            Image(systemName: modelTypeIcon(model.type))
                .font(interfaceScale.font(.iconMedium, weight: .semibold))
                .foregroundStyle(typeTint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.displayName)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.displayName)
                usageChips(row.usages)
                HStack(spacing: 4) {
                    Circle()
                        .fill(phaseDotColor(phase, installed: installed != nil))
                        .frame(width: 6, height: 6)
                    Text(LocalizedStringKey(installed == nil ? "toolbar.localai.notDownloaded" : phase.localizationKey))
                    if let resident, resident.loadedBytes > 0 {
                        Text(
                            String(
                                format: String.l10n("toolbar.localai.loadedMemory"),
                                format(resident.loadedBytes)
                            )
                        )
                        .monospacedDigit()
                    }
                }
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let message = resident?.error, phase == .failed {
                    Text(verbatim: message)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(message)
                }
            }
            Spacer(minLength: 0)
            Button(LocalizedStringKey(actionKey)) {
                run(model.id) {
                    if canUnload {
                        await LocalMLXRuntime.shared.unload(types: [model.type])
                    } else if let directory = manager.installedDirectoryURL(entryID: model.id) {
                        try await LocalMLXRuntime.shared.preload(entry: model, directory: directory)
                    }
                }
            }
            .controlSize(.small)
            // 手动加载尚未返回时仍允许点卸载，由运行时取消加载并等待 GPU 收尾。
            .disabled(
                installed == nil
                    || (pending.contains(model.id) && !canUnload)
                    || pending.contains("all")
                    || phase == .unloading
            )
            .accessibilityLabel("\(String.l10n(actionKey)) \(model.displayName)")

            Menu {
                Button("localai.logs.open") { onOpenLogs(model.id) }
                Divider()
                Button("toolbar.localai.clearCache") {
                    run("cache", operation: clearMemoryCache)
                }
                .disabled(snapshot.cacheBytes == 0 || pending.contains("cache"))
                Button("toolbar.status.localai.openSettings", action: onOpenSettings)
            } label: {
                Label {
                    Text("toolbar.status.localai.openSettings")
                } icon: {
                    Image(systemName: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .font(interfaceScale.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .focusEffectDisabled()
        }
    }

    /// Laya 使用独立 runtime 与磁盘目录，但在状态面板中遵循和普通模型相同的
    /// “已下载 ≠ 已加载”语义以及加载、卸载、日志和设置入口。
    private var layaModelRow: some View {
        let descriptor = LayaDecisionModelCatalog.multilingual
        let installedDirectory = layaManager.installedDirectoryURL?.standardizedFileURL
        let resident = layaSnapshot.model.flatMap { model in
            model.directory.standardizedFileURL == installedDirectory ? model : nil
        }
        let phase = resident?.phase ?? .notLoaded
        let canUnload = [.ready, .running, .loading].contains(phase)
        let actionKey = canUnload ? "toolbar.localai.unload" : "toolbar.localai.load"
        return HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(interfaceScale.font(.iconMedium, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: descriptor.displayName)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(descriptor.displayName)
                usageChips([.decision])
                HStack(spacing: 4) {
                    Circle()
                        .fill(phaseDotColor(phase, installed: installedDirectory != nil))
                        .frame(width: 6, height: 6)
                    Text(LocalizedStringKey(
                        installedDirectory == nil
                            ? "toolbar.localai.notDownloaded"
                            : phase.localizationKey
                    ))
                    if let resident, resident.loadedBytes > 0 {
                        Text(String(
                            format: String.l10n("toolbar.localai.loadedMemory"),
                            format(resident.loadedBytes)
                        ))
                        .monospacedDigit()
                    }
                }
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let message = resident?.error, phase == .failed {
                    Text(verbatim: message)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(message)
                }
            }
            Spacer(minLength: 0)
            Button(LocalizedStringKey(actionKey)) {
                run(descriptor.id) {
                    if canUnload {
                        try await layaManager.unloadFromMemory()
                    } else {
                        try await layaManager.loadIntoMemory()
                    }
                }
            }
            .controlSize(.small)
            .disabled(
                installedDirectory == nil
                    || (pending.contains(descriptor.id) && !canUnload)
                    || pending.contains("all")
                    || phase == .unloading
            )
            .accessibilityLabel("\(String.l10n(actionKey)) \(descriptor.displayName)")

            Menu {
                Button("localai.logs.open") { onOpenLogs(descriptor.id) }
                Divider()
                Button("toolbar.localai.clearCache") {
                    run("cache", operation: clearMemoryCache)
                }
                .disabled(snapshot.cacheBytes == 0 || pending.contains("cache"))
                Button("toolbar.status.localai.openSettings", action: onOpenLayaSettings)
            } label: {
                Label {
                    Text("toolbar.status.localai.openSettings")
                } icon: {
                    Image(systemName: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .font(interfaceScale.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .focusEffectDisabled()
        }
    }

    /// 业务标识复用任务页 / Rerank 标题的现成 key；完整字面量避免 LocalizedStringKey 插值丢翻译。
    private func usageChips(_ usages: [LocalAIStatusUsage]) -> some View {
        HStack(spacing: 4) {
            ForEach(usages, id: \.self) { usage in
                Text(Self.usageLabelKey(usage))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var hasResidentModels: Bool {
        snapshot.models.values.contains { [.loading, .ready, .running].contains($0.phase) }
            || layaSnapshot.model.map { [.loading, .ready, .running].contains($0.phase) } == true
    }

    /// 有模型驻留或正在加载时显示「已启动」，对应原型里的绿点。
    private var isRuntimeActive: Bool {
        hasResidentModels || snapshot.activeBytes > 0
    }

    private func modelTypeIcon(_ type: LocalAIModelType) -> String {
        switch type {
        case .embedding: return "cube.fill"
        case .reranker: return "square.stack.3d.up.fill"
        case .llm: return "sparkles"
        }
    }

    private func modelTypeTint(_ type: LocalAIModelType) -> Color {
        switch type {
        case .embedding: return .purple
        case .reranker: return .blue
        case .llm: return .green
        }
    }

    private func phaseDotColor(_ phase: LocalAIRuntimePhase, installed: Bool) -> Color {
        if !installed { return .secondary }
        switch phase {
        case .ready, .running, .loading: return .green
        case .failed: return .orange
        case .unloading, .notLoaded, .unloaded: return .secondary
        }
    }

    /// 使用完整字面量 key；LocalizedStringKey 的直接插值会生成 %@ 格式键，无法命中类别翻译。
    static func modelTypeLabelKey(_ type: LocalAIModelType) -> LocalizedStringKey {
        switch type {
        case .embedding: return "settings.localai.model.type.embedding"
        case .reranker: return "settings.localai.model.type.reranker"
        case .llm: return "settings.localai.model.type.llm"
        }
    }

    /// 业务标识同样必须用完整字面量 key，不能用 `"ai.task.\(task.rawValue)"` 插值。
    static func usageLabelKey(_ usage: LocalAIStatusUsage) -> LocalizedStringKey {
        switch usage {
        case .task(.summary): return "ai.task.summary"
        case .task(.tags): return "ai.task.tags"
        case .task(.chat): return "ai.task.chat"
        case .task(.embedding): return "ai.task.embedding"
        case .task(.translation): return "ai.task.translation"
        case .rerank: return "rag.workspace.rerank.title"
        case .decision: return "settings.labs.decision.section"
        }
    }

    private func unloadAllModels() async throws {
        await LocalMLXRuntime.shared.unloadAll()
        // 快照最多落后一次轮询；无条件请求 Laya 卸载，避免它刚加载完成却被“全部卸载”漏掉。
        // runtime 的空状态卸载是 no-op，不会触碰已下载文件。
        try await layaManager.unloadFromMemory(reason: "unload_all")
    }

    private func clearMemoryCache() async {
        await LocalMLXRuntime.shared.clearMemoryCache(
            includeExternallyInitializedMemory: layaSnapshot.isMLXInitialized
        )
    }

    /// 先读 Laya 是否已初始化 MLX，再读取进程级 Memory；两套 runtime 共享同一组
    /// 统计，不能相加，否则同时驻留时会把内存重复计算两次。
    private func refreshSnapshots() async {
        let latestLaya = await LayaDecisionRuntimeStore.shared.snapshot()
        let latestLocal = await LocalMLXRuntime.shared.snapshot(
            includeExternallyInitializedMemory: latestLaya.isMLXInitialized
        )
        layaSnapshot = latestLaya
        snapshot = latestLocal
    }

    /// 操作独立于面板的采样 task；关闭 popover 不应让手动卸载中途被取消。
    private func run(_ id: String, operation: @escaping @MainActor () async throws -> Void) {
        pending.insert(id)
        error = nil
        Task {
            defer { pending.remove(id) }
            do { try await operation() } catch is CancellationError {} catch {
                self.error = error.localizedDescription
            }
            await refreshSnapshots()
        }
    }

    private func format(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}
