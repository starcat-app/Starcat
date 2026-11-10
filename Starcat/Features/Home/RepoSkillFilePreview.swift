//
//  RepoSkillFilePreview.swift
//  Starcat
//
//  安装前核对固定提交的附件，复用现有源码预览和 blob 大小限制，不执行文件内容。
//

import AppKit
import SwiftUI

/// 预览独立于勾选状态；关闭或换文件时 SwiftUI 取消对应请求。
struct RepoSkillFilePreview: View {
    let skill: RepoSkill
    let file: RepoSkillFile
    let session: RepoSkillSession
    let onClose: () -> Void

    @State private var value: RepoFilePreview?
    @State private var error: String?

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
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 420)
        .task(id: "\(skill.id):\(file.id)") {
            value = nil
            error = nil
            do {
                value = try await session.preview(file: file, skill: skill)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// 文本用只读 NSTextView；图片仅解码预览，二进制、LFS 和大文件沿用下载功能的提示。
    @ViewBuilder private var content: some View {
        if let error {
            Text(verbatim: error).foregroundStyle(.secondary).padding()
        } else if let value {
            switch value {
            case .text(let text):
                RepoFileSourcePreview(text: text)
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
            ProgressView("repo.files.preview.loading")
        }
    }
}
