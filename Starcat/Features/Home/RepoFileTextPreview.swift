//
//  RepoFileTextPreview.swift
//  Starcat
//
//  Markdown 与源码保持同一结构身份。切换模式和放大不移除 WKWebView，
//  两种模式各自保留滚动位置；骨架只等当前文档的真实导航完成。
//

import SwiftUI

/// HTML 就绪不等于页面已显示；使用 documentID 核对 WebKit 的晚到回调。
struct RepoFileTextPreview: View {
    let text: String
    let markdown: RepoFileBrowserViewModel.MarkdownPhase
    let mode: RepoFileBrowserViewModel.PreviewMode
    let onFailure: (String) -> Void
    var translationRenderState: ReadmeTranslationRenderState = .hidden
    var onTranslationSourceChange: ((ReadmeTranslationSourceSnapshot, String) -> Void)?
    /// 由调用方按「是否存在翻译场景 + 是否可见渲染层」计算；nil = 不提取、不上桥。
    var translationMode: ReadmeTranslationMode? = nil
    @State private var renderedID: String?
    @Environment(\.starcatReduceMotion) private var reduceMotion

    private var document: RepoFileMarkdownDocument? {
        if case .ready(let document) = markdown { return document }
        return nil
    }

    private var showsSource: Bool {
        if case .idle = markdown { return true }
        return mode == .source
    }

    var body: some View {
        ZStack {
            RepoFileSourcePreview(text: text)
                .opacity(showsSource ? 1 : 0)
                .allowsHitTesting(showsSource)
                .accessibilityHidden(!showsSource)
            if let document {
                ReadmeWebView(
                    htmlFragment: document.html, documentID: document.id, baseURL: document.baseURL,
                    translationRenderState: translationRenderState,
                    onTranslationSourceChange: { snapshot in
                        onTranslationSourceChange?(snapshot, document.id)
                    },
                    translationMode: translationMode,
                    onDocumentReady: { identifier in
                        guard identifier == self.document?.id else { return }
                        withAnimation(.easeOut(duration: reduceMotion ? 0.06 : 0.12)) {
                            renderedID = identifier
                        }
                    },
                    onDocumentFailed: onFailure,
                    registersFindShortcut: false,
                    allowsSameDocumentAnchors: true
                )
                .opacity(!showsSource && renderedID == document.id ? 1 : 0)
                .allowsHitTesting(!showsSource && renderedID == document.id)
                .accessibilityHidden(showsSource || renderedID != document.id)
            }
            if !showsSource {
                if case .failed(let message) = markdown {
                    Text(verbatim: message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else if document == nil || renderedID != document?.id {
                    ReadmeSkeletonView()
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
