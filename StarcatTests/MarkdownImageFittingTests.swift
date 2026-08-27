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
}
