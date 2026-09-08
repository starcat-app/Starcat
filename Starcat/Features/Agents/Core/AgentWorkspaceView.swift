//
//  AgentWorkspaceView.swift
//  Starcat
//
//  Agent 独立 Workspace Window 的三栏内容视图。
//
//  本视图是所有内置 Agent 的唯一工作台壳子。三栏结构对齐 RAG 工作台：原生
//  Sidebar / Run Surface / Inspector 组合，左右栏可拖拽并跨窗口重开恢复。
//  Agent 只提供定义与运行事实，页面结构保持统一，避免 Weekly / Repo Insight 等
//  能力各自长出一套不可复用的 UI。
//

import AppKit
import SwiftUI

/// Agent 工作台三栏尺寸约束与持久化键。
///
/// 与 RAG 工作台共用同一套原生 Sidebar / Inspector 口径：左右栏可拖拽，中栏保留稳定阅读空间。
/// 持久化值读取时必须钳制，避免旧 defaults 或手工改键后恢复出挤掉 Run Surface 的布局。
enum AgentWorkspaceLayoutMetrics {
    static let leftMinimumWidth: CGFloat = 250
    static let leftIdealWidth: CGFloat = 312
    static let leftMaximumWidth: CGFloat = 380

    // 这是窗口级宽度预算，不直接作为 Run Surface 的 frame 下限。NavigationSplitView
    // 与 Inspector 会分别协商列宽；把 480pt 再挂到中栏会在最小窗口拖拽时形成冲突，
    // 让系统通过裁切边缘列满足所有局部约束。
    static let runMinimumWidth: CGFloat = 480

    static let rightMinimumWidth: CGFloat = 320
    // 首次打开保持紧凑；用户拖拽后的真实宽度由 Inspector 栏内测量写回并优先恢复。
    static let rightDefaultWidth = rightMinimumWidth
    static let rightMaximumWidth: CGFloat = 520

    // Window Scene 与旧 AppKit 窗口的布局时序不同，左栏不能复用迁移前的宽度记录。
    static let leftWidthDefaultsKey = "AgentWorkspace.SceneV2.LeftColumnWidth"
    // v2 的 HSplitView 测量没有稳定落盘；v3 由原生 Inspector 在栏内直接写回真实宽度。
    static let rightWidthDefaultsKey = "AgentWorkspace.SceneV3.RightColumnWidth"

    static func clampedLeftWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), leftMinimumWidth), leftMaximumWidth)
    }

    static func clampedRightWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), rightMinimumWidth), rightMaximumWidth)
    }
}

