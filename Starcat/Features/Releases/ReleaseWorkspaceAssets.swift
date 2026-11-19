//
//  ReleaseWorkspaceAssets.swift
//  Starcat
//
//  当前版本的构建产物浏览器：组合筛选、本机匹配分组和真正的文件下载入口。
//

import SwiftUI

struct ReleaseWorkspaceAssets: View {
    let assets: [ReleaseAsset]
    @Binding var filter: ReleaseArtifactFilter
    let downloads: ReleaseWorkspaceDownloads
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        if assets.isEmpty {
            EmptyStateView(systemImage: "shippingbox", title: "releases.workspace.noAssets")
        } else {
            VStack(spacing: 0) {
                controls.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                let builds = assets.map(ReleaseBuildArtifact.init).filter(filter.matches)
                if builds.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "releases.row.noMatchingAsset") {
                        Button("ai.usage.empty.clearFilters") { filter = ReleaseArtifactFilter() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let machine: ReleaseBuildArtifact.Architecture = LocalAIHardwareSupport.isAppleSilicon ? .arm64 : .intel
                    let recommended = builds.filter { $0.isRecommended(for: machine) }
                    let others = builds.filter { !$0.isRecommended(for: machine) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            group(recommended, heading: "releases.workspace.recommended", recommended: true)
                            group(others, heading: recommended.isEmpty ? nil : "releases.workspace.otherFiles", recommended: false)
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                searchField.frame(minWidth: scale.scaled(200))
                filterMenus.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                searchField
                filterMenus
            }
        }
    }

    private var searchField: some View {
        ReleaseSearchField(label: "releases.assetFilter.placeholder", text: $filter.query)
    }

    private var filterMenus: some View {
        HStack(spacing: 14) {
            Picker("releases.workspace.platform", selection: $filter.platform) {
                Text("general.all").tag(nil as ReleaseBuildArtifact.Platform?)
                ForEach(ReleaseBuildArtifact.Platform.allCases, id: \.self) { platform in
                    Text(verbatim: platform.rawValue).tag(Optional(platform))
                }
            }
            Picker("releases.workspace.architecture", selection: $filter.architecture) {
                Text("general.all").tag(nil as ReleaseBuildArtifact.Architecture?)
                ForEach(ReleaseBuildArtifact.Architecture.allCases, id: \.self) { architecture in
                    Text(verbatim: architecture.rawValue).tag(Optional(architecture))
                }
            }
        }.controlSize(.small).font(scale.font(.caption))
    }

    @ViewBuilder private func group(_ builds: [ReleaseBuildArtifact], heading: LocalizedStringKey?, recommended: Bool) -> some View {
        if !builds.isEmpty {
            if let heading {
                Label(heading, systemImage: recommended ? "desktopcomputer" : "shippingbox")
                    .font(scale.font(.captionStrong)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
            ForEach(Array(builds.enumerated()), id: \.element.id) { index, build in
                ReleaseWorkspaceAssetRow(build: build, downloads: downloads, recommended: recommended)
                    .listRowSurface(index: index)
            }
        }
    }
}

/// 文件名优先，次行给出大小与识别出的目标；成功后保留 Finder 操作，同时允许再次下载。
private struct ReleaseWorkspaceAssetRow: View {
    let build: ReleaseBuildArtifact
    let downloads: ReleaseWorkspaceDownloads
    let recommended: Bool
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            BusinessIcon(source: ReleaseAssetIcon.iconSource(for: build.asset.name), pointSize: 19)
                .frame(width: 29, height: 29)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: build.asset.name)
                    .font(scale.font(.body, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled).help(Text(verbatim: build.asset.name))
                let size = Int64(build.asset.size).formatted(.byteCount(style: .file).locale(locale))
                Text(verbatim: [size, build.platform?.rawValue, build.architecture?.rawValue]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(scale.font(.captionSmall)).foregroundStyle(.secondary)
                if case .failed(let reason) = downloads.states[build.id] {
                    Text(verbatim: reason).font(scale.font(.captionSmall)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            CopyFeedbackButton(providesContent: { build.asset.browserDownloadUrl }, tooltip: "releases.copyDownloadLink") { copied in
                Image(systemName: copied ? "checkmark.circle.fill" : "link")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            action.controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder private var action: some View {
        switch downloads.states[build.id] {
        case .running(let fraction):
            VStack(alignment: .trailing, spacing: 3) {
                Text(fraction, format: .percent.precision(.fractionLength(0)).locale(locale))
                    .font(scale.font(.captionSmall).monospacedDigit())
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 58)
            }
        case .saved(let url):
            Button { ReleaseAssetDownloadToastSupport.revealInFinder(url) } label: {
                Label("settings.storage.revealInFinder", systemImage: "folder").labelStyle(.iconOnly)
            }.help("settings.storage.revealInFinder")
            downloadButton
        case .failed:
            Button("action.retry") { Task { await downloads.start(build.asset) } }
        case nil:
            if recommended { downloadButton.buttonStyle(.borderedProminent) }
            else { downloadButton }
        }
    }

    private var downloadButton: some View {
        Button("repo.files.inspector.download") { Task { await downloads.start(build.asset) } }
            .help("releases.downloadAsset")
    }
}
