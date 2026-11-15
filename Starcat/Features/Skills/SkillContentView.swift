//
//  SkillContentView.swift
//  Starcat
//
//  本机 Skill 的按需只读阅读区。视图任务随选择／刷新取消，磁盘读取由后台读取器完成；
//  Markdown 图片统一占位，避免读取不受信任正文时自动请求远端或本机附件。
//

import MarkdownUI
import SwiftUI

/// 单个条目的内容状态随 entryID 重建，旧条目的异步结果不能污染新选择。
struct SkillContentView: View {
    let item: SkillLibraryItem
    let tab: SkillDetailTab
    let refreshID: UUID
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var snapshot: SkillContentSnapshot?
    @State private var failure: String?
    @State private var selectedFile: String?
    @State private var preview: SkillContentPreview?
    @State private var previewFailure: String?
    @State private var loading = false
    @State private var previewLoading = false
    @State private var contentID = UUID()
    @State private var loadID = UUID()
    @State private var previewID = UUID()

    private struct PreviewRequest: Hashable {
        let contentID: UUID
        let file: String?
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
                    else { files(snapshot) }
                }
            } else if let text = item.markdown {
                if tab == .overview { markdown(text) }
                else {
                    ForEach(item.files, id: \.self) { Label($0, systemImage: "doc.text") }
                }
            } else if loading {
                ProgressView("skills.detail.content.loading")
            } else if failure == nil {
                Text("skills.detail.content.unavailable").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: refreshID) { await load() }
        .task(id: PreviewRequest(contentID: contentID, file: selectedFile)) { await loadPreview() }
    }

    /// 两类图片 provider 都替换，行内图片也不得悄悄走默认 URLSession。
    private func markdown(_ text: String) -> some View {
        Markdown(SkillFrontmatter.stripFrontmatter(text))
            .markdownImageProvider(SkillBlockedImageProvider())
            .markdownInlineImageProvider(SkillBlockedInlineImageProvider())
            .markdownTextStyle {
                FontSize(interfaceScale.scaled(StarcatTypography.body.pointSize))
                ForegroundColor(.primary)
            }
            .environment(\.openURL, OpenURLAction { url in
                SkillPreviewLinkPolicy.allows(url) ? .systemAction(url) : .discarded
            })
    }

    private func files(_ snapshot: SkillContentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.files.isEmpty {
                Text("skills.detail.files.empty").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(snapshot.files) { file in
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
            if let selectedFile {
                Text(verbatim: selectedFile).font(interfaceScale.font(.code)).textSelection(.enabled)
            }
            if previewLoading {
                ProgressView("repo.files.preview.loading")
            } else if let previewFailure {
                Text(verbatim: previewFailure).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let preview {
                switch preview {
                case .text(let text):
                    RepoFileSourcePreview(text: text).frame(minHeight: 320)
                case .binary:
                    Text("repo.files.preview.binary").foregroundStyle(.secondary)
                case .tooLarge:
                    Text("skills.detail.files.tooLarge").foregroundStyle(.secondary)
                }
            } else {
                Text("skills.detail.files.select").foregroundStyle(.secondary)
            }
        }
    }

    /// Preview 样例使用内存正文；真实条目只读取当前可用位置，不尝试遍历整个来源。
    private func load() async {
        guard item.markdown == nil else { return }
        let run = UUID()
        loadID = run
        loading = true
        failure = nil
        defer { if loadID == run { loading = false } }
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
        previewLoading = false
        preview = nil
        previewFailure = nil
        guard let selectedFile, let snapshot else { return }
        previewLoading = true
        defer { if previewID == run { previewLoading = false } }
        do {
            let value = try await SkillContentReader().preview(rootPath: snapshot.rootPath, relativePath: selectedFile)
            try Task.checkCancellation()
            guard previewID == run, self.selectedFile == selectedFile else { return }
            preview = value
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, previewID == run, self.selectedFile == selectedFile else { return }
            previewFailure = error.localizedDescription
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

/// URL 仅用于符合 MarkdownUI 的协议签名，不读取图片内容。
private struct SkillBlockedImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Label("skills.detail.images.blocked", systemImage: "photo")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// 行内图片同样返回本机符号，绝不调用默认的网络图片 provider。
private struct SkillBlockedInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}
