//
//  RepoRecommendationFloatingButton.swift
//  Starcat
//
//  详情页右下角相似推荐浮动入口。
//

import SwiftUI

struct RepoRecommendationFloatingButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.primary)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }

                Text("\(min(count, 99))")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 4, y: -4)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(Text("repo.recommendations.open"))
        .accessibilityLabel(Text("repo.recommendations.open"))
    }
}
