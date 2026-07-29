//
//  StarcatWidgetComponents.swift
//  StarcatWidgets
//
//  三个 Widget 共用的头像、空态和元信息视图。
//

import AppKit
import SwiftUI

struct StarcatWidgetAvatar: View {
    let fileName: String?
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = loadImage() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "shippingbox.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: size * 0.24))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .accessibilityHidden(true)
    }

    private func loadImage() -> NSImage? {
        guard let fileName,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              fileName.hasSuffix(".png"),
              let groupIdentifier = try? WidgetSharedConfiguration.appGroupIdentifier(),
              let containerURL = try? WidgetSharedConfiguration.containerURL(
                groupIdentifier: groupIdentifier
              ) else {
            return nil
        }
        let url = WidgetSharedConfiguration.avatarsDirectoryURL(containerURL: containerURL)
            .appendingPathComponent(fileName, isDirectory: false)
        return NSImage(contentsOf: url)
    }
}

struct StarcatWidgetEmptyView: View {
    let symbol: String
    let titleKey: LocalizedStringKey
    let subtitleKey: LocalizedStringKey
    var openURL: URL? = WidgetAppDeepLink(destination: .main).url
    var accessibilityHintKey: LocalizedStringKey = "widget.common.openStarcat"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(titleKey)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(subtitleKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .widgetURL(openURL)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(accessibilityHintKey))
    }
}

extension StarcatWidgetContent {
    var emptyView: StarcatWidgetEmptyView? {
        switch self {
        case .snapshot:
            return nil
        case .preparing:
            return StarcatWidgetEmptyView(
                symbol: "hourglass",
                titleKey: "widget.common.preparing.title",
                subtitleKey: "widget.common.preparing.subtitle"
            )
        case .signedOut:
            return StarcatWidgetEmptyView(
                symbol: "person.crop.circle.badge.exclamationmark",
                titleKey: "widget.common.signedOut.title",
                subtitleKey: "widget.common.signedOut.subtitle"
            )
        case .unavailable:
            return StarcatWidgetEmptyView(
                symbol: "exclamationmark.triangle",
                titleKey: "widget.common.unavailable.title",
                subtitleKey: "widget.common.unavailable.subtitle"
            )
        case .upgradeRequired:
            return StarcatWidgetEmptyView(
                symbol: "arrow.down.app",
                titleKey: "widget.common.upgrade.title",
                subtitleKey: "widget.common.upgrade.subtitle"
            )
        }
    }
}
