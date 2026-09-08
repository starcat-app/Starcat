//
//  AIModelListView.swift
//  Starcat
//
//  AI 设置页模型列表组件。
//
//  模块职责：
//  - 展示单个 provider profile 通过 `/models` 发现的模型；
//  - 支持在本组件内部搜索、启用 / 禁用模型、修正 Chat / Embedding 能力；
//  - 限制模型列表高度，避免 LM Studio / OpenRouter 返回大量模型时把整个 Settings 页面无限拉长。
//
//  关键约束：
//  - 模型能力不是所有 OpenAI-compatible 服务都会返回统一字段，因此能力 Picker 是用户可修正项。
//  - 组件只负责展示和绑定，不直接修改 AppSettings；实际写入由父视图提供 Binding，便于测试和复用。
//  - 滚动：用固定高度 AppKit 宿主包 SwiftUI `ScrollView + LazyVStack`。Form 只看到固定高度 NSView，
//    不会对模型行跑 measureEstimates（避免 hang）；宿主吃掉纵向滚轮，避免整页跟着滚。
//  - 分页：内存里已有全量目录，但 UI 按页挂载（`automaticListPagination`），展开时不一次构建数百行。
//

import AppKit
import SwiftUI

/// Provider 模型列表的受限高度展示组件。
struct AIModelListView: View {

    /// 每页挂载行数。视口只有约 4 行，40 足够滚动预取，又远小于 OpenRouter 级全量。
    private static let pageSize = 40

    let profile: AIProviderProfile
    let enabledBinding: (AIModelDescriptor) -> Binding<Bool>
    let capabilityBinding: (AIModelDescriptor) -> Binding<AIModelCapability>
    /// HOM-68 follow-up v9：父视图提供"读取并写回 descriptor.parameters"的 nullable binding。
    /// nil 表示该模型没有用户级覆盖，使用 capability 默认。
    let parametersBinding: (AIModelDescriptor) -> Binding<AIModelParameters?>

    @State private var query = ""
    /// 当前已挂载到列表的前缀长度（对 `filteredModels` 切片）。
    @State private var loadedCount = AIModelListView.pageSize
    /// 当前正在编辑参数的模型；nil 表示无 popover 显示。
    @State private var popoverModel: AIModelDescriptor?

