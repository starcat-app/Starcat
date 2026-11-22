//
//  InsightsColumnHeader.swift
//  Starcat
//
//  洞察内容栏的紧凑顶栏，随标题与范围控件自然伸缩。
//

import SwiftUI

/// 最小高度与内边距沿用洞察顶栏的紧凑规格。
enum InsightsColumnChrome {
    static let minimumHeaderHeight: CGFloat = 64
    static let headerVerticalPadding: CGFloat = 8
    static let contentTopPadding: CGFloat = 10
}

/// 固定内容的垂直理想尺寸，允许长译文和大字号撑开顶栏。
struct InsightsColumnHeader<Title: View, Controls: View>: View {
    @ViewBuilder let title: Title
    @ViewBuilder let controls: Controls

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                title
                Spacer(minLength: 16)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                title
                controls
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, InsightsColumnChrome.headerVerticalPadding)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: InsightsColumnChrome.minimumHeaderHeight)
    }
}
