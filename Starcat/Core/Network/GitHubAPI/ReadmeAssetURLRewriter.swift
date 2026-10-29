//
//  ReadmeAssetURLRewriter.swift
//  Starcat
//
//  README HTML 内图片与视频资源地址重写工具。
//
//  ────────────────────────────────────────────────────────────────────────────
//  从渲染层迁移到 IO 层
//  ────────────────────────────────────────────────────────────────────────────
//
//  以前这段正则替换逻辑住在 `ReadmeWebView`（UI 层），每次列表切换 repo 触发
//  `loadIfNeeded` 都会扫描整段 HTML 跑一次 NSRegularExpression —— 几百 KB 的大
//  README（react 这种）在 8KB+ 字符串上跑全文匹配，每切一次都重新算，浪费
//  且明显延迟首帧。
//
//  本类把同一份逻辑提到 `ReadmeAPI` 在 200 / promote 路径 upsert **之前**调用,
//  rewrite 后的 HTML 直接落到 `readmes.rendered_html` / `trending_readmes.rendered_html`
//  里：
//  - 每条记录只跑一次正则,且发生在 IO 线程而非渲染线程；
//  - 后续详情页切换该 repo 时直接拿"已 rewrite 完成"的 HTML 喂 WKWebView，
//    渲染层不再 rewrite；
//  - 一次性、单向（不会有"先存 raw 再渲染时 rewrite"的不一致风险）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  camo 回源策略（2026-09-18 新增，先于其它规则执行）
//  ────────────────────────────────────────────────────────────────────────────
//
//  - GitHub 会把 README 里所有外链 <img src> / <source srcset> 换成
//    camo.githubusercontent.com 代理地址，原始 URL 保留在 data-canonical-src；
//  - App 的 WebKit 网络栈访问 camo 会间歇性失败（详见 rewriteCamoProxiedImages
//    注释），因此改写回 data-canonical-src 原始地址，绕开 camo 跳数；
//  - 该规则与 owner/repo 无关，在「owner/repo 缺失」保守短路之前执行。
//
//  ────────────────────────────────────────────────────────────────────────────
//  图片策略
//  ────────────────────────────────────────────────────────────────────────────
//
//  触发原因：GitHub HTML render 端点对原生 HTML `<img>` 不做 URL 重写，
//  用 `repo.htmlUrl` 作 baseURL 时 `./logo.PNG` 会被浏览器解析为
//  `https://github.com/owner/logo.PNG` → 404。
//
//  - 完整 URL（http(s):// / data: / 协议相对 //） → 除 GitHub 签名附件外不动
//  - GitHub 站点根路径 raw 图片（`/{owner}/{repo}/raw/{ref}/{path}`）
//    → 改写为 `https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}`
//  - 其余视作相对路径 → 拼到 README 文件所在目录对应的 raw URL：
//    `https://raw.githubusercontent.com/{owner}/{repo}/HEAD/{readmeDir}/`
//    - HEAD 自动指向 default branch，无需额外查询 default branch
//    - GitHub HTML 外层 `data-path=".github/README.md"` 表示本文档位于 `.github/`
//      目录，`img/logo.png` 必须解析到 `.github/img/logo.png`，不能按仓库根拼接
//  - `<picture>` 内 `<source srcset>` 的相对候选复用上述地址规则；仅替换 URL，
//    保留 media / type / sizes、候选描述符与原始空白，不触碰其它媒体的 source
//  - owner/repo 缺失 → 相对路径原样返回（保守，宁可坏图不要错重写）
//
//  附件策略（视频 GitHub Issue #107；2026-10-29 补齐图片）：
//  - GitHub 上传的图片与视频会被 HTML API 渲染为短时效签名 URL；
//  - `rendered_html` 的缓存寿命远长于签名 URL，直接落库会导致视频很快失效；
//  - 从 `private-user-images.githubusercontent.com` path 提取 attachment UUID，改写为
//    `https://github.com/user-attachments/assets/<UUID>`，由 GitHub 在加载时生成新重定向；
//  - UUID 无法可靠提取时保持原样，避免把第三方或未知地址误改坏。
//
//  正则只匹配双引号包裹的属性（GitHub render 出来稳定用双引号），不引入新依赖
//  （SwiftSoup 等）以保留 zero-dep 边界。签名 URL 不写日志，避免泄露临时访问参数。
//