    private var filteredModels: [AIModelDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return profile.models }
        return profile.models.filter { model in
            model.name.localizedCaseInsensitiveContains(trimmed)
                || (model.ownedBy?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || model.capability.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var displayedModels: [AIModelDescriptor] {
        Array(filteredModels.prefix(max(loadedCount, 0)))
    }

    private var hasMoreModels: Bool {
        loadedCount < filteredModels.count
    }

    /// 筛选 / provider / 目录规模变化时重置分页身份。
    private var paginationIdentity: String {
        "\(profile.id)#\(query)#\(profile.models.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.vertical, 8)
            Divider()
            searchField
                .padding(.vertical, 8)
            Divider()
            modelScroll
                .padding(.top, 8)
        }
        .padding(.top, 4)
        .onAppear {
            syncLoadedCountToFilter()
        }
        .onChange(of: paginationIdentity) { _, _ in
            syncLoadedCountToFilter()
        }
    }

    private var header: some View {
        HStack {
            // HOM-203：避免 `Text("key \(count)")` 被编译成空壳 `%@` entry，运行时回退成 key 字面量。
            Text(String(
                format: String.l10n("settings.ai.modelList.totalFormat"),
                profile.models.count
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(String(
                    format: String.l10n("settings.ai.modelList.matchedFormat"),
                    filteredModels.count
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var searchField: some View {
        TextField("settings.ai.modelList.searchPlaceholder", text: $query)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
    }

    private var modelScroll: some View {
        AIModelFixedHeightHost(height: modelScrollHeight) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if displayedModels.isEmpty {
                        Text("settings.ai.modelList.empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        ForEach(Array(displayedModels.enumerated()), id: \.element.id) { index, model in
                            AIModelListRow(
                                model: model,
                                isEnabled: enabledBinding(model),
                                capability: capabilityBinding(model),
                                isCustomized: modelHasCustomizedParameters(model),
                                popoverItem: popoverBinding(model: model),
                                parameters: nonNullParametersBinding(for: model),
                                onResetParameters: {
                                    parametersBinding(model).wrappedValue = nil
                                },
                                onOpenParameters: {
                                    popoverModel = model
                                }
                            )
                            .automaticListPagination(
                                appearingIndex: index,
                                visibleItemCount: displayedModels.count,
                                loadedItemCount: loadedCount,
                                hasMore: hasMoreModels,
                                isLoading: false,
                                identity: paginationIdentity
                            ) {
                                loadMoreModels()
                            }

                            if index < displayedModels.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .automaticListPaginationFill(
                    visibleItemCount: displayedModels.count,
                    loadedItemCount: loadedCount,
                    hasMore: hasMoreModels,
                    isLoading: false,
                    identity: paginationIdentity
                ) {
                    loadMoreModels()
                }
            }
            .scrollIndicators(.automatic)
        }
        .frame(height: modelScrollHeight)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// HOM-126 follow-up：行数 ≤ 4 时贴合内容；超过 4 时锁定高度并内部滚动。
    private var modelScrollHeight: CGFloat {
        let visibleRows = filteredModels.isEmpty ? 1 : min(filteredModels.count, 4)
        let perRowHeight: CGFloat = 44
        let dividerHeight: CGFloat = 1
        return CGFloat(visibleRows) * perRowHeight + CGFloat(max(0, visibleRows - 1)) * dividerHeight
    }

    private func syncLoadedCountToFilter() {
        loadedCount = min(Self.pageSize, filteredModels.count)
    }

    private func loadMoreModels() {
        guard hasMoreModels else { return }
        loadedCount = min(loadedCount + Self.pageSize, filteredModels.count)
    }

    private func modelHasCustomizedParameters(_ model: AIModelDescriptor) -> Bool {
        guard let parameters = parametersBinding(model).wrappedValue else { return false }
        return !parameters.isEffectivelyDefault(for: model.capability)
    }

    private func popoverBinding(model: AIModelDescriptor) -> Binding<AIModelDescriptor?> {
        Binding(
            get: { popoverModel?.id == model.id ? popoverModel : nil },
            set: { newValue in
                popoverModel = newValue
            }
        )
    }

    private func nonNullParametersBinding(for model: AIModelDescriptor) -> Binding<AIModelParameters> {
        let nullable = parametersBinding(model)
        return Binding(
            get: { nullable.wrappedValue ?? AIModelParameters.defaults(for: model.capability) },
            set: { newValue in
                if newValue.isEffectivelyDefault(for: model.capability) {
                    if nullable.wrappedValue != nil {
                        nullable.wrappedValue = nil
                    }
                    return
                }
                if let current = nullable.wrappedValue, current.isEffectivelyEqual(to: newValue) {
                    return
                }
                nullable.wrappedValue = newValue
            }
        )
    }
}

/// Form 内固定高度宿主：只暴露固定 intrinsic height，内部交给 SwiftUI ScrollView 懒加载。
///
/// 查：`docs/7-工具与脚本/Swift-学习索引.md` → `NSViewRepresentable`。
private struct AIModelFixedHeightHost<Content: View>: NSViewRepresentable {
    var height: CGFloat
    var content: Content

    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AIModelFixedHeightView {
        let container = AIModelFixedHeightView()
        container.fixedHeight = height
        context.coordinator.attach(content, to: container)
        return container
    }

    func updateNSView(_ container: AIModelFixedHeightView, context: Context) {
        container.fixedHeight = height
        context.coordinator.attach(content, to: container)
    }

    @MainActor
    final class Coordinator {
        private var host: NSHostingView<AnyView>?

        func attach(_ view: Content, to container: AIModelFixedHeightView) {
            let root = AnyView(view)
            if let host {
                host.rootView = root
                return
            }
            let created = NSHostingView(rootView: root)
            created.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(created)
            NSLayoutConstraint.activate([
                created.topAnchor.constraint(equalTo: container.topAnchor),
                created.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                created.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                created.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            host = created
        }
    }
}

/// 固定高度容器：用本地滚轮监视把纵向滚动锁在内部 SwiftUI ScrollView，避免外层 Form 抢事件。
private final class AIModelFixedHeightView: NSView {
    var fixedHeight: CGFloat = 0 {
        didSet {
            guard abs(oldValue - fixedHeight) >= 0.5 else { return }
            invalidateIntrinsicContentSize()
        }
    }

    private var scrollMonitor: Any?

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: fixedHeight > 0 ? fixedHeight : NSView.noIntrinsicMetric
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildScrollMonitor()
    }

    override func removeFromSuperview() {
        tearDownScrollMonitor()
        super.removeFromSuperview()
    }

    deinit {
        tearDownScrollMonitor()
    }

    private func rebuildScrollMonitor() {
        tearDownScrollMonitor()
        guard window != nil else { return }
        // Local monitor 在命中测试前拦截：指针在本列表内时吃掉纵向滚轮并转给内部 ScrollView。
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window == window else { return event }
            let localPoint = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(localPoint) else { return event }
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return event }
            guard let innerScrollView = self.firstDescendantScrollView() else { return event }

            let saved = innerScrollView.nextResponder
            innerScrollView.nextResponder = nil
            innerScrollView.scrollWheel(with: event)
            innerScrollView.nextResponder = saved
            return nil
        }
    }

    private func tearDownScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func firstDescendantScrollView() -> NSScrollView? {
        var stack: [NSView] = subviews
        while let view = stack.popLast() {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}

/// 单行模型控件。拆成独立 View，避免父列表 body 因其它行状态变化整表重建时重复量测。
private struct AIModelListRow: View {
    let model: AIModelDescriptor
    @Binding var isEnabled: Bool
    @Binding var capability: AIModelCapability
    let isCustomized: Bool
    @Binding var popoverItem: AIModelDescriptor?
    @Binding var parameters: AIModelParameters
    let onResetParameters: () -> Void
    let onOpenParameters: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ownedBy = model.ownedBy, !ownedBy.isEmpty {
                        Text(ownedBy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 8)

            Picker("", selection: $capability) {
                ForEach(AIModelCapability.allCases) { item in
                    Label(item.displayName, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .labelsHidden()
            .frame(width: 148)

            Button(action: onOpenParameters) {
                Image(systemName: isCustomized ? "gearshape.fill" : "gearshape")
                    .foregroundStyle(isCustomized ? Color.orange : Color.secondary)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("settings.ai.modelList.parametersHelp")
            .popover(item: $popoverItem, arrowEdge: .trailing) { focused in
                AIModelParametersPopover(
                    model: focused,
                    parameters: $parameters,
                    hasOverride: isCustomized,
                    onReset: onResetParameters
                )
                .appLocaleEnvironment()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
