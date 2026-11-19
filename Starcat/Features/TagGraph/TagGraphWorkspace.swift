// 在当前账户的全窗口画布内查找主题。原生操作区和离线画布共用选择状态。
import GRDB
import SwiftUI

/// 宿主以数据库修订号标识工作区，切号时同时销毁旧订阅和 WKWebView。
struct TagGraphWorkspace: View {
    let reader: any DatabaseReader
    let isCurrent: () -> Bool
    let escape: Int
    let onClose: () -> Void
    let onOpenRepo: (Repo) -> Void
    @State private var model = TagGraphViewModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.starcatReduceMotion) private var reduced
    @Environment(\.locale) private var locale
    @State private var camera = 0
    @State private var focusID: String?
    @State private var rendererAttempt = 0
    @State private var rendererFailed = false
    @State private var painted = false
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedTagID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("tagGraph.window.title", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Spacer()
                Button("followGraph.action.reset") {
                    model.select(nil)
                    focusID = nil
                    camera += 1
                }
                SheetCloseButton(action: onClose)
            }
            .padding(.horizontal).frame(height: 45)
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    if let graph = model.graph, !graph.nodes.isEmpty, !rendererFailed {
                        TagGraphCanvas(state: .init(graph: graph, session: model.session, generation: model.generation,
                            selected: model.selection?.tagIDs.sorted() ?? [], minimum: model.minimum,
                            camera: camera, focus: focusID, dark: scheme == .dark, reduced: reduced),
                            onSelect: acceptCanvas, onPaint: { painted = true }, onFailure: { rendererFailed = true })
                            .id(rendererAttempt)
                            .onDisappear { painted = false }
                            .accessibilityHidden(true)
                    }
                    if rendererFailed {
                        Button("followGraph.action.reloadRenderer") {
                            rendererAttempt += 1
                            painted = false
                            rendererFailed = false
                        }
                    } else if model.failed && model.graph == nil {
                        VStack(spacing: 10) {
                            Label("tagGraph.state.failed", systemImage: "exclamationmark.circle")
                            Button("action.retry") { model.observe() }
                        }
                    } else if model.graph?.nodes.isEmpty == true {
                        Label("tagGraph.state.empty", systemImage: "tag")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    } else if !painted {
                        graphSkeleton
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: reduced ? 0.10 : 0.18), value: painted)
                Divider()
                inspector.frame(minWidth: 230, idealWidth: 270, maxWidth: 305)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.bind(reader: reader, isCurrent: isCurrent); searchFocused = true }
        .onDisappear { model.clear() }
        .onChange(of: escape) {
            if model.showsAll { model.showsAll = false }
            else if !model.search.isEmpty { model.search = "" }
            else if model.selection != nil { model.select(nil) }
            else { onClose() }
        }
    }

    /// 首次等待数据库和 WebKit 真正绘出第一帧时共用同一个占位，减少动态效果时显示静态图形。
    private var graphSkeleton: some View {
        let palette = SkeletonPalette.forColorScheme(scheme)
        return SkeletonAnimatedPhase { phase in
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 80, weight: .light)).foregroundStyle(palette.base)
                .skeletonShimmer(phase: phase, palette: palette)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("followGraph.status.loading"))
    }

    private var inspector: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            TextField("batch.searchTags", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let node = model.graph?.matchingNodes(model.search).first { locate(node) } }
            if let graph = model.graph {
                LabeledContent("tagGraph.filter.minimum") {
                    TextField("tagGraph.filter.minimum", value: $model.minimum, format: .number.grouping(.never))
                        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 52)
                        .onChange(of: model.minimum) { _, new in model.minimum = max(1, new) }
                }
                let visibleCount = graph.visibleEdges(minimum: model.minimum).count
                Text(verbatim: String(format: .l10n("tagGraph.filter.count"), locale: locale, visibleCount, graph.edges.count))
                    .foregroundStyle(.secondary).font(.caption)
                if !graph.nodes.isEmpty && graph.edges.isEmpty {
                    Text("tagGraph.state.isolated").font(.callout).foregroundStyle(.secondary)
                } else if !graph.edges.isEmpty && visibleCount == 0 {
                    Text("tagGraph.state.filtered").font(.callout).foregroundStyle(.secondary)
                    Button("tagGraph.filter.showAll") { model.minimum = 1 }
                }
                if model.failed {
                    Label("tagGraph.state.failed", systemImage: "exclamationmark.circle")
                    Button("action.retry") { model.observe() }
                }
                if model.selectionDisappeared {
                    Text("tagGraph.state.removed").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                if let selection = model.selection, model.search.isEmpty {
                    TagGraphInspector(graph: graph, selection: selection, model: model, onOpenRepo: onOpenRepo)
                        .nativeDetailTransition(value: selection)
                } else {
                    tagList(graph)
                }
            } else if !model.failed {
                ListLoadingSkeleton(rowHeight: 32)
            }
            Spacer(minLength: 0)
        }.padding(12)
    }

    @ViewBuilder private func tagList(_ graph: TagGraphSnapshot) -> some View {
        let matches = graph.matchingNodes(model.search)
        if matches.isEmpty && !model.search.isEmpty {
            Text("batch.noMatch").foregroundStyle(.secondary)
            Button("search.clear") { model.search = ""; searchFocused = true }
        } else {
            List(Array(matches.enumerated()), id: \.element.id) { index, node in
                Button { locate(node) } label: {
                    HStack {
                        Image(systemName: node.icon ?? "tag")
                        Text(verbatim: node.name).lineLimit(1)
                        Spacer()
                        Text(node.repoCount, format: .number).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 5).frame(minHeight: 26)
                    .listRowSurface(index: index, isSelected: focusedTagID == node.id)
                }
                .buttonStyle(.plain).focusEffectDisabled().focused($focusedTagID, equals: node.id)
                .accessibilityLabel(Text(verbatim: node.name))
                .accessibilityValue(Text(verbatim: String(format: .l10n("list.repoCountFormat"), locale: locale, node.repoCount)))
                .help(Text(verbatim: node.name))
            }.listStyle(.inset)
        }
    }

    /// 搜索/列表定位才移动镜头，点画布或数据回读均保留视角。
    private func locate(_ node: TagGraphNode) {
        model.search = ""
        model.select(.node(node.id))
        focusID = node.id
        camera += 1
    }

    private func acceptCanvas(_ session: UUID, _ generation: Int, _ ids: [String]) {
        guard model.accepts(session: session, generation: generation) else { return }
        model.search = ""
        switch ids.count {
        case 0: model.select(nil)
        case 1: model.select(.node(ids[0]))
        case 2: model.select(.edge(TagGraphPair(ids[0], ids[1])))
        default: break
        }
    }
}
