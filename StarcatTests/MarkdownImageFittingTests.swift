//
//  MarkdownImageFittingTests.swift
//  StarcatTests
//
//  订阅发布 / Release notes 里的远程图必须按容器宽度等比缩小，
//  不能按 GitHub 截图像素尺寸撑破窗口。
//

import CoreGraphics
import Foundation
import Testing
@testable import Starcat

@Suite("MarkdownImageFitting")
struct MarkdownImageFittingTests {

    @Test("宽图按容器宽度等比缩小")
    func shrinksWideImageToContainerWidth() {
        let fitted = MarkdownImageFitting.size(
            fitting: CGSize(width: 1_672, height: 1_048),
            inWidth: 588
        )
        #expect(fitted.width == 588)
        #expect(abs(fitted.height - 368.7) < 0.5)
    }

    @Test("已经能放下的图不放大")
    func doesNotUpscaleSmallImage() {
        let fitted = MarkdownImageFitting.size(
            fitting: CGSize(width: 240, height: 120),
            inWidth: 588
        )
        #expect(fitted == CGSize(width: 240, height: 120))
    }

    @Test("无效尺寸返回 zero，避免 NaN 高度把时间线撑坏")
    func invalidSizesReturnZero() {
        #expect(
            MarkdownImageFitting.size(
                fitting: CGSize(width: 0, height: 100),
                inWidth: 588
            ) == .zero
        )
        #expect(
            MarkdownImageFitting.size(
                fitting: CGSize(width: 100, height: 50),
                inWidth: 0
            ) == .zero
        )
    }

    @Test("测试 host 不往 GitHub 图请求写 Authorization")
    func testHostDoesNotAttachAuthorization() {
        let url = URL(string: "https://github.com/user-attachments/assets/abc")!
        let modified = GitHubRemoteImageRequestModifier.modify(URLRequest(url: url))
        #expect(modified.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(modified.value(forHTTPHeaderField: "User-Agent") == AppConstants.httpUserAgent)
    }

    @Test("Layout 拿不到提议宽度时，回退到窗口测到的容器宽度")
    func availableWidthFallsBackToContainerWhenProposalMissing() {
        #expect(
            MarkdownImageFitting.availableWidth(proposal: 588, containerWidth: 620) == 588
        )
        #expect(
            MarkdownImageFitting.availableWidth(proposal: nil, containerWidth: 588) == 588
        )
        #expect(
            MarkdownImageFitting.availableWidth(proposal: 0, containerWidth: 588) == 588
        )
        #expect(
            MarkdownImageFitting.availableWidth(proposal: nil, containerWidth: 0) == nil
        )
    }

    @Test("列表项下一行的独立图提升为块，MarkdownUI 才会走可缩放的 ImageProvider")
    func prepareIsolatesListItemImagesIntoBlocks() {
        let raw = """
        - GitHub notification inbox: hello
          ![shot](https://cdn.dong4j.site/source/image/a.png)
        """
        let prepared = GitHubMarkdownPreparing.prepare(raw)
        #expect(prepared.contains("hello\n\n"))
        #expect(prepared.contains("![shot](https://cdn.dong4j.site/source/image/a.png)"))
        #expect(!prepared.contains("hello\n  ![shot]"))
    }

    @Test("HTML img 收成 Markdown 图，Release notes 里带 width 的截图才能走适配")
    func prepareConvertsHTMLImages() {
        let html = #"<img width="1672" alt="inbox" src="https://github.com/user-attachments/assets/abc" />"#
        let prepared = GitHubMarkdownPreparing.prepare(html)
        #expect(prepared.contains("![inbox](https://github.com/user-attachments/assets/abc)"))
        #expect(!prepared.contains("<img"))
    }

    @Test("句子中间的小图保持 inline，避免被抬成通栏块")
    func prepareLeavesMidSentenceImagesInline() {
        let raw = "See ![icon](https://example.com/i.png) here"
        #expect(GitHubMarkdownPreparing.prepare(raw) == raw)
    }

    @Test("代码块里的图片语法原样保留")
    func prepareSkipsFencedCodeBlocks() {
        let raw = """
        ```
        ![not-an-image](https://example.com/x.png)
        ```
        """
        #expect(GitHubMarkdownPreparing.prepare(raw) == raw)
    }
}
