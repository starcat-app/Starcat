//
//  ReleaseBuildArtifact.swift
//  Starcat
//
//  GitHub 附件没有结构化的目标平台字段。只把文件名中明确的证据用于筛选和推荐。
//

import Foundation

struct ReleaseBuildArtifact: Identifiable {
    enum Platform: String, CaseIterable {
        case mac = "macOS", windows = "Windows", linux = "Linux", android = "Android", ios = "iOS"
    }
    enum Architecture: String, CaseIterable {
        case arm64, intel = "x86_64", universal = "Universal", x86, armv7
    }

    let asset: ReleaseAsset
    let platform: Platform?
    let architecture: Architecture?
    private let isMacPackage: Bool
    var id: Int64 { asset.id }

    /// 匹配完整 token，避免 Darwin 命中 win、校验文件或跨平台压缩包被误作本机安装包。
    init(_ asset: ReleaseAsset) {
        self.asset = asset
        let name = asset.name.lowercased()
        let normalized = name.replacingOccurrences(of: "x86_64", with: "amd64")
            .replacingOccurrences(of: "x86-64", with: "amd64")
        let tokens = Set(normalized.components(separatedBy: CharacterSet.alphanumerics.inverted))
        func has(_ markers: String...) -> Bool { !tokens.isDisjoint(with: markers) }
        func ends(_ suffixes: String...) -> Bool { suffixes.contains { name.hasSuffix($0) } }
        let platforms: [Platform] = [
            has("macos", "mac", "darwin", "osx", "dmg", "pkg") ? .mac : nil,
            has("windows", "win", "win32", "win64", "exe", "msi", "msix") ? .windows : nil,
            has("linux", "ubuntu", "debian", "fedora", "appimage", "deb", "rpm") ? .linux : nil,
            has("android", "apk", "aab") ? .android : nil,
            has("ios", "iphoneos", "ipa") ? .ios : nil
        ].compactMap { $0 }
        platform = platforms.count == 1 ? platforms.first : nil
        let architectures: [Architecture] = [
            has("arm64", "aarch64") ? .arm64 : nil,
            has("amd64", "x64") ? .intel : nil,
            has("universal", "universal2") ? .universal : nil,
            has("i386", "i686", "x86") ? .x86 : nil,
            has("armv7", "armv7l", "armhf") ? .armv7 : nil
        ].compactMap { $0 }
        architecture = architectures.count == 1 ? architectures.first : nil
        isMacPackage = ends(".dmg", ".pkg", ".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar.zst") &&
            !has("dsym", "debug", "symbols", "source", "sources", "checksums", "checksum", "blockmap", "sig")
    }

    func isRecommended(for machine: Architecture) -> Bool {
        platform == .mac && isMacPackage && (architecture == machine || architecture == .universal)
    }
}

/// 所有条件取交集；识别不出的构件仍保留在「全部」以及文件名 / MIME 搜索结果中。
struct ReleaseArtifactFilter: Equatable {
    var query = ""
    var platform: ReleaseBuildArtifact.Platform?
    var architecture: ReleaseBuildArtifact.Architecture?

    func matches(_ build: ReleaseBuildArtifact) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (platform == nil || platform == build.platform) &&
            (architecture == nil || architecture == build.architecture) &&
            (needle.isEmpty || build.asset.name.localizedCaseInsensitiveContains(needle) ||
                build.asset.contentType?.localizedCaseInsensitiveContains(needle) == true)
    }
}
