//
//  GitHubMarkdownFitWidthImage.swift
//  Starcat
//
//  GitHub Markdown 远程图按容器宽度等比适配。
//
//  为什么需要单独组件
//  ──────────────────
//  MarkdownUI 默认 `ResizeToFit` 只在父级给出**有限宽度**时才会缩小。
//  订阅发布时间线是垂直 `ScrollView` + `LazyVStack`：图片经常按像素理想尺寸
//  （GitHub 截图常见 1600–2000px）参与布局，被约 540–620pt 的窗口裁掉。
//
//  第二层坑：changelog 常把截图写在列表项下一行（说明下一行 `![](url)`）。
//  这会被收成「同一段落里的 inline 图」，走 `Text` 附件而不是 `ImageProvider`，
//  宽度修饰符完全套不上。渲染前必须把独立行图片抬成块。
//
//  关键约束
//  ────────
//  - `ImageProvider.makeImage` 是 nonisolated 协议入口；Kingfisher 的 SwiftUI
//    modifier 必须留在 `View.body` 的 MainActor 上执行。
//  - GitHub `user-attachments` / 私有仓库图需要带 token；测试 host 禁止碰 Keychain。
//  - 只缩小、不放大，避免小图标被拉成通栏。
//  - `LazyVStack(alignment: .leading)` 量宽时常给 `.unspecified`；Layout 必须
//    能回退到窗口测到的容器宽度，不能把原图像素宽度回传给父级。
//

import AppKit
import Kingfisher
import MarkdownUI
import SwiftUI

/// 把原图像素尺寸压进容器宽度，高度按宽高比下降。
enum MarkdownImageFitting {
    static func size(fitting intrinsic: CGSize, inWidth containerWidth: CGFloat) -> CGSize {
        guard intrinsic.width > 0, intrinsic.height > 0 else { return .zero }
        guard containerWidth.isFinite, containerWidth > 0 else { return .zero }
        guard intrinsic.width > containerWidth else { return intrinsic }
        let scale = containerWidth / intrinsic.width
        return CGSize(width: containerWidth, height: intrinsic.height * scale)
    }

    /// Layout 优先用父级提议宽度；`LazyVStack` 量 ideal size 时提议为空，回退窗口宽度。
    static func availableWidth(proposal: CGFloat?, containerWidth: CGFloat) -> CGFloat? {
        if let proposal, proposal.isFinite, proposal > 0 { return proposal }
        if containerWidth.isFinite, containerWidth > 0 { return containerWidth }
        return nil
    }
}

/// GitHub Release notes 渲染前预处理：HTML `<img>` → Markdown，独立行图片抬成块。
///
/// 句子中间的 `![icon](url)` 保持 inline，避免小图标被抬成通栏。
enum GitHubMarkdownPreparing {
    static func prepare(_ raw: String) -> String {
        isolateStandaloneImages(GitHubNotificationMapper.prepareMarkdown(raw))
    }

    /// 独立成行的 `![alt](url)` 前后补空行，让 MarkdownUI 走块级 `ImageProvider`。
    static func isolateStandaloneImages(_ raw: String) -> String {
        let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var result: [String] = []
        result.reserveCapacity(lines.count + 8)
        var inFence = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                result.append(line)
                continue
            }

            let isImage = !inFence && isStandaloneImageLine(trimmed)
            if isImage, result.last.map({ !$0.isEmpty }) == true {
                result.append("")
            }
            result.append(line)
            if isImage {
                let next = index + 1 < lines.count ? lines[index + 1] : ""
                if !next.isEmpty {
                    result.append("")
                }
            }
        }
        return result.joined(separator: "\n")
    }

    private static func isStandaloneImageLine(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("![") else { return false }
        guard let altEnd = trimmed.firstIndex(of: "]") else { return false }
        let afterAlt = trimmed.index(after: altEnd)
        guard afterAlt < trimmed.endIndex, trimmed[afterAlt] == "(" else { return false }
        guard trimmed.hasSuffix(")") else { return false }
        return true
    }
}

