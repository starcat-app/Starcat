//
//  RepoContextSettingsSection.swift
//  Starcat
//
//  代码上下文的生成参数与产物管理；复用原配置和存储，关闭生成不影响已有内容管理。
//

import AppKit
import SwiftUI

/// 下载上限由页首共享分组承载，本分组只管理上下文生成参数和已有产物。
struct RepoContextSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var aiContextStorage = RepoContextStorage.shared
    @State private var aiContextActionError: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                repoContextEnableRow.padding(.vertical, 8)
                Divider()
                repoContextTokenBudgetRow.padding(.vertical, 8)
                Divider()
                repoContextTier1MaxLinesRow.padding(.vertical, 8)
                Divider()
                repoContextManageStorageRow.padding(.vertical, 8)
            }
        } header: {
            SettingsSectionHeader("ai.context.settings.title", businessIcon: .codeContext)
        }
        .task { aiContextStorage.reload() }
        .alert(
            "ai.context.storage.actionFailed",
            isPresented: Binding(
                get: { aiContextActionError != nil },
                set: { if !$0 { aiContextActionError = nil } }
            )
        ) {
            Button("general.ok") { aiContextActionError = nil }
        } message: {
            Text(aiContextActionError ?? "")
        }
    }

    private var repoContextEnableRow: some View {
        Toggle(isOn: repoContextEnabledBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ai.context.settings.enabled")
                Text("settings.integration.tools.context.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    /// 保留原 Slider 范围与步进，右侧只显示数字，单位在说明中出现一次。
    private var repoContextTokenBudgetRow: some View {
        SettingsSliderRow(
            title: "settings.integration.tools.context.length", value: tokenBudgetBinding,
            range: 4000...32000, step: 2000,
            readout: settings.aiRepoContextTokenBudget.formatted(.number),
            description: "settings.integration.tools.context.lengthHelp"
        )
        .disabled(!settings.aiRepoContextEnabled)
    }

    private var repoContextTier1MaxLinesRow: some View {
        @Bindable var settings = settings
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ai.context.settings.tier1MaxLines")
                Text("settings.integration.tools.context.linesHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            LocalToolIntegerField(
                title: "ai.context.settings.tier1MaxLines",
                value: $settings.aiRepoContextTier1MaxLines,
                range: 40...200
            )
        }
        .disabled(!settings.aiRepoContextEnabled)
    }

    /// 目录切换仍调用原存储迁移接口；不随生成开关禁用，便于管理已有产物。
    private var repoContextManageStorageRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalToolOutputDirectoryRow(
                path: aiContextStorage.outputDirectoryDisplayPath,
                hasCustomDirectory: aiContextStorage.hasCustomOutputDirectory,
                onChoose: chooseAIContextOutputDirectory,
                onReveal: revealAIContextOutputDirectory,
                onReset: resetAIContextOutputDirectory
            )
            Divider()
            LocalToolStorageSummary(
                projectCount: aiContextStorage.projectCount,
                totalBytes: aiContextStorage.totalBytes,
                generationCount: aiContextStorage.totalGenerationCount,
                latestGeneratedAt: aiContextStorage.latestGeneratedAt
            )
            if let message = aiContextStorage.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if aiContextStorage.projectCount == 0 {
                Text("ai.context.storage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - AI 代码上下文 storage action 入口

    /// 选择新的产物输出目录（NSOpenPanel）。失败走 aiContextActionError alert。
    private func chooseAIContextOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("ai.context.storage.choosePanelTitle")
        panel.prompt = String.l10n("ai.context.storage.choosePanelPrompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try aiContextStorage.setCustomOutputDirectory(url)
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func resetAIContextOutputDirectory() {
        do {
            try aiContextStorage.resetOutputDirectory()
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func revealAIContextOutputDirectory() {
        do {
            try aiContextStorage.revealOutputRoot()
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    // HOM-203：单项 reveal / delete 已经移除——repo 列表整体砍掉，"全部清除"
    // 在 设置 → 存储 Tab 已有入口，不再需要单项操作。`storage.revealProject`
    // 和 `storage.deleteProject` API 仍保留供未来使用 / 单测。

    /// Token 预算 Int↔Double 适配 binding。
    /// SwiftUI Slider 要求 `BinaryFloatingPoint` 值类型，但 `aiRepoContextTokenBudget` 是 Int
    /// （UserDefaults 直接 Int 持久化更直观，避免出现 `8000.0`）。这里在两端之间做转换：
    ///   - get：Int → Double（无损扩展）
    ///   - set：Double → Int（`rounded()` 保证步进对齐到整 2000）
    private var tokenBudgetBinding: Binding<Double> {
        Binding(
            get: { Double(self.settings.aiRepoContextTokenBudget) },
            set: { newValue in
                self.settings.aiRepoContextTokenBudget = Int(newValue.rounded())
            }
        )
    }

    /// 总开关沿用原配置绑定，迁移页面不改变持久化字段和开关行为。
    private var repoContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.aiRepoContextEnabled },
            set: { self.settings.aiRepoContextEnabled = $0 }
        )
    }

}
