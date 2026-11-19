//
//  SkillContentView.swift
//  Starcat
//
//  本机 Skill 的按需只读阅读区。视图任务随选择／刷新取消，磁盘读取由后台读取器完成；
//  Markdown 图片统一占位，避免读取不受信任正文时自动请求远端或本机附件。
//

import SwiftUI

/// 单个条目的内容状态随 entryID 重建，旧条目的异步结果不能污染新选择。
struct SkillContentView: View {
    let item: SkillLibraryItem
    let tab: SkillDetailTab
    let refreshID: UUID
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace
    @State private var snapshot: SkillContentSnapshot?
    @State private var failure: String?
    @State private var selectedFile: String?
    @State private var preview = PreviewPresentation()
    @State private var previewLoading = false
    @State private var contentID = UUID()
    @State private var loadID = UUID()
    @State private var previewID = UUID()

    private struct PreviewRequest: Hashable {
        let contentID: UUID
        let file: String?
    }

    /// 文件、正文与可见性是同一份展示快照；回切时可以恢复被中断退场的当前文件。
    struct PreviewPresentation {
        var file: String?
        var content: SkillContentPreview?
        var failure: String?
        var isVisible = false

        /// 同文件重新读取前先恢复已有正文，后续失败也不依赖成功回调才能看见内容。
        mutating func begin(file: String) -> Bool {
            failure = nil
            let retainsContent = self.file == file && content != nil
            if retainsContent {
                isVisible = true
            }
            return retainsContent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure {
                Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let snapshot {
                VStack(alignment: .leading, spacing: 12) {
                    if snapshot.isPartial {
                        Label("skills.detail.content.incomplete", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    if tab == .overview { markdown(snapshot.markdown) }
                    else { ScrollView { files(snapshot) } }
                }
            } else if let text = item.markdown {
                if tab == .overview { markdown(text) }
                else {
                    ForEach(item.files, id: \.self) { Label($0, systemImage: "doc.text") }
                }
            } else if failure == nil {
                // 首帧 task 尚未启动时也显示占位，不能先闪一次“内容不可用”。
                RepoSkillSkeletonView(layout: tab == .files ? .files : .manifest)
                    .frame(minHeight: 320)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 加载快照与文件选择留在稳定的外层，只交接不同页签的展示内容。
        // 条目与文件预览已有独立交接，页签不再复制并模糊整段 Markdown / 文件列表。
        .stableDetailTransition(value: tab)
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: snapshot == nil)
        .task(id: refreshID) { await load() }
        .task(id: PreviewRequest(contentID: contentID, file: selectedFile)) { await loadPreview() }
    }

    /// 复用仓库 Skills 的阅读工具；来源策略继续阻止图片、附件和非 http/https 链接。
    private func markdown(_ text: String) -> some View {
        MarkdownDocumentWebView(
            markdown: SkillFrontmatter.stripFrontmatter(text),
            resourcePolicy: .localTextOnly
        )
    }

    private func files(_ snapshot: SkillContentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.files.isEmpty {
                Text("skills.detail.files.empty").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(snapshot.files.enumerated()), id: \.element.id) { index, file in
                        Button {
                            selectedFile = file.path
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: icon(file.kind))
                                Text(verbatim: file.path).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if file.kind == .symbolicLink {
                                    Text("skills.detail.files.link").font(interfaceScale.font(.caption))
                                }
                            }
                            .font(interfaceScale.font(.code))
                            .foregroundStyle(selectedFile == file.path ? .primary : .secondary)
                            .padding(.vertical, 4)
                            .listRowSurface(index: index, isSelected: selectedFile == file.path,
                                            selectionNamespace: selectionSpace)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .disabled(file.kind != .file)
                    }
                }
            }
            .frame(height: min(260, CGFloat(snapshot.files.count) * 32))
            Divider()
            if let path = preview.file ?? selectedFile {
                Text(verbatim: path).font(interfaceScale.font(.code)).textSelection(.enabled)
            }
            ZStack(alignment: .topLeading) {
                if previewLoading && preview.content == nil {
                    RepoSkillSkeletonView(layout: .manifest).frame(minHeight: 320)
                        .transition(.opacity)
                } else if let content = preview.content {
                    VStack(alignment: .leading, spacing: 8) {
                        if let previewFailure = preview.failure {
                            Text(verbatim: previewFailure).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        switch content {
                        case .text(let text):
                            RepoFileSourcePreview(text: text).frame(minHeight: 320)
                        case .binary:
                            Text("repo.files.preview.binary").foregroundStyle(.secondary)
                        case .tooLarge:
                            Text("skills.detail.files.tooLarge").foregroundStyle(.secondary)
                        }
                    }
                    .opacity(preview.isVisible ? 1 : 0)
                    .blur(radius: reduceMotion || preview.isVisible ? 0 : 10)
                    .detailContentTransition()
                    .allowsHitTesting(preview.isVisible)
                    .accessibilityHidden(!preview.isVisible)
                } else if let previewFailure = preview.failure {
                    Text(verbatim: previewFailure).foregroundStyle(.secondary).textSelection(.enabled)
                        .detailContentTransition()
                } else {
                    Text("skills.detail.files.select").foregroundStyle(.secondary)
                }
            }
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: previewLoading)
            .clipped()
        }
    }

