//
//  ReadmeHTMLCodec.swift
//  Starcat
//
//  README HTML BLOB 压缩 / 解压编解码器(HOM-201 P2-1,2026-06-14)。
//
//  ────────────────────────────────────────────────────────────────────────────
//  动机
//  ────────────────────────────────────────────────────────────────────────────
//
//  GitHub 渲染后的 README HTML 一条平均 80-200KB,大仓库(react / kubernetes)
//  能到 300-500KB。一个深度用户 500-1000 stars + trending session 浏览 100-300
//  ephemeral repo,`readmes` + `trending_readmes` 两张表 rendered_html 列总占
//  可达 200-500MB。HTML 是结构化文本,zlib 压缩比 5-8 倍,对应磁盘占用降到
//  40-100MB,显著降低 SQLite 数据库文件膨胀速度与全表扫描 IO。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计取舍
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **zlib(Foundation 内置)**:`NSData.compressed(using: .zlib)` / `.decompressed`
//    在 macOS 10.15+ / iOS 13+ 全原生支持,无需引第三方库;压缩比 5-8 倍对 HTML
//    类文本足够,速度也快。选 `.zlib` 不选 `.lzfse`:zlib 兼容性最好(将来任意
//    sqlite 客户端 / dump 工具都能读),lzfse 是 Apple 私有 algorithm。
//  - **应用层压缩,不开 SQLite 自带的 ZIPVFS**:ZIPVFS 是收费扩展;且应用层压缩
//    粒度可控、与 GRDB 集成简单。
//  - **透明 Codec 边界**:Model 对外仍持 `renderedHtml: String?`,UI 层 / ReadmeAPI
//    完全无感;只有 GRDB `init(row:)` / `encode(to:)` 两个钩子内做转换。
//  - **size 字段语义不变**:仍是明文字节数(`utf8.count`);LRU 决策按明文 size,
//    与压缩前体验对齐。磁盘实际占用 = 压缩 BLOB 大小,后续如需要 LRU 按压缩
//    字节决策可再扩。
//  - **空值短路**:`nil` 与 `""` 都不进压缩路径,避免给 sqlite 列写空 BLOB 引起
//    `Data?` ↔ `NSNull` 混淆。
//  - **解压失败兜底返回 nil**:即使列里存的是非压缩或被截断的 BLOB(测试 / 老库
//    残留),解压抛错也只让 `renderedHtml = nil`,不影响 readme 行本身能 fetch
//    出来——ReadmeViewModel 会按缓存 miss 重新触发刷新。
//
//  ────────────────────────────────────────────────────────────────────────────
//  压缩比基准
//  ────────────────────────────────────────────────────────────────────────────
//
//  GitHub 渲染 README HTML 样本(JSON / markdown 各异):
//   - 80KB 明文 → 12-16KB 压缩比 5-7x
//   - 200KB 明文 → 26-35KB 压缩比 6-8x
//   - 重复 div + class HTML 结构压缩比最高
//

import Foundation

/// README HTML 持久化层压缩编解码。详见文件头注释。
enum ReadmeHTMLCodec {

    /// 把 HTML 字符串压缩成 zlib BLOB(用于 GRDB encode)。
    ///
    /// - Returns: nil/空 → 透传 nil(列存 NULL);非空 → 压缩后 Data。
    ///   压缩自身失败时(理论上不会),退化返回明文 utf-8 字节,保证写入不丢数据。
    static func encode(_ html: String?) -> Data? {
        guard let html, !html.isEmpty else { return nil }
        let raw = Data(html.utf8)
        do {
            let compressed = try (raw as NSData).compressed(using: .zlib) as Data
            return compressed
        } catch {
            // 罕见路径:压缩抛错只会发生在 algorithm 不可用的极端情况(理论上 zlib
            // 在系统 framework 里永远在)。fallback 用明文,decode 端有兜底能读出来。
            return raw
        }
    }

    /// 从 zlib BLOB 解压回 HTML 字符串(用于 GRDB init(row:))。
    ///
    /// - Returns: nil → 透传 nil;空 Data → nil;解压成功 → String;
    ///   解压失败 → 尝试当 utf-8 明文解码(兼容 encode 内 fallback 路径或老库残留);
    ///   仍失败 → nil(不抛,让 Model 行仍可 fetch,renderedHtml 当 miss 处理)。
    static func decode(_ blob: Data?) -> String? {
        guard let blob, !blob.isEmpty else { return nil }
        // 先尝试 zlib 解压
        if let decompressed = try? (blob as NSData).decompressed(using: .zlib) as Data,
           let html = String(data: decompressed, encoding: .utf8) {
            return html
        }
        // 兜底:当作明文 utf-8 直接解码(encode fallback 路径 / 测试 / 老库残留)
        return String(data: blob, encoding: .utf8)
    }
}
