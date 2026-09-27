import SwiftUI

/// One tab: its display metadata and its own NavStack.
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

/// One `TabView`: a NavStack per tab, plus the selected tab.
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

    /// The modal covering the TabView, whichever tab presented it.
    /// A modal covers the tab bar, so the whole TabView shows one at a time, and switching tabs
    /// leaves it on screen (verified on simulator). Prefers the selected tab if there were ever two.
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