struct AgentWorkspaceView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @AppStorage(AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey)
    private var persistedLeftColumnWidth = Double(AgentWorkspaceLayoutMetrics.leftIdealWidth)
    @AppStorage(AgentWorkspaceLayoutMetrics.rightWidthDefaultsKey)
    private var persistedRightColumnWidth = Double(AgentWorkspaceLayoutMetrics.rightDefaultWidth)
    @State private var viewModel = AgentWorkspaceViewModel()
    @State private var isHistoryExpanded = false
    /// 栏宽测量属于持久化缓存而不是渲染状态；引用对象内部变化不能让整棵工作台重新求值。
    @State private var columnWidthPersistence = AgentWorkspaceColumnWidthPersistence()
    @Bindable var chromeState: WorkspaceChromeState

    private var restoredLeftColumnWidth: CGFloat {
        AgentWorkspaceLayoutMetrics.clampedLeftWidth(persistedLeftColumnWidth)
    }

    private var restoredRightColumnWidth: CGFloat {
        AgentWorkspaceLayoutMetrics.clampedRightWidth(persistedRightColumnWidth)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $chromeState.leftColumnVisibility) {
            agentRail
                .navigationSplitViewColumnWidth(
                    min: AgentWorkspaceLayoutMetrics.leftMinimumWidth,
                    ideal: restoredLeftColumnWidth,
                    max: AgentWorkspaceLayoutMetrics.leftMaximumWidth
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                scheduleLeftWidthPersistence(width)
                            }
                    }
                }
                // NavigationSplitView 的 Sidebar 是独立 preference 边界，尺寸不能再向
                // 根视图上传；在列内直接监听 GeometryReader，才能可靠写回 @AppStorage。
        } detail: {
            GeometryReader { proxy in
                AgentWorkspaceRunSurface(viewModel: viewModel)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            // 中栏只填充 NavigationSplitView 已分配的尺寸，不把内容固有宽度带回三栏协商；
            // 否则在最小窗口拖动 Inspector 时，SwiftUI 会反复重算布局并导致主线程卡死。
        }
        // 任务检查器是语义明确的 trailing inspector。使用系统 Inspector 后，宽度
        // 约束直接进入分栏控制器，不再依赖 HSplitView 对普通 idealWidth 的布局猜测。
        .inspector(isPresented: $chromeState.isRightColumnPresented) {
            artifactInspector
                .inspectorColumnWidth(
                    min: AgentWorkspaceLayoutMetrics.rightMinimumWidth,
                    ideal: restoredRightColumnWidth,
                    max: AgentWorkspaceLayoutMetrics.rightMaximumWidth
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                scheduleRightWidthPersistence(width)
                            }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
        .animation(.easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
        .onDisappear {
            // 用户可能拖完立即关闭窗口；同步提交最后测量值，不能依赖 debounce 任务来得及执行。
            columnWidthPersistence.persistLastMeasuredWidths(
                leftWidth: $persistedLeftColumnWidth,
                rightWidth: $persistedRightColumnWidth
            )
            columnWidthPersistence.cancelPendingPersistence()
        }
    }

    private var availableAgentDefinitions: [AgentDefinition] {
        guard dependencies.distributionGate.isAvailable(.externalAgentRuntime) else {
            return BuiltInAgents.all
        }
        return ExternalAgentDefinitions.all + BuiltInAgents.all
    }

    // MARK: - Agent Rail

    private var agentRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(AgentWorkspaceTaxonomy.sections) { section in
                        let agents = AgentWorkspaceTaxonomy.agents(in: section, from: viewModel.agents)
                        if !agents.isEmpty {
                            agentSection(section.titleKey, agents: agents)
                        }
                    }
                    historySection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 工作台胶囊标识（Beta / Preview 等），与左侧 Agent 列表行内 Preview 标识同构。
    private func agentWorkspaceBadge(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(agentFont(.caption2, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .aiCommandAuxiliarySurface(cornerRadius: 6)
    }

    private var railHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(agentIconFont(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("agent.workspace.title")
                            .font(agentFont(.headline))
                        agentWorkspaceBadge("agent.workspace.badge.beta")
                    }
                    Text("agent.workspace.subtitle")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

        }
        .padding(14)
    }

    private func agentSection(_ titleKey: String, agents: [AgentDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(titleKey))
                .font(agentFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            ForEach(agents) { agent in
                agentButton(agent)
            }
        }
    }

    private func agentButton(_ agent: AgentDefinition) -> some View {
        Button {
            viewModel.selectAgent(agent)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: agent.systemImage)
                    .font(agentIconFont(size: 17, weight: .regular))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(agent.id == viewModel.selectedAgentID ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(agent.title)
                            .font(agentFont(.subheadline, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if !agent.isEnabled {
                            agentWorkspaceBadge("agent.workspace.badge.preview")
                        }
                    }

                    Text(agent.subtitle)
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        ForEach(agent.capabilityLabels.prefix(3), id: \.self) { label in
                            Text(label)
                                .font(agentFont(.caption2))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .separatorColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(agent.id == viewModel.selectedAgentID ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(agent.id == viewModel.selectedAgentID ? Color.accentColor.opacity(0.24) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!agent.isEnabled || viewModel.isRunning)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("agent.workspace.history.title")
                .font(agentFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            if viewModel.historyRuns.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text("agent.workspace.history.empty")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(11)
                .background(Color(nsColor: .separatorColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(AgentHistoryPresentation.visibleRuns(
                    viewModel.historyRuns,
                    isExpanded: isHistoryExpanded
                )) { run in
                    historyRunButton(run)
                }

                if viewModel.historyRuns.count > AgentHistoryPresentation.collapsedLimit {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isHistoryExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isHistoryExpanded ? "chevron.up" : "ellipsis.circle")
                                .frame(width: 18)
                            Text(historyDisclosureTitle)
                                .font(agentFont(.caption, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
    }

    private var historyDisclosureTitle: String {
        if isHistoryExpanded {
            return String.l10n("agent.workspace.history.collapse")
        }
        let remainingCount = viewModel.historyRuns.count - AgentHistoryPresentation.collapsedLimit
        return String(
            format: String.l10n("agent.workspace.history.moreFormat"),
            locale: locale,
            remainingCount
        )
    }

    private func historyRunButton(_ run: AgentRunRecord) -> some View {
        let isSelected = viewModel.selectedHistoryRunID == run.id
        return Button {
            Task {
                await viewModel.openHistoryRun(run)
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: historyIcon(for: run.status))
                    .foregroundStyle(historyTint(for: run.status))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.title)
                        .font(agentFont(.caption, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(historySubtitle(run))
                        .font(agentFont(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .separatorColor).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(viewModel.isRunning)
    }

    private func historySubtitle(_ run: AgentRunRecord) -> String {
        "\(historyStatusLabel(for: run.status)) · \(historyTimeLabel(for: run.createdAt))"
    }

    private func historyStatusLabel(for status: String) -> String {
        switch AgentRunStatus(rawValue: status) {
        case .completed:
            return String.l10n("agent.workspace.status.completed")
        case .failed:
            return String.l10n("agent.workspace.status.failed")
        case .cancelled:
            return String.l10n("agent.workspace.status.cancelled")
        case .planning:
            return String.l10n("agent.workspace.status.planning")
        case .running:
            return String.l10n("agent.workspace.status.running")
        case .waitingForConfirmation:
            return String.l10n("agent.workspace.status.waitingForConfirmation")
        case .idle, .none:
            return String.l10n("agent.workspace.status.idle")
        }
    }

    private func historyTimeLabel(for raw: String) -> String {
        guard let date = ISO8601DateFormatter.shared.date(from: raw) else {
            return raw
        }
        return RelativeTimeText.pastEvent(date, locale: locale)
    }

    private func historyIcon(for status: String) -> String {
        switch AgentRunStatus(rawValue: status) {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "pause.circle.fill"
        case .planning, .running, .waitingForConfirmation:
            return "circle.dotted"
        case .idle, .none:
            return "clock"
        }
    }

    private func historyTint(for status: String) -> Color {
        switch AgentRunStatus(rawValue: status) {
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        case .planning, .running, .waitingForConfirmation:
            return .accentColor
        case .idle, .none:
            return .secondary
        }
    }

    // MARK: - Artifact Inspector

    private var artifactInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentRunInspectorHeader(viewModel: viewModel)
            Divider()
            AgentRunInspectorView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 右栏不参与窗口内容向 Toolbar 的背景贯穿；否则 Inspector 的底色会越过
        // Toolbar 下边界顶到窗口顶部。左栏和中栏仍保留现有贯穿行为。
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.26),
            ignoresSafeAreaEdges: []
        )
    }

    // MARK: - Helpers

    private enum AgentFontRole {
        case title2
        case headline
        case subheadline
        case body
        case callout
        case caption
        case caption2

        /// Maps local workspace roles onto the shared `DESIGN.md` typography tokens.
        var typography: StarcatTypography {
            switch self {
            case .title2:          return .workspaceTitle
            case .headline:        return .panelTitle
            case .subheadline:     return .rowTitle
            case .body:            return .body
            case .callout:         return .bodyEmphasis
            case .caption:         return .caption
            case .caption2:        return .captionSmall
            }
        }
    }

    private func agentFont(
        _ role: AgentFontRole,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func agentIconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }

    /// 将连续 GeometryReader 测量交给非 Observable 缓存，避免测量值反向使根视图失效。
    private func scheduleLeftWidthPersistence(_ measuredWidth: CGFloat) {
        columnWidthPersistence.scheduleLeftWidthPersistence(
            measuredWidth,
            isCollapsed: chromeState.isLeftColumnCollapsed,
            persistedWidth: $persistedLeftColumnWidth
        )
    }

    private func scheduleRightWidthPersistence(_ measuredWidth: CGFloat) {
        columnWidthPersistence.scheduleRightWidthPersistence(
            measuredWidth,
            isCollapsed: chromeState.isRightColumnCollapsed,
            persistedWidth: $persistedRightColumnWidth
        )
    }

}