import Foundation

/// README HTML 图片与视频资源地址重写工具。详见文件头注释。
enum ReadmeAssetURLRewriter {

    /// GitHub camo 代理图片的稳定前缀。
    private static let camoImageProxyRoot = "https://camo.githubusercontent.com/"

    /// 规范化 README HTML 中的图片与视频资源地址。
    ///
    /// 详见文件头 `策略` 节。
    ///
    /// - Parameters:
    ///   - html: GitHub `Accept: application/vnd.github.html` 返回的 HTML 片段
    ///   - owner: 仓库 owner（缺失 / 空字符串则不重写相对路径）
    ///   - repo: 仓库 name（缺失 / 空字符串则不重写相对路径）
    /// - Returns: 重写后的 HTML；没有命中资源规则时返回原字符串
    static func rewrite(in html: String, owner: String?, repo: String?) -> String {
        // camo 回源后再规范化签名附件，避免 canonical 本身就是会过期的临时地址。
        // 两者均不依赖仓库身份；缺失身份时仍能修复旧缓存，不猜测相对路径。
        let camoRewritten = rewriteCamoProxiedImages(in: html)
        let attachmentRewritten = rewriteGitHubAttachmentSources(in: camoRewritten)
        guard let owner, let repo, !owner.isEmpty, !repo.isEmpty else { return attachmentRewritten }
        let rawRoot = "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/"
        let documentDirectory = readmeDocumentDirectory(from: attachmentRewritten)
        let rawBase = rawRoot + documentDirectory

        let imageRewritten = rewriteImageSources(
            in: attachmentRewritten,
            rawBase: rawBase,
            rawRoot: rawRoot,
            documentDirectory: documentDirectory
        )
        return rewritePictureSourceSets(
            in: imageRewritten,
            rawBase: rawBase,
            rawRoot: rawRoot,
            documentDirectory: documentDirectory
        )
    }

