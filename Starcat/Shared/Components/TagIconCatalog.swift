//
//  TagIconCatalog.swift
//  Starcat
//
//  读取构建时生成的本地图标索引，并解析与标签数据一起保存的标识。
//

import AppKit
import Foundation

/// 标签图标索引只包含可供点选的素材，避免把 App 的内部图片暴露给标签。
enum TagIconCatalog {
    enum Source: String, CaseIterable, Decodable {
        case lucide
        case devicon
        case skillAgent
        case aiProvider
    }

    struct Entry: Decodable, Identifiable {
        let assetName: String
        let name: String
        let source: Source
        let isTemplateAsset: Bool

        var id: String { TagIconCatalog.assetPrefix + assetName }

        /// 部分服务商的纯白 SVG 由现有 Provider 规则标记，浅色主题也需要套用模板色。
        var isTemplate: Bool {
            isTemplateAsset || (source == .aiProvider && TagIconCatalog.monochromeProviderAssets.contains(assetName))
        }

        @MainActor
        var image: NSImage? { Bundle.main.image(forResource: NSImage.Name(assetName)) }
    }

    private static let assetPrefix = "asset:"
    private static let monochromeProviderAssets = Set(
        AIServiceProvider.allCases.filter(\.iconIsMonochromeWhite).map(\.iconAssetName)
    )

    static let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "TagIconCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }()

    private static let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    static func entry(for identifier: String) -> Entry? {
        entriesByID[identifier]
    }

    /// 素材不可用时回退到展示面的默认符号，已有 SF Symbol 名可直接回读。
    static func systemName(for identifier: String, fallback: String) -> String {
        identifier.hasPrefix(assetPrefix) ? fallback : identifier
    }

    /// 同时匹配素材原名与 Lucide 在 Starcat 中的用途名称。
    static func matching(_ query: String) -> [Entry] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) || $0.assetName.localizedCaseInsensitiveContains(keyword)
        }
    }
}
