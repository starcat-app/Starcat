//
//  RepoSkillFilePreview.swift
//  Starcat
//
//  阅读区底部附件预览，Markdown 复用正文渲染，其他文件保留源码与 blob 大小限制。
//

import AppKit
import SwiftUI

/// 预览独立于勾选状态；关闭或换文件时 SwiftUI 取消对应请求。
struct RepoSkillFilePreview: View {
    let skill: RepoSkill
    let file: RepoSkillFile
    let session: RepoSkillSession
    let onClose: () -> Void

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var value: RepoFilePreview?
    @State private var error: String?
    @State private var markdown: RepoFileMarkdownDocument?
    @State private var renderedDocumentID: String?

    private var isContentReady: Bool {
        error != nil || (value != nil && (markdown == nil || renderedDocumentID == markdown?.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: file.path)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                SheetCloseButton(action: onClose)
            }
            .padding(14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(isContentReady ? 1 : 0)
                .allowsHitTesting(isContentReady)
                .accessibilityHidden(!isContentReady)
                .overlay {
                    if !isContentReady {
                        RepoSkillSkeletonView(layout: .manifest)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: isContentReady)
        }
        .task(id: "\(skill.id):\(file.id)") {
            value = nil
            error = nil
            markdown = nil
            renderedDocumentID = nil
            do {
                let preview = try await session.preview(file: file, skill: skill)
                var preparedMarkdown: RepoFileMarkdownDocument?
                if case .text(let text) = preview, RepoFileMarkdownRenderer.supports(fileName: file.name) {
                    preparedMarkdown = try await RepoFileMarkdownRenderer.shared.prepare(
                        text: text, target: RepoFileBrowserTarget(repo: session.repo),
                        commit: skill.commitSHA, path: skill.directory + file.path, blobSHA: file.sha
                    )
                }
                // 关闭、换文件或切换 Skill 后不得发布迟到内容；渲染只读取扫描时的提交。
                try Task.checkCancellation()
                markdown = preparedMarkdown
                value = preview
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// 正文就绪即入场，不等待图片等资源；渲染失败回到已读到的源码，避免永久骨架。
    @ViewBuilder private var content: some View {
        if let error {
            Text(verbatim: error).foregroundStyle(.secondary).padding()
        } else if let value {
            switch value {
            case .text(let text):
                if let markdown {
                    ReadmeWebView(
                        htmlFragment: markdown.html, documentID: markdown.id, baseURL: markdown.baseURL,
                        onDocumentReady: { documentID in
                            if documentID == self.markdown?.id { renderedDocumentID = documentID }
                        },
                        onDocumentFailed: { documentID in
                            if documentID == self.markdown?.id { self.markdown = nil }
                        },
                        allowsSameDocumentAnchors: true
                    )
                } else {
                    RepoFileSourcePreview(text: text)
                }
            case .image(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().padding()
                } else {
                    Text("repo.files.preview.binary").foregroundStyle(.secondary)
                }
            case .binary:
                Text("repo.files.preview.binary").foregroundStyle(.secondary)
            case .tooLarge(let count):
                Text(String(format: String.l10n("repo.files.preview.tooLargeFormat"),
                            ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)))
                    .foregroundStyle(.secondary).padding()
            case .gitLFS(let count):
                Text(String(format: String.l10n("repo.files.preview.lfsFormat"),
                            ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)))
                    .foregroundStyle(.secondary).padding()
            }
        } else {
            Color.clear
        }
    }
}