    /// 把 GitHub camo 代理的 `<img src>` / `<source srcset>` 改写回 `data-canonical-src`
    /// 保留的原始地址。
    ///
    /// 触发原因（2026-09-18 无 GUI WKWebView 探针实测）：App 的 WebKit 网络栈访问
    /// camo.githubusercontent.com 会间歇性失败（首载约 1/3，推测 HTTP/3/QUIC 走 UDP
    /// 被 Surge / GFW 干扰；同机 curl 直连与走代理均 20/20 全通），README 内的外链
    /// 图片（徽章、star-history 卡片）在 App 内随机裂图；而原始地址（shields.io、
    /// 自托管 history.starcat.ink 等）在 WebKit 里直连稳定。GitHub 渲染 HTML 时在
    /// camo 图片上保留了 data-canonical-src，因此改回原始地址以绕开 camo 跳数。
    ///
    /// 边界（全部命中才改写）：
    /// - 标签是 `<img>` 或 `<source>`，`src` / `srcset` 指向 camo 前缀；
    /// - 同标签携带 `data-canonical-src`，且值为 http(s) 绝对地址（按不可信输入
    ///   校验，防止相对路径或 javascript: 一类怪值进入 src）；
    /// - `srcset` 含多候选（逗号分隔）不改写，整体替换描述符列表容易破坏语义；
    /// - `data-canonical-src` 属性原值保留（README 星标历史的内嵌检测依赖它）；
    ///   替换直接复制源 HTML 里已转义的属性值（&amp; 等），不做二次编解码。
    private static func rewriteCamoProxiedImages(in html: String) -> String {
        let tagPattern = #"<(img|source)\b[^>]*>"#
        guard let tagRegex = try? NSRegularExpression(
            pattern: tagPattern,
            options: [.caseInsensitive]
        ) else {
            return html
        }

        let nsHtml = html as NSString
        let matches = tagRegex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            let tag = nsHtml.substring(with: match.range)
            guard let rewrittenTag = rewriteCamoAttributes(inTag: tag),
                  rewrittenTag != tag,
                  let range = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(range, with: rewrittenTag)
        }
        return result
    }

    /// 单个 `<img>` / `<source>` 标签内的 camo 属性改写；无命中返回 nil。
    private static func rewriteCamoAttributes(inTag tag: String) -> String? {
        guard let canonical = attributeValue(named: "data-canonical-src", inTag: tag)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let canonicalURL = URL(string: canonical),
              let scheme = canonicalURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        var working = tag
        var changed = false
        for attribute in ["src", "srcset"] {
            guard let value = attributeValue(named: attribute, inTag: working)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  value.lowercased().hasPrefix(camoImageProxyRoot),
                  !value.contains(",")
            else { continue }
            working = replaceAttributeValue(named: attribute, inTag: working, with: canonical)
            changed = true
        }
        return changed ? working : nil
    }

    /// 从标签字符串中提取指定属性的原始值（保留 HTML 转义形态）。
    ///
    /// 只匹配双引号包裹的属性（GitHub 渲染输出稳定用双引号），与既有视频改写约定一致。
    /// 属性名前置 `(?<=\s)` 断言而不是 `\b`：`data-canonical-src` 的尾部同样满足
    /// `\bsrc`，属性顺序不保证时会取错值；标签内属性名必然由空白分隔。
    ///
    /// 注意模式字符串用原始字符串书写：正则的 `\s` 在 `#"..."#` 里就是单反斜杠，
    /// 误写成 `\\s` 会变成「字面反斜杠 + s」导致永远不匹配（已踩过）。
    private static func attributeValue(named name: String, inTag tag: String) -> String? {
        let pattern = #"(?<=\s)"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsTag = tag as NSString
        guard let match = regex.firstMatch(
            in: tag,
            options: [],
            range: NSRange(location: 0, length: nsTag.length)
        ) else { return nil }
        return nsTag.substring(with: match.range(at: 1))
    }

    /// 把标签内指定属性的值替换为新值（按匹配区间做字符串手术，不走正则模板，
    /// 避免属性值里的 `$` / `\` 被当作模板占位符解释）。
    private static func replaceAttributeValue(named name: String, inTag tag: String, with value: String) -> String {
        let pattern = #"((?<=\s)"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*")([^"]+)(")"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return tag
        }
        let nsTag = tag as NSString
        guard let match = regex.firstMatch(
            in: tag,
            options: [],
            range: NSRange(location: 0, length: nsTag.length)
        ),
              let valueRange = Range(match.range(at: 2), in: tag)
        else { return tag }
        return tag.replacingCharacters(in: valueRange, with: value)
    }

    /// 图片规则沿用既有实现，单独收口后让视频规范化不会改变图片匹配边界。
    private static func rewriteImageSources(
        in html: String,
        rawBase: String,
        rawRoot: String,
        documentDirectory: String
    ) -> String {
        // <img ...src="xxx"...> ；捕获 1 = src 前的属性串，捕获 2 = src 值
        let pattern = #"<img\b([^>]*?)\bsrc\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let nsHtml = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for m in matches {
            let unchanged = NSRange(location: cursor, length: m.range.location - cursor)
            result += nsHtml.substring(with: unchanged)

            let prefix = nsHtml.substring(with: m.range(at: 1))
            let originalSrc = nsHtml.substring(with: m.range(at: 2))
            let rewritten = rewriteOne(
                originalSrc,
                rawBase: rawBase,
                rawRoot: rawRoot,
                documentDirectory: documentDirectory
            )
            result += "<img\(prefix)src=\"\(rewritten)\""

            cursor = m.range.location + m.range.length
        }
        result += nsHtml.substring(from: cursor)
        return result
    }

    /// 只补齐 picture 图片候选，不让同名 source 标签把视频 / 音频带入图片地址规则。
    ///
    /// 深浅色 picture 会优先使用 source，即使 img.src 已是正确直链，漏改 source
    /// 仍会裂图。按文档逆序替换标签，避免前面的字符串长度变化使后续匹配区间失效。
    private static func rewritePictureSourceSets(
        in html: String,
        rawBase: String,
        rawRoot: String,
        documentDirectory: String
    ) -> String {
        guard let pictureRegex = try? NSRegularExpression(
            pattern: #"<picture\b[^>]*>.*?</picture\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
              let sourceRegex = try? NSRegularExpression(
                pattern: #"<source\b[^>]*>"#,
                options: [.caseInsensitive]
              )
        else { return html }

        let nsHtml = html as NSString
        let pictures = pictureRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
        var result = html
        for picture in pictures.reversed() {
            for source in sourceRegex.matches(in: html, range: picture.range).reversed() {
                let tag = nsHtml.substring(with: source.range)
                guard let srcset = attributeValue(named: "srcset", inTag: tag) else { continue }
                let rewritten = rewritePictureSourceSet(
                    srcset,
                    rawBase: rawBase,
                    rawRoot: rawRoot,
                    documentDirectory: documentDirectory
                )
                guard rewritten != srcset, let range = Range(source.range, in: result) else { continue }
                result.replaceSubrange(range, with: replaceAttributeValue(named: "srcset", inTag: tag, with: rewritten))
            }
        }
        return result
    }

    /// 按 URL token 与描述符读取 srcset，仅替换相对 URL 与 GitHub 签名附件的字符区间。
    ///
    /// 不能直接 split(",")：data URI 和普通 URL 路径也能含逗号。URL 先读到 ASCII
    /// 空白，尾逗号才结束无描述符候选；否则读取后面的 1x / 480w 等描述符。
    /// 不认识的描述符保留整串，避免只修好前半段却破坏候选选择。绝对 URL 不补目录，
    /// 使缓存每次读取重跑此函数仍保持幂等；HTML 的 &amp; 等转义直接按原字符保留。
    private static func rewritePictureSourceSet(
        _ srcset: String,
        rawBase: String,
        rawRoot: String,
        documentDirectory: String
    ) -> String {
        let whitespace: Set<Character> = [" ", "\t", "\n", "\r", "\u{0C}"]
        var cursor = srcset.startIndex
        var replacements: [(Range<String.Index>, String)] = []

        while cursor < srcset.endIndex {
            while cursor < srcset.endIndex, whitespace.contains(srcset[cursor]) || srcset[cursor] == "," {
                cursor = srcset.index(after: cursor)
            }
            guard cursor < srcset.endIndex else { break }

            let urlStart = cursor
            while cursor < srcset.endIndex, !whitespace.contains(srcset[cursor]) {
                cursor = srcset.index(after: cursor)
            }
            var urlEnd = cursor
            while urlEnd > urlStart, srcset[srcset.index(before: urlEnd)] == "," {
                urlEnd = srcset.index(before: urlEnd)
            }
            if urlEnd == cursor {
                let descriptorStart = cursor
                while cursor < srcset.endIndex, srcset[cursor] != "," {
                    cursor = srcset.index(after: cursor)
                }
                let descriptor = srcset[descriptorStart..<cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                if !descriptor.isEmpty {
                    if descriptor.hasSuffix("w"), let width = Int(descriptor.dropLast()), width > 0 {
                        // 宽度描述符保留原文，仅校验其属于可安全处理的单候选形式。
                    } else if descriptor.hasSuffix("x"),
                              let density = Double(descriptor.dropLast()), density.isFinite, density >= 0 {
                        // 密度描述符与原候选绑定，不参与 URL 拼接。
                    } else {
                        return srcset
                    }
                }
            }

            let url = String(srcset[urlStart..<urlEnd])
            // 签名候选也是绝对地址，必须先于「绝对地址不补目录」的短路处理。
            if let stableURL = stableGitHubAttachmentURL(from: url) {
                replacements.append((urlStart..<urlEnd, stableURL))
                continue
            }
            guard !url.isEmpty, !url.hasPrefix("//"), !url.hasPrefix("#"),
                  URL(string: url)?.scheme == nil
            else { continue }
            let rewritten = rewriteOne(
                url,
                rawBase: rawBase,
                rawRoot: rawRoot,
                documentDirectory: documentDirectory
            )
            if rewritten != url {
                replacements.append((urlStart..<urlEnd, rewritten))
            }
        }

        var result = srcset
        for (range, url) in replacements.reversed() {
            result.replaceSubrange(range, with: url)
        }
        return result
    }

    /// 把 GitHub HTML API 生成的短时效图片与视频地址改成稳定 attachment URL。
    ///
    /// 同时处理 `src` 与 `data-canonical-src`，避免旧签名继续残留在落库 HTML 中。
    /// 只扫描 img / video 资源属性，不触碰 iframe、object 或普通链接。
    private static func rewriteGitHubAttachmentSources(in html: String) -> String {
        let tagPattern = #"<(?:img|video)\b[^>]*>"#
        guard let tagRegex = try? NSRegularExpression(
            pattern: tagPattern,
            options: [.caseInsensitive]
        ) else {
            return html
        }

        let nsHtml = html as NSString
        let matches = tagRegex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            let tag = nsHtml.substring(with: match.range)
            let rewrittenTag = rewriteAttachmentSourceAttributes(in: tag)
            guard rewrittenTag != tag,
                  let range = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(range, with: rewrittenTag)
        }
        return result
    }

    /// 只替换资源属性值，保留尺寸、替代文本和媒体控制属性；不能误匹配 data-src 等属性。
    private static func rewriteAttachmentSourceAttributes(in tag: String) -> String {
        let attributePattern = #"(?<=\s)(data-canonical-src|src)\s*=\s*"([^"]+)""#
        guard let attributeRegex = try? NSRegularExpression(
            pattern: attributePattern,
            options: [.caseInsensitive]
        ) else {
            return tag
        }

        let nsTag = tag as NSString
        let matches = attributeRegex.matches(
            in: tag,
            options: [],
            range: NSRange(location: 0, length: nsTag.length)
        )
        guard !matches.isEmpty else { return tag }

        var result = tag
        for match in matches.reversed() {
            let sourceRange = match.range(at: 2)
            let source = nsTag.substring(with: sourceRange)
            guard let stableURL = stableGitHubAttachmentURL(from: source),
                  let range = Range(sourceRange, in: result)
            else { continue }
            result.replaceSubrange(range, with: stableURL)
        }
        return result
    }

    /// GitHub 的签名附件 path 会保留原 UUID；只在 host 与 UUID 都准确时重写。
    private static func stableGitHubAttachmentURL(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host?.lowercased() == "private-user-images.githubusercontent.com"
        else { return nil }

        let fileName = url.deletingPathExtension().lastPathComponent
        let uuidPattern = #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#
        guard let uuidRegex = try? NSRegularExpression(
            pattern: uuidPattern,
            options: [.caseInsensitive]
        ) else { return nil }

        let nsFileName = fileName as NSString
        let searchRange = NSRange(location: 0, length: nsFileName.length)
        guard let match = uuidRegex.firstMatch(in: fileName, options: [], range: searchRange),
              let matchRange = Range(match.range(at: 1), in: fileName),
              let uuid = UUID(uuidString: String(fileName[matchRange]))
        else { return nil }

        return "https://github.com/user-attachments/assets/\(uuid.uuidString.lowercased())"
    }

    /// 单个 `src` 的重写策略：
    /// - 绝对/协议相对/data URI/mailto/javascript 一律放过；
    /// - GitHub 站点根路径 raw 图片改写为 raw.githubusercontent.com；
    /// - 其余视为相对路径，去掉前导 `./` 与 `/`，拼到 `rawBase`。
    ///
    /// 暴露为 `internal` 是为了单测能精确覆盖各种边界 src。
    static func rewriteOne(_ src: String, rawBase: String) -> String {
        rewriteOne(src, rawBase: rawBase, rawRoot: rawBase, documentDirectory: "")
    }

    /// 单个 `src` 的重写策略（带 README 文档目录上下文）。
    ///
    /// `data-path=".github/README.md"` 这类 GitHub HTML wrapper 表明图片相对路径应以
    /// README 所在目录为基准，而不是仓库根目录。旧版本已经把这类路径错误落库为
    /// `.../HEAD/img/foo.png`，所以这里也会在同仓库 `HEAD/` raw URL 上做一次定向修复。
    static func rewriteOne(
        _ src: String,
        rawBase: String,
        rawRoot: String,
        documentDirectory: String
    ) -> String {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix(rawRoot.lowercased()),
           !documentDirectory.isEmpty,
           let repaired = repairSameRepoHeadRawURL(
            trimmed,
            rawRoot: rawRoot,
            documentDirectory: documentDirectory
           ) {
            return repaired
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("//") || lower.hasPrefix("data:")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("javascript:") {
            return trimmed
        }
        if let githubRawURL = githubRootRawURL(from: trimmed) {
            return githubRawURL
        }
        var clean = Substring(trimmed)
        if clean.hasPrefix("./") { clean = clean.dropFirst(2) }
        while clean.hasPrefix("/") { clean = clean.dropFirst() }
        return rawBase + String(clean)
    }

    /// 从 GitHub HTML wrapper 的 `data-path` 推导 README 所在目录。
    ///
    /// GitHub 仓库主页可能展示 `.github/README.md` 作为 overview README。HTML render
    /// 输出会带 `data-path=".github/README.md"`，其内部 `<img src="img/logo.png">`
    /// 是相对 `.github/` 的。如果忽略该目录直接拼仓库根，会得到 404 的 raw URL。
    private static func readmeDocumentDirectory(from html: String) -> String {
        let pattern = #"data-path\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return ""
        }
        let nsHtml = html as NSString
        let searchRange = NSRange(location: 0, length: min(nsHtml.length, 4096))
        guard let match = regex.firstMatch(in: html, options: [], range: searchRange) else {
            return ""
        }
        let path = nsHtml.substring(with: match.range(at: 1))
        guard let slashIndex = path.lastIndex(of: "/") else { return "" }
        let directory = path[..<path.index(after: slashIndex)]
        return sanitizeRelativeDirectory(String(directory))
    }

    /// 只保留安全的仓库内相对目录，避免 HTML 异常值影响 raw URL 拼接。
    private static func sanitizeRelativeDirectory(_ directory: String) -> String {
        var clean = Substring(directory.trimmingCharacters(in: .whitespacesAndNewlines))
        while clean.hasPrefix("./") { clean = clean.dropFirst(2) }
        while clean.hasPrefix("/") { clean = clean.dropFirst() }
        guard !clean.contains("..") else { return "" }
        return clean.isEmpty || clean.hasSuffix("/") ? String(clean) : String(clean) + "/"
    }

    /// 修复旧缓存中已经被错误改写过的同仓库 raw HEAD URL。
    ///
    /// 旧逻辑把 `.github/README.md` 内的 `img/javalin.png` 写成
    /// `.../HEAD/img/javalin.png`。这种 URL 看起来是绝对 URL，普通 rewrite 会跳过；
    /// 这里仅在 HTML 明确声明 README 位于子目录时，把缺失的目录补回去。
    private static func repairSameRepoHeadRawURL(
        _ src: String,
        rawRoot: String,
        documentDirectory: String
    ) -> String? {
        guard src.hasPrefix(rawRoot), !documentDirectory.isEmpty else { return nil }
        let relativePath = String(src.dropFirst(rawRoot.count))
        guard !relativePath.isEmpty, !relativePath.hasPrefix(documentDirectory) else { return nil }
        return rawRoot + documentDirectory + relativePath
    }

    /// 识别 GitHub HTML 渲染结果里常见的站点根路径 raw 图片。
    ///
    /// 这种 URL 看起来像相对路径，但语义是 GitHub 站点路径：
    /// `/javalin/javalin/raw/master/.github/img/javalin.png`。如果继续按仓库根相对路径拼接，
    /// 会得到错误的 `.../HEAD/javalin/javalin/raw/master/...`，WebView 只能显示坏图占位。
    private static func githubRootRawURL(from src: String) -> String? {
        guard src.hasPrefix("/") else { return nil }

        let parts = src.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2].lowercased() == "raw" else { return nil }

        let owner = parts[0]
        let repo = parts[1]
        let ref = parts[3]
        let path = parts.dropFirst(4).joined(separator: "/")
        guard !owner.isEmpty, !repo.isEmpty, !ref.isEmpty, !path.isEmpty else { return nil }

        return "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(path)"
    }
}
