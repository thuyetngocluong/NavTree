import SwiftUI

@MainActor
final class NavTab: Identifiable {

    let id = UUID()
    let title: String
    let systemImage: String
    let branch: NavBranch

    init(_ title: String, systemImage: String, root: any NavNode) {
        self.title = title
        self.systemImage = systemImage
        self.branch = NavBranch(root: root)
    }
}

@MainActor
@Observable
final class NavForest {

    let tabs: [NavTab]
    var selection: NavTab.ID

    init(tabs: [NavTab]) {
        self.tabs = tabs
        self.selection = tabs.first?.id ?? UUID()
    }
}