    /// Preview 样例使用内存正文；真实条目只读取当前可用位置，不尝试遍历整个来源。
    private func load() async {
        guard item.markdown == nil else { return }
        let run = UUID()
        loadID = run
        failure = nil
        do {
            guard let location = item.locations.first(where: { $0.state != .missing }),
                  let path = location.resolvedPath else { throw SkillContentReadError.unavailable }
            let content = try await SkillContentReader().load(rootPath: path)
            try Task.checkCancellation()
            guard loadID == run else { return }
            snapshot = content
            contentID = UUID()
            if let selectedFile, !content.files.contains(where: { $0.path == selectedFile && $0.kind == .file }) {
                self.selectedFile = nil
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, loadID == run else { return }
            failure = error.localizedDescription
        }
    }

    /// 选择或刷新后重新读取；取消的结果不写回当前预览。
    private func loadPreview() async {
        let run = UUID()
        previewID = run
        guard let selectedFile, let snapshot else {
            preview = PreviewPresentation()
            previewLoading = false
            return
        }
        let isRefresh = withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.24)) {
            preview.begin(file: selectedFile)
        }
        previewLoading = true
        defer { if previewID == run { previewLoading = false } }
        do {
            // 读取与退场并行，复用现有请求身份；刷新同一文件时继续显示旧内容。
            async let preparation = SkillContentReader().preview(
                rootPath: snapshot.rootPath, relativePath: selectedFile
            )
            if !isRefresh {
                await fadeOutPreview()
                try Task.checkCancellation()
                guard previewID == run else { return }
                preview = PreviewPresentation()
            }
            let value = try await preparation
            try Task.checkCancellation()
            guard previewID == run, self.selectedFile == selectedFile else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.24)) {
                preview = PreviewPresentation(file: selectedFile, content: value, isVisible: true)
                previewLoading = false
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, previewID == run, self.selectedFile == selectedFile else { return }
            preview.failure = error.localizedDescription
        }
    }

    /// 等实际退场完成后才替换正文，不用固定等待猜测 Markdown 或源码的渲染耗时。
    private func fadeOutPreview() async {
        guard preview.content != nil else {
            preview.isVisible = false
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withAnimation(.easeOut(duration: reduceMotion ? 0.06 : 0.12), completionCriteria: .removed) {
                preview.isVisible = false
            } completion: {
                continuation.resume()
            }
        }
    }

    private func icon(_ kind: SkillContentFile.Kind) -> String {
        switch kind {
        case .directory: "folder"
        case .file: "doc.text"
        case .symbolicLink: "link"
        case .unsupported: "questionmark.square"
        }
    }
}

