//
//  UnifiedSortMenu.swift
//  Starcat
//
//  顶部 toolbar 通用排序下拉菜单。
//
//  存在意义（W12 toolbar 专项 PR-1）：
//  - Manage 用本地 in-memory comparator（`RepoSortOption`），Weekly 用后端 API
//    参数（`WeeklyFeedSort`），但 UI 形态完全一致：一个 Menu + 内嵌 Picker，
//    每条 Label(name, systemImage:)。
//  - 把"读写当前选项 + 渲染辅助信息"做成 `ListSortDriver` 协议契约，让
//    Manage / Weekly 各自的 ViewModel 实现一份，view 调用方按入参方式注入；
//    UnifiedSortMenu 只关心 UI 容器。
//
//  关键约束：
//  - SwiftUI `Picker` 的 selection 必须是 `Binding`，但 driver 协议本身不便要求
//    `Observable`（实现方往往是 @Observable 的 ViewModel 封装类，包装成 @Bindable
//    会绕一圈）。本组件直接接 `Binding<Option>` + 渲染元数据闭包，更贴 SwiftUI
//    原生写法；`ListSortDriver` 协议保留，仅作为「期望 ViewModel 暴露这些访问器」
//    的契约，调用方按 driver 的 binding/getter 拼装入参。
//

import SwiftUI

// MARK: - 驱动协议（可选）

/// 列表排序驱动协议：所有可接入全局 sort 菜单的 ViewModel 都实现这一份。
///
/// 协议本身不强制 Observable —— 它只规定"如何读写 sortOption + 暴露选项元数据"。
/// view 层在 body 内访问 `driver.sortOption` 时通过外层 `@Bindable var viewModel`
/// 触发 Observation tracking，driver 实例的存在仅作为接口契约。
///
/// 关联类型 `Option` 必须是 `Hashable + Identifiable + CaseIterable + Equatable`：
/// - `Hashable`：SwiftUI Picker tag 需要
/// - `Identifiable`：ForEach 渲染需要
/// - `CaseIterable`：driver 可以直接暴露 `Option.allCases`（也可以自定义子集）
/// - `Equatable`：driver 内部 `didSet` 比较新旧值
///
/// `@MainActor`：driver 都包装 `@MainActor` ViewModel，菜单交互全在主线程；
/// 协议本身标记 actor 隔离，避免实现侧每个成员都重复声明 `@MainActor`。
@MainActor
protocol ListSortDriver: AnyObject {
    associatedtype Option: Hashable & Identifiable & CaseIterable & Equatable

    /// 当前选中的排序选项。
    var sortOption: Option { get set }

    /// 当前 driver 暴露给菜单的可选项列表。
    var availableOptions: [Option] { get }

    /// 选项的本地化显示名（Label.title 用）。
    func displayName(for option: Option) -> LocalizedStringKey

    /// 选项的 SF Symbol 名（Label.icon 用）。
    func systemImage(for option: Option) -> String
}

extension ListSortDriver where Option.AllCases == [Option] {
    var availableOptions: [Option] { Array(Option.allCases) }
}

// MARK: - View

/// 通用排序菜单。toolbar primaryAction 槽内调用。
///
/// 调用方典型用法：
/// ```swift
/// @Bindable var vm = viewModel
/// UnifiedSortMenu(
///     selection: $vm.sortOption,
///     options: RepoSortOption.allCases,
///     displayName: { $0.displayName },
///     systemImage: { $0.systemImage }
/// )
/// ```
struct UnifiedSortMenu<Option: Hashable & Identifiable>: View {

    @Binding var selection: Option
    let options: [Option]
    let displayName: (Option) -> LocalizedStringKey
    let systemImage: (Option) -> String
    var dividerBefore: (Option) -> Bool = { _ in false }

    var body: some View {
        Menu {
            Picker("list.sort", selection: $selection) {
                ForEach(options) { opt in
                    if dividerBefore(opt) {
                        Divider()
                    }
                    Label {
                        Text(displayName(opt))
                    } icon: {
                        Image(systemName: systemImage(opt))
                    }
                    .tag(opt)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("list.sort")
                Text(displayName(selection))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("list.sort")
        }
        .fixedSize()
        .help("list.sortHint")
    }
}

// MARK: - Driver 实现

/// Manage 场景排序 driver：包 `HomeViewModel.sortOption`（内存 comparator）。
///
/// 不在 driver 内做持久化：HomeViewModel.sortOption 没有 didSet 持久化，外层
/// `RepoListView.toolbar` 旧实现是在 `.onChange(of: viewModel.sortOption)` 里
/// 同步 `settings.repoSortOption`。本次抽取保留该模式：菜单切到 driver 后，
/// 外层仍负责持久化同步。
@MainActor
final class ManageSortDriver: ListSortDriver {

    private let viewModel: HomeViewModel

    init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
    }

    var sortOption: RepoSortOption {
        get { viewModel.sortOption }
        set { viewModel.sortOption = newValue }
    }

    var availableOptions: [RepoSortOption] {
        RepoSortOption.manageOptions
    }

    func displayName(for option: RepoSortOption) -> LocalizedStringKey {
        option.displayName
    }

    func systemImage(for option: RepoSortOption) -> String {
        option.systemImage
    }
}

/// Weekly 场景排序 driver：包 `WeeklyContentViewModel.selectedSort`（变更触发 API reload）。
///
/// 与 ManageSortDriver 的区别仅在于读写源；UI 渲染完全一致。
@MainActor
final class WeeklySortDriver: ListSortDriver {

    private let viewModel: WeeklyContentViewModel

    init(viewModel: WeeklyContentViewModel) {
        self.viewModel = viewModel
    }

    var sortOption: WeeklyFeedSort {
        get { viewModel.selectedSort }
        set { viewModel.changeSort(to: newValue) }
    }

    var availableOptions: [WeeklyFeedSort] {
        Array(WeeklyFeedSort.allCases)
    }

    func displayName(for option: WeeklyFeedSort) -> LocalizedStringKey {
        switch option {
        case .defaultOrder: return "weekly.sort.default"
        case .starsDesc:    return "weekly.sort.starsDesc"
        case .starsAsc:     return "weekly.sort.starsAsc"
        case .updatedDesc:  return "weekly.sort.updatedDesc"
        case .updatedAsc:   return "weekly.sort.updatedAsc"
        case .createdDesc:  return "weekly.sort.createdDesc"
        case .createdAsc:   return "weekly.sort.createdAsc"
        case .nameAsc:      return "weekly.sort.nameAsc"
        case .nameDesc:     return "weekly.sort.nameDesc"
        }
    }

    func systemImage(for option: WeeklyFeedSort) -> String {
        switch option {
        case .defaultOrder: return "sparkles"
        case .starsDesc:    return "star.fill"
        case .starsAsc:     return "star"
        case .updatedDesc, .updatedAsc:
            return "clock.arrow.circlepath"
        case .createdDesc:
            return "calendar.badge.plus"
        case .createdAsc:
            return "calendar"
        case .nameAsc:
            return "a.square"
        case .nameDesc:
            return "z.square"
        }
    }
}
