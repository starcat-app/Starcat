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
                            .accessibilityHidden(true)
                    }
                    if rendererFailed {
                        Button("followGraph.action.reloadRenderer") {
                            rendererAttempt += 1
                            painted = false
                            rendererFailed = false
                        }
                    } else if model.graph?.nodes.isEmpty == true {
                        Text("batch.noTags").foregroundStyle(.secondary)
                    } else if !painted && !model.failed {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(minWidth: 230, idealWidth: 270, maxWidth: 305)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.bind(reader: reader, isCurrent: isCurrent) }
        .onDisappear { model.clear() }
        .onChange(of: escape) {
            if model.showsAll { model.showsAll = false }
            else if !model.search.isEmpty { model.search = "" }
            else if model.selection != nil { model.select(nil) }
            else { onClose() }
        }
    }

    private var inspector: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            TextField("batch.searchTags", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let node = model.graph?.matchingNodes(model.search).first { locate(node) } }
            if let graph = model.graph {
                LabeledContent("tagGraph.filter.minimum") {
                    TextField("tagGraph.filter.minimum", value: $model.minimum, format: .number.grouping(.never))
                        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 52)
                        .onChange(of: model.minimum) { _, new in model.minimum = max(1, new) }
                }
                Text(verbatim: String(format: .l10n("tagGraph.filter.count"), locale: locale,
                                      graph.visibleEdges(minimum: model.minimum).count, graph.edges.count))
                    .foregroundStyle(.secondary).font(.caption)
                Divider()
                tagList(graph)
            }
            if model.failed { Button("action.retry") { model.observe() } }
            Spacer(minLength: 0)
        }.padding(12)
    }

    private func tagList(_ graph: TagGraphSnapshot) -> some View {
        List(graph.matchingNodes(model.search)) { node in
            Button { locate(node) } label: {
                HStack {
                    Image(systemName: node.icon ?? "tag")
                    Text(verbatim: node.name).lineLimit(1)
                    Spacer()
                    Text(node.repoCount, format: .number).monospacedDigit().foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    /// 搜索/列表定位才移动镜头，点画布或数据回读均保留视角。
    private func locate(_ node: TagGraphNode) {
        model.select(.node(node.id))
        focusID = node.id
        camera += 1
    }

    private func acceptCanvas(_ session: UUID, _ generation: Int, _ ids: [String]) {
        guard model.accepts(session: session, generation: generation) else { return }
        switch ids.count {
        case 0: model.select(nil)
        case 1: model.select(.node(ids[0]))
        case 2: model.select(.edge(TagGraphPair(ids[0], ids[1])))
        default: break
        }
    }
}
