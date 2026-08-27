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
//  关键约束
//  ────────
//  - `ImageProvider.makeImage` 是 nonisolated 协议入口；Kingfisher 的 SwiftUI
//    modifier 必须留在 `View.body` 的 MainActor 上执行。
//  - GitHub `user-attachments` / 私有仓库图需要带 token；测试 host 禁止碰 Keychain。
//  - 只缩小、不放大，避免小图标被拉成通栏。
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
        MarkdownContentWidthLayout {
            self
                .markdownImageProvider(GitHubMarkdownFitWidthImageProvider())
                .markdownBlockStyle(\.image) { configuration in
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 把父级给出的有限宽度灌进 Markdown，避免内部图片按 `.unspecified` 理想尺寸撑破窗口。
private struct MarkdownContentWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite, width > 0 else {
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

    var body: some View {
        MarkdownFitWidthLayout {
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
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 子视图理想尺寸超过提议宽度时，按 `MarkdownImageFitting` 缩小。
private struct MarkdownFitWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let intrinsic = view.sizeThatFits(.unspecified)
        guard let width = proposal.width, width.isFinite, width > 0 else {
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
