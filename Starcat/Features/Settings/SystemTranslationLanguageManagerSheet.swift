//
//  SystemTranslationLanguageManagerSheet.swift
//  Starcat
//
//  系统翻译语言管理 Sheet：展示语言组合状态，并通过 Apple 提供的系统界面
//  请求提前下载语言包。
//
//  关键约束：
//  - `TranslationSession` 必须绑定当前 SwiftUI View 生命周期，因此下载配置只放在本 Sheet；
//  - `prepareTranslation()` 的授权与下载进度由 macOS 托管，Starcat 不静默下载；
//  - Apple 没有开放删除语言包的 API，删除操作只能跳转系统设置。
//

import SwiftUI
import Translation

/// 管理当前目标语言对应的 Apple 系统翻译语言组合。
struct SystemTranslationLanguageManagerSheet: View {
    let targetLanguage: ReadmeTranslationLanguage
    let catalog: SystemTranslationLanguageCatalog
    let openSystemSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var downloadConfiguration: TranslationSession.Configuration?
    @State private var pendingSourceIdentifier: String?
    @State private var downloadErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 480, idealHeight: 560)
        .task(id: resolvedTarget.rawValue) {
            pendingSourceIdentifier = nil
            downloadConfiguration = nil
            downloadErrorMessage = nil
            // 每次打开都重读系统状态，避免用户在「语言与地区」删除语言包后，
            // 再次进入仍看到上一次 Sheet 缓存的结果。
            await catalog.refresh(target: resolvedTarget, force: true)
        }
        .translationTask(downloadConfiguration) { session in
            await prepareLanguage(using: session)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "character.bubble")
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("settings.translation.system.sheet.title")
                    .font(.headline)
                Text(verbatim: String(
                    format: String.l10n("settings.translation.system.sheet.subtitleFormat"),
                    resolvedTarget.displayName
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            SyncIconButton(
                isRefreshing: catalog.isRefreshing,
                disabled: catalog.isRefreshing || pendingSourceIdentifier != nil,
                // 设置页 icon-only 标准口径；SyncIconButton 自身默认是全 App 刷新按钮的
                // 18pt 基准，设置域内显式覆盖为 15pt / 28×28。
                font: SettingsIconMetrics.standardGlyph,
                frameSize: SettingsIconMetrics.actionFrameSize,
                tooltip: String.l10n("settings.translation.system.refresh")
            ) {
                Task { await catalog.refresh(target: resolvedTarget, force: true) }
            }
            SheetCloseButton(
                action: { dismiss() },
                frameSize: 28
            )
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if !catalog.isLoaded(for: resolvedTarget) {
            ProgressView("settings.translation.system.readiness.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sortedLanguages.isEmpty {
            ContentUnavailableView(
                "settings.translation.system.empty",
                systemImage: "character.bubble"
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(sortedLanguages, id: \.minimalIdentifier) { language in
                if let status = catalog.status(for: language) {
                    SystemTranslationLanguageRow(
                        name: displayName(for: language),
                        identifier: language.minimalIdentifier,
                        status: status,
                        isPreparing: pendingSourceIdentifier == language.minimalIdentifier,
                        downloadDisabled: pendingSourceIdentifier != nil || catalog.isRefreshing,
                        onDownload: { requestDownload(for: language) }
                    )
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let downloadErrorMessage {
                Label {
                    Text(verbatim: downloadErrorMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.red)
            }

            HStack(alignment: .center, spacing: 12) {
                Text("settings.translation.system.sheet.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(action: openSystemSettings) {
                    Text("settings.translation.system.openSettings")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
            }
        }
        .padding(20)
    }

    private var resolvedTarget: ReadmeTranslationLanguage {
        targetLanguage.resolved()
    }

    private var sortedLanguages: [Locale.Language] {
        guard catalog.isLoaded(for: resolvedTarget) else { return [] }
        return catalog.languages.sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    private func displayName(for language: Locale.Language) -> String {
        locale.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    private func requestDownload(for language: Locale.Language) {
        let sourceIdentifier = language.minimalIdentifier
        pendingSourceIdentifier = sourceIdentifier
        downloadErrorMessage = nil

        let nextConfiguration = TranslationSession.Configuration(
            source: language,
            target: resolvedTarget.localeLanguage
        )
        if downloadConfiguration == nextConfiguration {
            // 同一个语言上次取消后再次点击时，必须递增 configuration version，
            // 否则 SwiftUI 会把相同值视为没有变化，不会重新提供 Session。
            downloadConfiguration?.invalidate()
        } else {
            downloadConfiguration = nextConfiguration
        }
    }

    private func prepareLanguage(using session: TranslationSession) async {
        guard let sourceIdentifier = pendingSourceIdentifier else { return }

        do {
            try await session.prepareTranslation()
        } catch is CancellationError {
            // Sheet 关闭或任务替换属于正常取消，不显示错误。
        } catch {
            downloadErrorMessage = String.l10n("settings.translation.system.downloadFailed")
            AppLog.ai.error(
                "System translation language preparation failed (source=\(sourceIdentifier, privacy: .public), target=\(resolvedTarget.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }

        // 系统弹窗被关闭后下载仍可能继续；先刷新一次，并保留顶栏刷新供用户稍后复查。
        await catalog.refresh(target: resolvedTarget, force: true)
        if pendingSourceIdentifier == sourceIdentifier {
            pendingSourceIdentifier = nil
        }
    }
}
