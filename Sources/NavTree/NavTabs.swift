import SwiftUI

/// Một tab: metadata hiển thị + NavStack riêng của tab đó.
@MainActor
final class NavTab: Identifiable {

    let id = UUID()
    let title: String
    let systemImage: String
    let stack: NavStack

    init(_ title: String, systemImage: String, root: any NavNode) {
        self.title = title
        self.systemImage = systemImage
        self.stack = NavStack(root: root)
    }
}

/// Một `TabView`: nhiều NavStack đứng cạnh nhau, mỗi tab một stack, và tab đang chọn.
@MainActor
@Observable
final class NavTabs {

    let tabs: [NavTab]
    var selection: NavTab.ID

    init(tabs: [NavTab]) {
        self.tabs = tabs
        self.selection = tabs.first?.id ?? UUID()
        for tab in tabs {
            tab.stack.tabs = self
        }
    }

    var selectedTab: NavTab? {
        tabs.first { $0.id == selection } ?? tabs.first
    }

    /// Modal đang che TabView, bất kể tab nào đã present nó.
    /// Modal che cả tab bar, nên cả TabView chỉ present được một modal tại một thời điểm;
    /// đổi tab khi modal đang mở thì modal vẫn nằm trên màn hình (đã xác nhận trên simulator).
    /// Ưu tiên tab đang chọn nếu (bất thường) có nhiều hơn một.
    var presentedModal: NavStack? {
        if let modal = selectedTab?.stack.presentedModal { return modal }
        return tabs.lazy.compactMap { $0.stack.presentedModal }.first
    }

    func treeLines() -> [String] {
        tabs.flatMap { tab -> [String] in
            let mark = tab.id == selection ? "▶" : "•"
            return ["\(mark) [tab] \(tab.title)"] + tab.stack.treeLines(indent: "    ")
        }
    }
}
