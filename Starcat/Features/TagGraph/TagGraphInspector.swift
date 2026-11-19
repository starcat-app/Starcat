// 标签与关联详情。仓库在独立详情窗打开，画布宿主、视角和当前分页继续保留。
import SwiftUI

/// 鼠标和辅助技术选择一条边后共用这个检查器，所有仓库成员来自同一份 AND 查询。
struct TagGraphInspector: View {
    let graph: TagGraphSnapshot
    let selection: TagGraphSelection
    let model: TagGraphViewModel
    let onOpenRepo: (Repo) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("settings.navigation.back") {
                if model.showsAll { model.showsAll = false } else { model.select(nil) }
            }
            let names = selection.tagIDs.sorted().compactMap { id in graph.nodes.first { $0.id == id }?.name }
            Text(verbatim: names.joined(separator: " ∩ ")).font(.headline).textSelection(.enabled)
            if let page = model.page {
                let countKey = selection.tagIDs.count == 2 ? "tagGraph.detail.shared" : "list.repoCountFormat"
                Text(verbatim: String(format: .l10n(countKey), locale: locale, page.total))
                    .foregroundStyle(.secondary)
                if model.showsAll {
                    repositoryList(page)
                } else {
                    Button("insights.drilldown.viewAll") { model.showsAll = true }
                        .disabled(page.total == 0)
                    if case .node(let id) = selection {
                        relatedTags(id)
                    } else {
                        // 即使不进入完整列表，也可以核对前三个共同仓库。
                        ForEach(page.items.prefix(3)) { repo in repositoryButton(repo) }
                    }
                }
            } else if !model.failed {
                ListLoadingSkeleton(rowCount: 4, rowHeight: 32)
            }
        }
    }

    /// 保留查询的权重降序和端点决胜顺序；阈值与画布显示的邻居一致。
    private func relatedTags(_ id: String) -> some View {
        let edges = graph.visibleEdges(minimum: model.minimum).filter { $0.leftID == id || $0.rightID == id }
        return VStack(alignment: .leading) {
            Text("tagGraph.detail.related").font(.subheadline.bold())
            List(edges) { edge in
                let otherID = id == edge.leftID ? edge.rightID : edge.leftID
                if let other = graph.nodes.first(where: { $0.id == otherID }) {
                    Button { model.select(.edge(edge.id)) } label: {
                        HStack {
                            Text(verbatim: other.name).lineLimit(2)
                            Spacer()
                            Text(edge.sharedCount, format: .number).monospacedDigit()
                        }.contentShape(Rectangle())
                    }
                    .help(Text(verbatim: other.name))
                    .accessibilityLabel(Text(verbatim: other.name))
                    .accessibilityValue(Text(verbatim: String(format: .l10n("tagGraph.detail.shared"), locale: locale, edge.sharedCount)))
                }
            }.listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    /// 显式翻页使键盘、VoiceOver 和鼠标都能访问全部仓库，无需调整首页筛选。
    private func repositoryList(_ page: RepoTagIntersectionPage) -> some View {
        VStack {
            List(page.items) { repo in repositoryButton(repo) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            if page.total > TagGraphViewModel.pageSize {
                HStack {
                    Button("recommendations.daily.browsePrevious") { model.turnPage(to: model.offset - TagGraphViewModel.pageSize) }
                        .disabled(model.offset == 0)
                    Text(verbatim: "\(model.offset + 1)–\(model.offset + page.items.count) / \(page.total)").monospacedDigit()
                    Button("recommendations.daily.browseNext") { model.turnPage(to: model.offset + TagGraphViewModel.pageSize) }
                        .disabled(model.offset + page.items.count >= page.total)
                }.controlSize(.small)
            }
        }
    }

    private func repositoryButton(_ repo: Repo) -> some View {
        Button { onOpenRepo(repo) } label: {
            Label { Text(verbatim: repo.fullName).lineLimit(2) } icon: { Image(systemName: "book.closed") }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .help(Text(verbatim: repo.fullName))
    }
}