private struct MarkdownContainerWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var markdownContainerWidth: CGFloat {
        get { self[MarkdownContainerWidthKey.self] }
        set { self[MarkdownContainerWidthKey.self] = newValue }
    }
}

private struct MarkdownContainerWidthPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// 挂在由窗口决定宽度的祖先上（不要挂在会被大图撑开的 Markdown 自己身上）。
private struct MarkdownContainerWidthReporter: ViewModifier {
    var horizontalInset: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MarkdownContainerWidthPreference.self,
                        value: max(0, proxy.size.width - horizontalInset * 2)
                    )
                }
            }
            .onPreferenceChange(MarkdownContainerWidthPreference.self) { width = $0 }
            .environment(\.markdownContainerWidth, width)
    }
}

extension View {
    /// 把当前视图的窗口宽度（扣除左右 inset）灌进 Markdown 图适配。
    func reportingMarkdownContainerWidth(horizontalInset: CGFloat = 0) -> some View {
        modifier(MarkdownContainerWidthReporter(horizontalInset: horizontalInset))
    }
}

/// MarkdownUI 远程图入口：把 Kingfisher 加载和宽度约束留在 View.body。
struct GitHubMarkdownFitWidthImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Group {
            if let url {
                GitHubMarkdownFitWidthRemoteImage(url: url)
            }
        }
    }
}

/// `user-attachments` 在私有仓库里要带 token；测试 host 禁止碰 Keychain。
enum GitHubRemoteImageRequestModifier {
    static func modify(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        guard !TestEnvironment.isRunning else { return request }
        guard let host = request.url?.host?.lowercased(),
              host.contains("github.com") || host.contains("githubusercontent.com"),
              let token = try? KeychainManager.shared.loadGithubToken(),
              !token.isEmpty
        else { return request }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

extension View {
    /// 让 MarkdownUI 远程图按当前容器宽度等比适配，避免被窗口裁切。
    func fittedGitHubMarkdownImages() -> some View {
        MarkdownContentWidthLayoutAdapter {
            self
                .markdownImageProvider(GitHubMarkdownFitWidthImageProvider())
                .markdownBlockStyle(\.image) { configuration in
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// Layout 读不到 Environment；先在 View 里取出窗口宽度再交给 Layout。
private struct MarkdownContentWidthLayoutAdapter<Content: View>: View {
    @Environment(\.markdownContainerWidth) private var containerWidth
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        MarkdownContentWidthLayout(containerWidth: containerWidth) {
            content()
        }
    }
}

/// 把父级给出的有限宽度灌进 Markdown，避免内部图片按 `.unspecified` 理想尺寸撑破窗口。
private struct MarkdownContentWidthLayout: Layout {
    var containerWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        guard let width = MarkdownImageFitting.availableWidth(
            proposal: proposal.width,
            containerWidth: containerWidth
        ) else {
            return view.sizeThatFits(proposal)
        }
        let size = view.sizeThatFits(.init(width: width, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        view.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// Kingfisher 在 `View.body` 里加载；Layout 用提议宽度做最后一道等比约束。
private struct GitHubMarkdownFitWidthRemoteImage: View {
    let url: URL
    @Environment(\.markdownContainerWidth) private var containerWidth

    var body: some View {
        MarkdownFitWidthLayout(containerWidth: containerWidth) {
            KFImage(url)
                .requestModifier(AnyModifier { request in
                    GitHubRemoteImageRequestModifier.modify(request)
                })
                .placeholder {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
                .fade(duration: 0.15)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 子视图理想尺寸超过提议宽度时，按 `MarkdownImageFitting` 缩小。
private struct MarkdownFitWidthLayout: Layout {
    var containerWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let intrinsic = view.sizeThatFits(.unspecified)
        guard let width = MarkdownImageFitting.availableWidth(
            proposal: proposal.width,
            containerWidth: containerWidth
        ) else {
            return intrinsic
        }
        return MarkdownImageFitting.size(fitting: intrinsic, inWidth: width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        view.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
