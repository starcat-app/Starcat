//
//  RepoRowSkeletonView.swift
//  Starcat
//
//  骨架屏行视图，RepoListView 加载中时替代真实行显示。
//
//  设计约束：
//  - 骨架行尺寸严格匹配 RepoRowView（compact / card 两种密度）
//  - 使用 SwiftUI 动画模拟真实数据加载的"闪烁"效果
//  - 不持有任何业务数据，纯展示型组件
//

import SwiftUI

/// 骨架屏行视图入口：根据密度参数选子视图。
struct RepoRowSkeletonView: View {
    let density: RepoListDensity

    var body: some View {
        switch density {
        case .compact: RepoRowSkeletonCompact()
        case .card:    RepoRowSkeletonCard()
        }
    }
}

// MARK: - Compact 骨架行

private struct RepoRowSkeletonCompact: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 10) {
            // 头像占位
            Circle()
                .fill(shimmerGradient)
                .frame(width: 22, height: 22)

            // 名字占位（两段式模拟）
            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 120, height: 13)

            Spacer()

            // 语言占位
            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 50, height: 13)

            // stars 占位
            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 40, height: 13)
        }
        .padding(.vertical, 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
        .opacity(isAnimating ? 0.6 : 1.0)
    }
}

// MARK: - Card 骨架行

private struct RepoRowSkeletonCard: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 头像占位
            RoundedRectangle(cornerRadius: 20)
                .fill(shimmerGradient)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                // 名字占位
                RoundedRectangle(cornerRadius: 4)
                    .fill(shimmerGradient)
                    .frame(width: 160, height: 14)

                // 描述占位（两行）
                RoundedRectangle(cornerRadius: 4)
                    .fill(shimmerGradient)
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(shimmerGradient)
                    .frame(width: 200, height: 12)

                // 属性条占位
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(shimmerGradient)
                        .frame(width: 50, height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(shimmerGradient)
                        .frame(width: 40, height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(shimmerGradient)
                        .frame(width: 60, height: 12)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
        .opacity(isAnimating ? 0.6 : 1.0)
    }
}

// MARK: - 共享渐变

/// 骨架屏闪烁渐变色：深灰 → 浅灰 → 深灰。
/// 模拟真实加载的视觉反馈，让用户感知"正在加载"。
private var shimmerGradient: LinearGradient {
    LinearGradient(
        gradient: Gradient(colors: [
            Color.gray.opacity(0.15),
            Color.gray.opacity(0.25),
            Color.gray.opacity(0.15)
        ]),
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - 骨架列表视图

/// 骨架屏列表入口，供 RepoListView 在加载中时渲染。
/// 渲染 N 行（默认 8 行）与当前列表密度匹配。
struct RepoSkeletonListView: View {
    let density: RepoListDensity
    let rowCount: Int

    init(density: RepoListDensity = .card, rowCount: Int = 8) {
        self.density = density
        self.rowCount = rowCount
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { _ in
                RepoRowSkeletonView(density: density)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                Divider()
            }
        }
    }
}
