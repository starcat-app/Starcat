//
//  ReadmeAssetURLRewriterTests.swift
//  StarcatTests
//
//  README 图片相对路径与 GitHub attachment 视频地址重写单测。
//
//  本文件继承原 `ReadmeWebViewTests` 中关于 `rewriteAssetURLs` / `rewriteOneAssetURL`
//  的 8 个用例（逻辑没改、仅是函数从 UI 层 ReadmeWebView 迁到 IO 层
//  ReadmeAssetURLRewriter）。Issue #107 在同一 IO 边界补充短时效视频 URL 规范化。
//

import Testing
import Foundation
@testable import Starcat

@Suite("ReadmeAssetURLRewriter")
struct ReadmeAssetURLRewriterTests {

    // MARK: - rewrite (HTML 整体扫描)

    @Test("相对路径图片重写为 raw.githubusercontent.com")
    func rewrite_relativePath() {
        let html = #"<img src="./logo.png" alt="logo">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("https://raw.githubusercontent.com/alice/foo/HEAD/logo.png"))
    }

    @Test("子目录 README 的相对图片按 data-path 所在目录重写")
    func rewrite_relativePathUsesReadmeDataPathDirectory() {
        let html = #"""
        <div id="readme" data-path=".github/README.md">
          <img src="img/javalin.png" alt="Logo">
        </div>
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "javalin", repo: "javalin")

