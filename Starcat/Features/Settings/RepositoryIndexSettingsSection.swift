//
//  RepositoryIndexSettingsSection.swift
//  Starcat
//
//  仓库搜索索引的执行记录与操作。处理数包含跳过项，不能作为向量库存覆盖率。
//  开始、暂停、继续与全量重建均沿用 SemanticIndexBuilder。
//

import SwiftUI

/// 活任务优先显示实时计数，空闲时读取持久化执行记录。
struct RepositoryIndexSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    @State private var confirmsRebuild = false

    private var builder: SemanticIndexBuilder { dependencies.semanticIndexBuilder }
    private var isActive: Bool { builder.status == .running || builder.status == .paused }
    private var hasModel: Bool { (try? settings.resolveEmbeddingSelection()) != nil }

    var body: some View {
        // 一张卡片只占一个 Form 行，内部显式分区，避免系统在每段说明之间插入分隔线。
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(isActive
                             ? "settings.searchIndex.layout.currentRun"
                             : "settings.searchIndex.layout.lastRun"))
                            .font(.callout.weight(.medium))
                        Text("settings.searchIndex.repository.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    IndexSettingsStatusBadge(status: SearchIndexStatus.repository(
                        status: builder.status,
                        failures: builder.failures,
                        lastRun: settings.semanticIndexLastPrefetch
                    ))
                }

                if isActive {
                    progressCounts(processed: builder.processed, total: builder.total, failures: builder.failures)
                    ProgressView(value: Double(builder.processed), total: Double(max(1, builder.total)))
                        .tint(builder.status == .paused ? RAGBackendTestStatus.warningTint : .accentColor)
                } else if let last = settings.semanticIndexLastPrefetch {
                    progressCounts(processed: last.processed, total: last.total, failures: last.failures)
                    if last.outcome == .failed, let message = last.failureMessage, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !hasModel {
                    Text("settings.searchIndex.repository.noModel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                actionsRow
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                SettingsSectionHeader("settings.searchIndex.repository.title", businessIcon: .aiIndex)
                Spacer(minLength: 8)
                Text("settings.searchIndex.layout.repoTagline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("settings.searchIndex.repository.rebuildImpact")
        }
        .sheet(isPresented: $confirmsRebuild) {
            IndexRebuildConfirmationSheet(kind: .repository) {
                // 确认期间模型可能被修改；不使用打开弹窗时捕获的配置。
                guard hasModel, !isActive else { return }
                builder.rebuildAll()
            }
            .appLocaleEnvironment()
        }
    }

    private var actionsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if let last = settings.semanticIndexLastPrefetch {
                    Text(String(
                        format: String.l10n("settings.searchIndex.layout.lastTime"),
                        locale: locale, RelativeTimeText.pastEvent(last.finishedAt, locale: locale)
                    ))
                } else {
                    Text("settings.aiIndex.prefetch.neverRun")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(role: .destructive) { confirmsRebuild = true } label: {
                Text("settings.searchIndex.layout.fullRebuild")
                    .foregroundStyle(RAGBackendTestStatus.dangerTint)
            }
            .buttonStyle(.bordered)
            .disabled(!hasModel || isActive)
            switch builder.status {
            case .running:
                Button("settings.aiIndex.prefetch.pause") { builder.pause() }
                    .buttonStyle(.bordered)
            case .paused:
                Button("settings.aiIndex.prefetch.resume") { builder.resume() }
                    .buttonStyle(.bordered)
                    .disabled(!hasModel)
            default:
                Button("settings.aiIndex.prefetch.start") {
                    builder.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(!hasModel)
            }
        }
        .controlSize(.regular)
    }

    /// 计数与结果分开：存在失败时不把“遍历完成”表述为全部索引成功。
    private func progressCounts(processed: Int, total: Int, failures: Int) -> some View {
        HStack(alignment: .top, spacing: 20) {
            IndexSettingsMetric(
                value: processed, total: total,
                unit: "settings.searchIndex.layout.repoUnit",
                caption: "settings.searchIndex.layout.processed"
            )
            Divider().frame(height: 56)
            IndexSettingsMetric(
                value: failures,
                unit: "settings.searchIndex.layout.itemUnit",
                caption: "settings.searchIndex.layout.failures"
            )
        }
        .padding(.vertical, 4)
    }
}
