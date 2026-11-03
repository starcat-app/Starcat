//
//  AgentRuntimeSettingsChrome.swift
//  Starcat
//
//  Agent Runtime 设置页与 CodeFlow 集成段对齐的轻量视觉零件。
//
//  为什么单独抽这一层：
//  - 旧版把每个 Runtime 塞进 GroupBox，再叠 LabeledContent / 长状态句 / 一排文字按钮，
//    设置页会出现「卡片套卡片」和长路径折行，扫一眼找不到操作入口。
//  - CodeFlow 段已经验证过更疏的口径：说明一行、提示条、路径与按钮同一行。
//    这里复用同一套路径行和提示条，避免 Codex / DeepSeek 各自再发明一版密度。
//

import AppKit
import SwiftUI

/// 单一配置指南入口：说明在左，独立操作靠右，不额外嵌套背景卡片。
struct AgentRuntimeGuideNotice: View {
    let destination: URL

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("settings.integration.agentRuntime.guide.notice")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("settings.integration.agentRuntime.openGuide.action") {
                openURL(destination)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize()
        }
    }
}

/// CodeFlow 同款路径行：路径在左截断，操作按钮固定在右，避免长路径把按钮挤换行。
///
/// 关键约束：macOS 上 `.textSelection(.enabled)` 会按完整路径报告固有宽度，
/// 点选后 `Text` 画出截断槽、盖住「选择 / Finder」。所以路径必须 `minWidth: 0`
/// 才能被 HStack 压到剩余宽度，再 `.clipped()` 把选中态限制在自己的槽里；
/// 按钮侧提高 `layoutPriority`，不被路径挤没。
struct AgentRuntimePathRow<Actions: View>: View {
    var caption: LocalizedStringKey?
    let path: String
    let actions: Actions

    init(
        caption: LocalizedStringKey? = nil,
        path: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.caption = caption
        self.path = path
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(verbatim: displayedPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .layoutPriority(-1)

                actions
                    .layoutPriority(1)
            }
        }
    }

    private var displayedPath: String {
        path.isEmpty ? String.l10n("settings.integration.agentRuntime.notConfigured") : path
    }
}

/// 路径操作统一为「选择 → Finder → 可选重置」，与保存目录行保持相同顺序。
struct AgentRuntimePathTrailingActions<Reset: View>: View {
    let path: String
    var isDisabled: Bool = false
    let onChoose: () -> Void
    let reset: Reset

    init(
        path: String,
        isDisabled: Bool = false,
        onChoose: @escaping () -> Void,
        @ViewBuilder reset: () -> Reset
    ) {
        self.path = path
        self.isDisabled = isDisabled
        self.onChoose = onChoose
        self.reset = reset()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button("settings.integration.agentRuntime.openPanel.prompt", action: onChoose)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
                .disabled(isDisabled)

            RevealInFinderIconButton(help: Text("settings.integration.codeFlow.outputDir.revealHelp")) {
                AgentRuntimePathReveal.reveal(path)
            }
            .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if Reset.self != EmptyView.self {
                reset
            }
        }
    }
}

extension AgentRuntimePathTrailingActions where Reset == EmptyView {
    init(
        path: String,
        isDisabled: Bool = false,
        onChoose: @escaping () -> Void
    ) {
        self.init(path: path, isDisabled: isDisabled, onChoose: onChoose) {
            EmptyView()
        }
    }
}

/// 折叠后标题仍需读到真实状态；失败摘要保留在展开内容，标题不用单独图标替代文字。
struct AgentRuntimeStatusChip: View {
    let status: AgentRuntimeSettingsStatus

    var body: some View {
        switch status {
        case .idle:
            Text("settings.integration.agentRuntime.notConfigured")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            Text("settings.integration.agentRuntime.detecting")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            Label {
                Text("settings.integration.agentRuntime.status.ready")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
        case .failed:
            Label("settings.integration.tools.runtime.unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

enum AgentRuntimeInfoKind: Sendable {
    case codex
    case deepSeek

    var title: String {
        switch self {
        case .codex: "Codex App Server"
        case .deepSeek: "DeepSeek Harness"
        }
    }

    var summaryKey: LocalizedStringKey {
        switch self {
        case .codex: "settings.integration.agentRuntime.codex.info.summary"
        case .deepSeek: "settings.integration.agentRuntime.deepSeek.info.summary"
        }
    }

    var components: [String] {
        switch self {
        case .codex:
            ["codex-app-server (or codex)", "codex-code-mode-host"]
        case .deepSeek:
            [
                "dsh-jsonrpc-agent-pkg-macos-arm64",
                "dsh-jsonrpc-agent-pkg-macos-arm64-rg",
                "dsh-jsonrpc-agent-pkg-macos-arm64-spawn-helper",
                "starcat.cordis.yml",
            ]
        }
    }

    var noteKey: LocalizedStringKey {
        switch self {
        case .codex: "settings.integration.agentRuntime.codex.info.note"
        case .deepSeek: "settings.integration.agentRuntime.deepSeek.info.note.modelsSettings"
        }
    }
}

/// Runtime 标题旁的轻量帮助入口。Popover 只解释本地文件契约，不读取认证信息。
struct AgentRuntimeInfoButton: View {
    let kind: AgentRuntimeInfoKind

    @State private var isPresented = false

    var body: some View {
        SettingsActionIconButton(
            title: "settings.integration.agentRuntime.info.button",
            systemImage: "info.circle"
        ) {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentRuntimeInfoPopover(kind: kind)
                .appLocaleEnvironment()
        }
    }
}

private struct AgentRuntimeInfoPopover: View {
    let kind: AgentRuntimeInfoKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(verbatim: kind.title)
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }

            Text(kind.summaryKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("settings.integration.agentRuntime.info.requiredComponents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                ForEach(kind.components, id: \.self) { component in
                    Label {
                        Text(verbatim: component)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(kind.noteKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

extension AgentRuntimeSettingsStatus {
    /// 检测失败时才展示完整错误。选择文件或恢复自动检测后会立刻再跑一次校验，
    /// 不再单独放刷新按钮。
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// 在 Finder 中打开路径所在目录：文件会选中该文件，目录则直接打开。
enum AgentRuntimePathReveal {
    static func reveal(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }

        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { return }
        NSWorkspace.shared.open(parent)
    }
}
