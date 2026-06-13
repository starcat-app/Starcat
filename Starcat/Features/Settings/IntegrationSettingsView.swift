//
//  IntegrationSettingsView.swift
//  Starcat
//
//  设置页 → 集成 Tab：管理 CodeFlow 等直接嵌入 Starcat 的第三方工具。
//  自建后端 URL/API Key 仍归「服务」Tab，避免两类配置混在同一页面。
//

import AppKit
import SwiftUI

struct IntegrationSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    /// CodeFlow 生成物不进数据库，设置页直接观察文件系统扫描结果。
    @State private var storage = CodeFlowStorage.shared
    @State private var showsClearConfirmation = false
    @State private var actionError: String?
    @State private var anySearchAPIKey: String = ""
    @State private var showAnySearchAPIKey: Bool = false

    var body: some View {
        Form {
            anySearchSection
            Section("CodeFlow") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("代码图谱输出目录", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Text("切换目录时会迁移现有 CodeFlow HTML 与 metadata；共享源码 ZIP 仍保存在应用容器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(storage.outputDirectoryDisplayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("选择目录") { chooseOutputDirectory() }
                    Button {
                        revealOutputDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("在 Finder 中显示")
                    Button {
                        resetOutputDirectory()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(!storage.hasCustomOutputDirectory)
                    .help("迁移到 App Container 默认目录")
                }

                HStack(spacing: 18) {
                    stat(title: "项目", value: "\(storage.projects.count)")
                    stat(title: "占用", value: ByteCountFormatter.string(fromByteCount: storage.totalBytes, countStyle: .file))
                    stat(title: "累计生成", value: "\(storage.totalGenerationCount) 次")
                    if let date = storage.latestGeneratedAt {
                        stat(title: "最后生成", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Spacer()
                }

                if let message = storage.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if storage.projects.isEmpty {
                    Text("当前目录还没有 CodeFlow 生成项目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(storage.projects) { project in
                        projectRow(project)
                    }

                    HStack {
                        Spacer()
                        Button("一键清除", role: .destructive) {
                            showsClearConfirmation = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { storage.reload() }
        .task { anySearchAPIKey = settings.anySearchAPIKey() ?? "" }
        .alert("清除全部 CodeFlow 数据？", isPresented: $showsClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) { clearAllProjects() }
        } message: {
            Text("将删除当前输出目录中的全部 CodeFlow HTML 与 metadata。共享源码 ZIP 不会被删除。")
        }
        .alert("CodeFlow 操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好") { actionError = nil }
        } message: {
            Text(actionError ?? "未知错误")
        }
    }

    private var anySearchSection: some View {
        @Bindable var settings = settings
        return Section("AnySearch") {
            Toggle("启用 AnySearch 网页搜索", isOn: $settings.anySearchEnabled)
            Toggle("匿名模式（不发送 API Key）", isOn: $settings.anySearchAnonymousMode)
                .disabled(!settings.anySearchEnabled)

            HStack {
                Group {
                    if showAnySearchAPIKey {
                        TextField("API Key", text: $anySearchAPIKey)
                    } else {
                        SecureField("API Key", text: $anySearchAPIKey)
                    }
                }
                Button {
                    showAnySearchAPIKey.toggle()
                } label: {
                    Image(systemName: showAnySearchAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                Button("保存") { settings.setAnySearchAPIKey(anySearchAPIKey) }
            }
            .disabled(!settings.anySearchEnabled || settings.anySearchAnonymousMode)

            Toggle("在“全部”范围中包含网页结果", isOn: $settings.searchIncludeWebInAll)
                .disabled(!settings.anySearchEnabled)
            Toggle("AI 摘要使用外部网页上下文", isOn: $settings.aiExternalContextEnabled)
                .disabled(!settings.anySearchEnabled)
            Toggle("允许私有仓库使用外部上下文", isOn: $settings.aiExternalContextAllowPrivateRepos)
                .disabled(!settings.aiExternalContextEnabled)

            Text("默认禁止把私有仓库名称、README 或笔记发送到外部搜索。匿名模式不会发送已保存的 API Key；配置了无效 Key 时不会自动降级为匿名请求。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption.weight(.medium))
        }
    }

    private func projectRow(_ project: CodeFlowStoredProject) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.metadata.repository.fullName)
                        .font(.callout.weight(.medium))
                    Text("\(project.metadata.sourceRevision.branch) · \(project.metadata.sourceRevision.shortSHA) · HTML \(ByteCountFormatter.string(fromByteCount: project.metadata.artifact.pageBytes, countStyle: .file)) · ZIP \(ByteCountFormatter.string(fromByteCount: project.metadata.artifact.sourceArchiveBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(project.metadata.generation.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                // 语义约定：预览 = 浏览器查看图谱；打开 = Finder 定位生成文件。
                Button("预览") { preview(project) }
                Button("打开") { reveal(project) }
                Button("删除", role: .destructive) { delete(project) }
            }

            DisclosureGroup("详情") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("页面路径"); Text(project.pageURL.path).textSelection(.enabled) }
                    GridRow { Text("生成次数"); Text("\(project.metadata.generation.generationCount)") }
                    GridRow { Text("最近耗时"); Text("\(project.metadata.generation.lastDurationMilliseconds) ms") }
                    GridRow { Text("CodeFlow 版本"); Text(String(project.metadata.generator.codeFlowCommit.prefix(7))).monospaced() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 CodeFlow 输出目录"
        panel.prompt = "选择并迁移"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try storage.setCustomOutputDirectory(url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resetOutputDirectory() {
        do {
            try storage.resetOutputDirectory()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func revealOutputDirectory() {
        do {
            try storage.revealOutputRoot()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func preview(_ project: CodeFlowStoredProject) {
        do {
            guard try storage.openPage(project.pageURL) else {
                throw CocoaError(.fileNoSuchFile)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func reveal(_ project: CodeFlowStoredProject) {
        do {
            try storage.revealPage(project.pageURL)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func delete(_ project: CodeFlowStoredProject) {
        do {
            try storage.deleteProject(
                owner: project.metadata.repository.owner,
                name: project.metadata.repository.name
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func clearAllProjects() {
        do {
            try storage.deleteAllProjects()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

#Preview {
    IntegrationSettingsTab()
        .frame(width: 560, height: 500)
}
