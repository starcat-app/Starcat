// 标签与仓库归属图谱的全窗口宿主。画布、入场和交互复用关注者图谱。
import AppKit
import GRDB
import SwiftUI

/// 数据订阅仍按账户隔离；渲染状态只描述当前 WebView 会话。
struct TagGraphWorkspace: View {
    // 画布从本地资源加载 Logo，点击「更多」时无需重新传输图片。
    private static let appLogoURL = Bundle.main.url(
        forResource: "starcat-\(DistributionChannel.current.rawValue)-r", withExtension: "png"
    )?.absoluteString

    let reader: any DatabaseReader
    let isCurrent: () -> Bool
    let escape: Int
    let onClose: () -> Void
    // 卡片底部「打开详情」的落点，由宿主页面接到 RepoDetailWindowController。
    let onOpenDetail: (Repo) -> Void
    @State private var model = TagGraphViewModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var focusID: String?
    @State private var viewportRevision = 0
    @State private var rendererRevision = 0
    @State private var rendererPresented = false
    @State private var rendererFailed = false
    @State private var canvasSize = CGSize.zero
    @State private var cardContentHeight: CGFloat = 180
    @State private var toolbarHeight: CGFloat = 28
    @FocusState private var focusedControl: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvas
            FollowGraphSelectionCard(node: rendererPresented ? model.selectedNode : nil,
                                     canvasSize: canvasSize, toolbarHeight: toolbarHeight,
                                     contentHeight: $cardContentHeight) { node in
                TagGraphNodeCard(node: node, model: model, reader: reader, isCurrent: isCurrent,
                                 onOpenDetail: onOpenDetail) {
                    focus(node.id)
                }
            }
            .zIndex(1)
        }
        .overlay(alignment: .top) {
            FollowGraphToolbarPanel(
                canvasWidth: canvasSize.width,
                search: $search,
                searchPlaceholder: "tagGraph.search.placeholder",
                toolbarHeight: $toolbarHeight,
                focusedControl: $focusedControl,
                onSearchSubmit: selectFirstSearchResult
            ) {
                resetButton
            } results: {
                searchResults
            }
            .padding(.top, 16)
        }
        .overlay(alignment: .bottom) { failureOverlay }
        .overlay(alignment: .topTrailing) {
            SheetCloseButton(action: onClose)
                .accessibilityLabel(Text("common.close"))
                .padding(16)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .onAppear { model.bind(reader: reader, isCurrent: isCurrent) }
        .onDisappear { model.clear() }
        .onChange(of: escape) {
            if !search.isEmpty {
                search = ""
                focusedControl = "search"
            } else if model.selectedID != nil {
                model.select(nil)
            } else {
                onClose()
            }
        }
    }

    private var canvas: some View {
        ZStack {
            Color(white: scheme == .dark ? 28.0 / 255 : 245.0 / 255).ignoresSafeArea()
            if let graph = model.displayed, !graph.nodes.isEmpty, !rendererFailed {
                FollowGraphWebView(input: canvasInput, events: canvasEvents)
                    .id(rendererRevision)
                    .ignoresSafeArea()
                    .opacity(rendererPresented ? 1 : 0)
                    .allowsHitTesting(rendererPresented)
                    .accessibilityHidden(!rendererPresented)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: rendererPresented)
                if !rendererPresented { graphSkeleton }
            } else if !rendererFailed && model.displayed?.nodes.isEmpty == true {
                Label("tagGraph.state.empty", systemImage: "tag")
                    .foregroundStyle(.secondary)
            } else if !rendererFailed && !model.failed {
                graphSkeleton
            }
        }
    }

    /// 数据与命令分离，搜索、重置视角和主题变化不重复编码整张图。
    private var canvasInput: FollowGraphWebView.Input? {
        guard let graph = model.displayed else { return nil }
        let root = TagGraphViewModel.rootID
        return FollowGraphWebView.Input(
            rootID: root,
            kind: .tags,
            revision: model.revision,
            selectedID: model.selectedID,
            selectionRevision: model.selectionRevision,
            viewportRevision: viewportRevision,
            focusID: focusID
        ) {
            var logo: [String: Any] = ["id": root, "kind": "app", "name": "Starcat"]
            logo["glyph"] = Self.appLogoURL
            let nodes = graph.nodes.map { node -> [String: Any] in
                var value: [String: Any] = ["id": node.id, "kind": node.kind.rawValue, "name": node.name]
                if node.kind == .tag {
                    value["color"] = node.color ?? ""
                    if let glyph = TagGraphSymbolCache.glyph(for: node.icon ?? "tag") {
                        value["glyph"] = glyph
                    }
                } else {
                    value["avatar"] = FollowGraphAvatarURL.source(node.avatarURL)
                }
                return value
            }
            // Logo 连线只用于画布导航。归属查询和标签统计只读取数据库里的边。
            let anchors = graph.nodes.lazy.filter { $0.kind == .tag }.map { ["source": root, "target": $0.id] }
            return ([logo] + nodes, Array(anchors) + graph.edges.map { ["source": $0.source, "target": $0.target] })
        }
    }

    private var canvasEvents: FollowGraphWebView.Events {
        let renderer = rendererRevision
        return FollowGraphWebView.Events(
            isCurrent: { isCurrent() && rendererRevision == renderer && !rendererFailed },
            onPresented: { rendererPresented = true },
            onError: { failed in
                guard failed else { return }
                rendererPresented = false
                rendererFailed = true
            },
            onSelect: { id in
                guard model.select(id) else { return nil }
                return canvasInput
            },
            onProgress: { _, _, revision, id, selectionRevision, count in
                model.reportProgress(revision: revision, selectedID: id,
                                     selectionRevision: selectionRevision, count: count)
            }
        )
    }

    @ViewBuilder private var failureOverlay: some View {
        VStack(spacing: 8) {
            if rendererFailed {
                Button("followGraph.action.reloadRenderer") {
                    rendererFailed = false
                    rendererPresented = false
                    model.resetRenderedProgress()
                    rendererRevision += 1
                }
                .buttonStyle(.bordered)
            } else if model.failed {
                Label("tagGraph.state.failed", systemImage: "exclamationmark.circle")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                Button("action.retry") { model.observe() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.bottom, 16)
    }

    private func selectFirstSearchResult() {
        if let node = model.graph?.matchingNodes(search).first { locate(node) }
    }

    private var resetButton: some View {
        Button { focus(nil) } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedControl, equals: "followGraph.action.reset")
        .help(String.l10n("followGraph.action.reset"))
        .accessibilityLabel(Text("followGraph.action.reset"))
    }

    @ViewBuilder private var searchResults: some View {
        let matches = model.graph?.matchingNodes(search, limit: 12) ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if matches.isEmpty {
                    Text("followGraph.search.empty")
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, node in
                        Button { locate(node) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: node.kind == .tag ? (node.icon ?? "tag") : "book.closed")
                                    .foregroundStyle(.secondary)
                                Text(verbatim: node.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .listRowSurface(index: index)
                        .focused($focusedControl, equals: "result.\(node.id)")
                        .help(Text(verbatim: node.name))
                        .accessibilityLabel(Text(verbatim: node.name))
                    }
                }
            }
        }
        .frame(maxWidth: 440, maxHeight: 230)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// 搜索定位会同时高亮并移动镜头；画布内点击由 renderer 本地处理。
    private func locate(_ node: TagGraphNode) {
        model.locate(node.id)
        focus(model.selectedID)
        search = ""
        focusedControl = nil
    }

    private func focus(_ id: String?) {
        focusID = id
        viewportRevision += 1
    }

    /// 首帧由 WebKit 汇报，数据库读取和脚本装载期间使用同一静态占位。
    private var graphSkeleton: some View {
        let palette = SkeletonPalette.forColorScheme(scheme)
        return SkeletonAnimatedPhase { phase in
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 80, weight: .light))
                .foregroundStyle(palette.base)
                .skeletonShimmer(phase: phase, palette: palette)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("followGraph.status.loading"))
    }
}

/// SF Symbols 只在标签图使用。按符号名缓存透明 PNG，避免数据库刷新时重复栅格化。
@MainActor private enum TagGraphSymbolCache {
    private static var glyphs: [String: String?] = [:]

    static func glyph(for symbol: String) -> String? {
        if let cached = glyphs[symbol] { return cached }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let configured = image.withSymbolConfiguration(.init(pointSize: 40, weight: .medium)),
              let value = dataURL(configured) else {
            // 记录失败可以避免每次图刷新都请求系统符号；renderer 会回退到标签首字。
            glyphs[symbol] = .some(nil)
            return nil
        }
        glyphs[symbol] = value
        return value
    }

    private static func dataURL(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