        #expect(result.contains("https://raw.githubusercontent.com/javalin/javalin/HEAD/.github/img/javalin.png"))
        #expect(!result.contains("https://raw.githubusercontent.com/javalin/javalin/HEAD/img/javalin.png"))
    }

    @Test("子目录 README 旧缓存里错误的 raw HEAD 根路径会被修复")
    func rewrite_repairsWrongSameRepoHeadRawURLWithDataPathDirectory() {
        let html = #"""
        <div id="readme" data-path=".github/README.md">
          <img src="https://raw.githubusercontent.com/javalin/javalin/HEAD/img/javalin.png" alt="Logo">
        </div>
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "javalin", repo: "javalin")

        #expect(result.contains("https://raw.githubusercontent.com/javalin/javalin/HEAD/.github/img/javalin.png"))
        #expect(!result.contains(#"src="https://raw.githubusercontent.com/javalin/javalin/HEAD/img/javalin.png""#))
    }

    @Test("绝对 URL 图片不重写")
    func rewrite_absoluteURL() {
        let html = #"<img src="https://example.com/logo.png" alt="logo">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("https://example.com/logo.png"))
        #expect(!result.contains("raw.githubusercontent.com"))
    }

    @Test("协议相对 // URL 不重写")
    func rewrite_protocolRelative() {
        let html = #"<img src="//avatars.githubusercontent.com/u/1234" alt="avatar">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("//avatars.githubusercontent.com"))
        #expect(!result.contains("raw.githubusercontent.com"))
    }

    @Test("data: URI 不重写")
    func rewrite_dataURI() {
        let html = #"<img src="data:image/png;base64,abc123" alt="badge">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("data:image/png;base64,abc123"))
    }

    @Test("无 owner/repo 时不重写（保守策略）")
    func rewrite_nilOwner() {
        let html = #"<img src="./logo.png" alt="logo">"#
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: nil, repo: "foo") == html)
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: nil) == html)
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "", repo: "foo") == html)
    }

    @Test("多张图片全部重写")
    func rewrite_multipleImages() {
        let html = """
        <img src="./a.png">
        <img src="./b.png">
        <img src="https://example.com/c.png">
        """
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "bob", repo: "bar")
        #expect(result.contains("raw.githubusercontent.com/bob/bar/HEAD/a.png"))
        #expect(result.contains("raw.githubusercontent.com/bob/bar/HEAD/b.png"))
        #expect(result.contains("https://example.com/c.png"))
    }

    @Test("嵌套属性 img 标签也能匹配")
    func rewrite_imgWithOtherAttrs() {
        let html = #"<img class="badge" src="./shield.svg" loading="lazy" alt="build">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "carol", repo: "baz")
        #expect(result.contains("raw.githubusercontent.com/carol/baz/HEAD/shield.svg"))
    }

    @Test("GitHub 签名视频地址改写为稳定 attachment URL")
    func rewrite_githubSignedVideoURL() {
        let html = #"""
        <video src="https://private-user-images.githubusercontent.com/123/456-3eb63328-0d64-40fd-9a84-f6d08e309d10.webm?jwt=temporary"
               data-canonical-src="https://private-user-images.githubusercontent.com/123/456-3eb63328-0d64-40fd-9a84-f6d08e309d10.webm?jwt=temporary"
               controls="controls" muted="muted">
        """#

        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        let stableURL = "https://github.com/user-attachments/assets/3eb63328-0d64-40fd-9a84-f6d08e309d10"

        #expect(result.components(separatedBy: stableURL).count == 3)
        #expect(!result.contains("private-user-images.githubusercontent.com"))
        #expect(!result.contains("jwt=temporary"))
        #expect(result.contains(#"controls="controls""#))
        #expect(result.contains(#"muted="muted""#))
    }

    @Test("无法提取 UUID 的 GitHub 视频地址保持原样")
    func rewrite_githubVideoWithoutUUIDKeepsOriginalURL() {
        let source = "https://private-user-images.githubusercontent.com/123/demo.webm?jwt=temporary"
        let html = #"<video src="\#(source)" controls="controls">"#

        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result == html)
    }

    @Test("普通 HTTPS 视频地址保持原样")
    func rewrite_externalVideoKeepsOriginalURL() {
        let html = #"<video src="https://cdn.example.com/demo.mp4" controls="controls">"#

        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result == html)
    }

    @Test("真实 README 签名图片还原稳定附件入口并保持幂等", arguments: [
        "60738984/646132383-2cd4a6ec-eb1e-4b45-8627-a76442ea3874.png",
        "507615/465824706-74ad0b4a-e086-4955-8edd-9f2cff31aee8.png",
        "507615/465824705-d4bcb7c1-42c7-4c0f-b130-1193a931f9f7.png"
    ])
    func rewrite_githubSignedImageURL(path: String) {
        // 保留现场文件路径，签名使用离线占位，避免测试依赖外网或持久化访问参数。
        let source = "https://private-user-images.githubusercontent.com/\(path)?jwt=expired&amp;other=1"
        let uuid = String(path.dropLast(4).suffix(36))
        let stableURL = "https://github.com/user-attachments/assets/\(uuid)"
        let html = #"<a href="https://example.com/details"><img data-canonical-src="\#(source)" src="\#(source)" width="900" alt="preview"></a>"#
        let expected = html.replacingOccurrences(of: source, with: stableURL)
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result == expected)
        #expect(ReadmeAssetURLRewriter.rewrite(in: result, owner: "alice", repo: "foo") == expected)
    }

    @Test("camo 回源后继续修复签名图片，且无需仓库身份")
    func rewrite_camoSignedImageWithoutRepository() {
        let source = "https://private-user-images.githubusercontent.com/507615/465824706-74ad0b4a-e086-4955-8edd-9f2cff31aee8.png?jwt=expired"
        let html = #"<img src="https://camo.githubusercontent.com/abc/def" data-canonical-src="\#(source)">"#
        let stableURL = "https://github.com/user-attachments/assets/74ad0b4a-e086-4955-8edd-9f2cff31aee8"
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: nil, repo: nil)

        #expect(result == #"<img src="\#(stableURL)" data-canonical-src="\#(stableURL)">"#)
    }

    @Test("picture 签名候选保留描述符、空白和其它绝对候选")
    func rewrite_signedPictureCandidates() {
        let source = "https://private-user-images.githubusercontent.com/507615/465824705-d4bcb7c1-42c7-4c0f-b130-1193a931f9f7.png?jwt=expired"
        let stableURL = "https://github.com/user-attachments/assets/d4bcb7c1-42c7-4c0f-b130-1193a931f9f7"
        let html = """
        <picture><source media="(prefers-color-scheme: dark)" srcset="  \(source) 1x,\thttps://example.com/large.png 2x  "><img src="https://example.com/fallback.png"></picture>
        """
        let expected = html.replacingOccurrences(of: source, with: stableURL)
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result == expected)
        #expect(ReadmeAssetURLRewriter.rewrite(in: result, owner: "alice", repo: "foo") == expected)
    }

    @Test("未知签名图片和其它主机保持原样", arguments: [
        "https://private-user-images.githubusercontent.com/123/unknown.png?jwt=expired",
        "https://private-user-images.githubusercontent.com.evil.example/123/456-74ad0b4a-e086-4955-8edd-9f2cff31aee8.png?jwt=expired",
        "https://cdn.example.com/123/456-74ad0b4a-e086-4955-8edd-9f2cff31aee8.png?jwt=expired"
    ])
    func rewrite_unknownSignedImageUnchanged(source: String) {
        let html = #"<picture><source srcset="\#(source) 1x"><img src="\#(source)"></picture><a href="\#(source)">original</a>"#
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == html)
    }

    @Test("附件修复不修改普通链接与非资源属性")
    func rewrite_signedImagePreservesOtherAttributes() {
        let source = "https://private-user-images.githubusercontent.com/507615/465824705-d4bcb7c1-42c7-4c0f-b130-1193a931f9f7.png?jwt=expired"
        let html = #"<a href="\#(source)"><img src="https://example.com/preview.png" data-src="\#(source)"></a>"#
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == html)
    }

    // MARK: - rewriteOne (单个 src)

    @Test("不带 ./ 前缀的相对路径也能正确处理")
    func rewriteOne_withoutDotSlash() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeAssetURLRewriter.rewriteOne("logo.png", rawBase: rawBase) == rawBase + "logo.png")
        #expect(ReadmeAssetURLRewriter.rewriteOne("./logo.png", rawBase: rawBase) == rawBase + "logo.png")
    }

    @Test("前导斜杠被去掉以与仓库根对齐")
    func rewriteOne_leadingSlash() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeAssetURLRewriter.rewriteOne("/logo.png", rawBase: rawBase) == rawBase + "logo.png")
    }

    @Test("GitHub 根路径 raw 图片重写为 raw.githubusercontent.com")
    func rewriteOne_githubRootRawPath() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        let src = "/javalin/javalin/raw/master/.github/img/javalin.png"
        let expected = "https://raw.githubusercontent.com/javalin/javalin/master/.github/img/javalin.png"

        #expect(ReadmeAssetURLRewriter.rewriteOne(src, rawBase: rawBase) == expected)
    }

    @Test("普通前导斜杠路径不误判为 GitHub raw 路径")
    func rewriteOne_leadingSlashWithoutRawKeepsCurrentRepoRoot() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"

        #expect(ReadmeAssetURLRewriter.rewriteOne("/javalin/javalin/logo.png", rawBase: rawBase)
            == rawBase + "javalin/javalin/logo.png")
    }

    @Test("mailto: 和 javascript: 不重写")
    func rewriteOne_mailtoJS() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeAssetURLRewriter.rewriteOne("mailto:alice@example.com", rawBase: rawBase)
            == "mailto:alice@example.com")
        #expect(ReadmeAssetURLRewriter.rewriteOne("javascript:void(0)", rawBase: rawBase)
            == "javascript:void(0)")
    }

    @Test("空白和换行被 trim")
    func rewriteOne_whitespace() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeAssetURLRewriter.rewriteOne("  ./logo.png  \n", rawBase: rawBase)
            == rawBase + "logo.png")
    }

    // MARK: - picture 图片候选地址

    @Test("diagram-design 的深浅色 Hero 与 GIF 候选地址全部重写")
    func rewrite_diagramDesignPictures() {
        // 使用实际缓存的结构：img 已修好，深浅色 source 仍为相对路径。
        let rawBase = "https://raw.githubusercontent.com/cathrynlavery/diagram-design/HEAD/"
        let html = #"""
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="docs/hero/hero-dark.webp">
          <img alt="Diagram Design" src="https://raw.githubusercontent.com/cathrynlavery/diagram-design/HEAD/docs/hero/hero-light.webp">
        </picture>
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="docs/hero/demo.gif">
          <source media="(prefers-color-scheme: light)" srcset="docs/hero/demo-light.gif">
          <img src="https://raw.githubusercontent.com/cathrynlavery/diagram-design/HEAD/docs/hero/demo.gif" width="900">
        </picture>
        """#
        let expected = html
            .replacingOccurrences(of: #"srcset="docs/"#, with: #"srcset="\#(rawBase)docs/"#)

        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "cathrynlavery", repo: "diagram-design")

        #expect(result == expected)
        #expect(ReadmeAssetURLRewriter.rewrite(in: result, owner: "cathrynlavery", repo: "diagram-design") == result)
    }

    @Test("picture 的多候选密度描述符、逗号路径与空白保持原样")
    func rewrite_pictureDensityCandidates() {
        let html = #"""
        <picture><source type="image/webp" srcset="images/small,wide.webp 1x,
          ./images/large.webp 2x, https://cdn.example.com/hero.webp?x=1&amp;y=2 3x"></picture>
        """#
        let expected = #"""
        <picture><source type="image/webp" srcset="https://raw.githubusercontent.com/alice/foo/HEAD/images/small,wide.webp 1x,
          https://raw.githubusercontent.com/alice/foo/HEAD/images/large.webp 2x, https://cdn.example.com/hero.webp?x=1&amp;y=2 3x"></picture>
        """#

        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == expected)
    }

    @Test("picture 的宽度描述符与 sizes 不变")
    func rewrite_pictureWidthCandidates() {
        let html = #"<picture><source sizes="(max-width: 600px) 100vw, 600px" srcset="small.webp 480w, large.webp 1200w"></picture>"#
        let expected = #"<picture><source sizes="(max-width: 600px) 100vw, 600px" srcset="https://raw.githubusercontent.com/alice/foo/HEAD/small.webp 480w, https://raw.githubusercontent.com/alice/foo/HEAD/large.webp 1200w"></picture>"#

        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == expected)
    }

    @Test("picture 中的 GitHub 根路径 raw 地址与无描述符候选正确重写")
    func rewrite_pictureRootRawCandidates() {
        let html = #"<picture><source srcset="/other/repo/raw/main/dark.webp, light.webp"></picture>"#
        let expected = #"<picture><source srcset="https://raw.githubusercontent.com/other/repo/main/dark.webp, https://raw.githubusercontent.com/alice/foo/HEAD/light.webp"></picture>"#

        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == expected)
    }

    @Test("picture 相对候选遵循子目录 README 且重复处理不变")
    func rewrite_pictureSubdirectoryReadme() {
        let html = #"""
        <div data-path=".github/README.md">
          <picture><source srcset="img/dark.webp?x=1&amp;y=2"></picture>
        </div>
        """#
        let expected = html.replacingOccurrences(
            of: #"srcset="img/"#,
            with: #"srcset="https://raw.githubusercontent.com/alice/foo/HEAD/.github/img/"#
        )
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result == expected)
        #expect(ReadmeAssetURLRewriter.rewrite(in: result, owner: "alice", repo: "foo") == result)
    }

    @Test("picture 中 data URI 的逗号不被误当成候选分隔符")
    func rewrite_pictureDataURICandidate() {
        let html = #"<picture><source srcset="data:image/png;base64,AAAA 1x, large.png 2x"></picture>"#
        let expected = #"<picture><source srcset="data:image/png;base64,AAAA 1x, https://raw.githubusercontent.com/alice/foo/HEAD/large.png 2x"></picture>"#

        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == expected)
    }

    @Test("picture 中绝对地址、协议相对地址与未知协议保持原样")
    func rewrite_pictureAbsoluteCandidatesUnchanged() {
        let html = #"<picture><source srcset="https://cdn.example.com/a,b.webp 1x, //cdn.example.com/b.webp 2x, blob:example 3x"></picture>"#

        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == html)
    }

    @Test("picture 中无法可靠识别的候选描述符保持原样")
    func rewrite_pictureUnknownDescriptorsUnchanged() {
        let html = #"<picture><source srcset="small.webp 1x, large.webp calc(2, 3)"></picture>"#

        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == html)
    }

    @Test("picture 外的 source、视频音频和普通链接不进入图片候选重写")
    func rewrite_pictureSourcesDoNotChangeOtherMedia() {
        let html = #"""
        <source srcset="standalone.webp">
        <video controls><source src="movie.mp4" srcset="video.webp"></video>
        <audio controls><source src="sound.mp3"></audio>
        <a href="docs/hero/demo.gif">Download</a>
        <picture><source srcset="dark.webp"></picture>
        """#
        let expected = html.replacingOccurrences(
            of: #"srcset="dark.webp""#,
            with: #"srcset="https://raw.githubusercontent.com/alice/foo/HEAD/dark.webp""#
        )

        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo") == expected)
    }

    @Test("缺少仓库身份时 picture 相对候选保持原样")
    func rewrite_pictureWithoutRepositoryUnchanged() {
        let html = #"<picture><source srcset="dark.webp"><img src="light.webp"></picture>"#

        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: nil, repo: "foo") == html)
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: nil) == html)
    }

    // MARK: - camo 代理图片回源（2026-09-18）

    @Test("camo 图片改写回 data-canonical-src 原始地址")
    func rewrite_camoImgRestoredToCanonicalSrc() {
        let html = #"""
        <img alt="badge" src="https://camo.githubusercontent.com/abc123/68747470733a2f2f696d672e736869656c64732e696f2f62616467652f746573742d626c75652e737667" data-canonical-src="https://img.shields.io/badge/test-blue.svg" style="max-width: 100%;">
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        // 断言锚定到标签开头，避免误匹配 data-canonical-src 属性里的同段子串。
        #expect(result.contains(#"<img alt="badge" src="https://img.shields.io/badge/test-blue.svg""#))
        #expect(result.contains(#"data-canonical-src="https://img.shields.io/badge/test-blue.svg""#))
        #expect(!result.contains("camo.githubusercontent.com"))
    }

    @Test("picture 内 source srcset 的 camo 地址改写回原始地址并保留转义")
    func rewrite_camoSourceSrcsetRestoredWithEscaping() {
        let html = #"""
        <source media="(prefers-color-scheme: dark)" srcset="https://camo.githubusercontent.com/def456/68747470733a2f2f686973746f72792e6578616d706c65" data-canonical-src="https://history.example.com/embed/v1/repos/a/b/star-history.svg?theme=dark&amp;locale=en">
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        // canonical 值按源 HTML 的转义形态复制，&amp; 不做二次编解码。
        #expect(result.contains(#"srcset="https://history.example.com/embed/v1/repos/a/b/star-history.svg?theme=dark&amp;locale=en""#))
        #expect(!result.contains("camo.githubusercontent.com"))
    }

    @Test("camo 改写不依赖 owner/repo（保守短路之前执行）")
    func rewrite_camoRestoredEvenWithoutOwner() {
        let html = #"<img src="https://camo.githubusercontent.com/abc123/68747470" data-canonical-src="https://example.com/a.png">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: nil, repo: nil)

        // 整串等值断言，杜绝 src= 命中 data-canonical-src 子串的假阳性。
        #expect(result == #"<img src="https://example.com/a.png" data-canonical-src="https://example.com/a.png">"#)
    }

    @Test("无 data-canonical-src 的 camo 图片保持原样")
    func rewrite_camoWithoutCanonicalUnchanged() {
        let html = #"""
        <img src="https://camo.githubusercontent.com/abc123/68747470" alt="x">
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result.contains("camo.githubusercontent.com"))
    }

    @Test("data-canonical-src 非 http(s) 绝对地址不改写")
    func rewrite_camoWithNonHTTPCanonicalUnchanged() {
        let html = #"""
        <img src="https://camo.githubusercontent.com/abc123/68747470" data-canonical-src="javascript:void(0)">
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result.contains(#"src="https://camo.githubusercontent.com/abc123"#))
    }

    @Test("多候选 srcset 不改写")
    func rewrite_camoSrcsetWithDescriptorsUnchanged() {
        let html = #"""
        <source srcset="https://camo.githubusercontent.com/abc123/68747470 1x, https://camo.githubusercontent.com/def456/68747471 2x" data-canonical-src="https://example.com/a.png">
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result.contains("camo.githubusercontent.com"))
    }

    @Test("非 camo 的绝对地址图片不受影响")
    func rewrite_nonCamoAbsoluteImgUntouched() {
        let html = #"""
        <img src="https://example.com/logo.png" data-canonical-src="https://other.example.com/logo.png">
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result.contains(#"src="https://example.com/logo.png""#))
    }

    @Test("picture 内 img 与 source 同时命中时都改写")
    func rewrite_camoPictureImgAndSourceBothRestored() {
        let html = #"""
        <picture data-starcat-star-history>
          <source media="(prefers-color-scheme: dark)" srcset="https://camo.githubusercontent.com/h1/6871" data-canonical-src="https://history.example.com/dark.svg">
          <img alt="history" src="https://camo.githubusercontent.com/h2/6872" data-canonical-src="https://history.example.com/light.svg">
        </picture>
        """#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")

        #expect(result.contains(#"srcset="https://history.example.com/dark.svg""#))
        #expect(result.contains(#"<img alt="history" src="https://history.example.com/light.svg""#))
        #expect(!result.contains("camo.githubusercontent.com"))
        #expect(result.contains(#"data-starcat-star-history"#))
    }
}
