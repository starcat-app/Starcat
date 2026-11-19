//
//  MarkdownDocumentWebView.swift
//  Starcat
//
//  本机 Markdown → HTML → 共享阅读器。每个阅读区只保留当前文档，准备任务随源文
//  变化取消；显示前核对文档身份，防止快速切换后旧 WebKit 回调揭开新正文。
//

import MarkdownUI
import SwiftUI

/// 单篇静态文档的阅读宿主，复用字号工具、回到顶部及主题，不承载业务操作。
struct MarkdownDocumentWebView: View {
    let markdown: String
    var baseURL: URL? = nil

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var document: Document?
    @State private var renderedID: String?
    @State private var failedID: String?

    private struct Document {
        let id: String
        let html: String
    }

    var body: some View {
        ZStack {
            if let document {
                if failedID == document.id {
                    // 渲染进程失败仍保留原文可读，不重新请求内容或永久显示骨架。
                    ScrollView {
                        Text(verbatim: markdown)
                            .starcatMarkdownBodyFont()
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    ReadmeWebView(
                        htmlFragment: document.html, documentID: document.id, baseURL: baseURL,
                        onDocumentReady: { id in
                            guard id == self.document?.id else { return }
                            withAnimation(.easeOut(duration: reduceMotion ? 0.06 : 0.12)) { renderedID = id }
                        },
                        onDocumentFailed: { id in
                            if id == self.document?.id { failedID = id }
                        },
                        allowsSameDocumentAnchors: true
                    )
                    .opacity(renderedID == document.id ? 1 : 0)
                }
            }
            if document == nil || (renderedID != document?.id && failedID != document?.id) {
                ReadmeSkeletonView().transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: markdown) {
            let source = markdown
            let html = await Self.render(source)
            guard !Task.isCancelled else { return }
            document = Document(id: UUID().uuidString, html: html)
        }
    }

    /// 转换只在内容变化时后台执行；调字号或展开阅读工具不重新解析整篇 Markdown。
    @concurrent
    private static func render(_ markdown: String) async -> String {
        MarkdownContent(markdown).renderHTML()
    }
}
