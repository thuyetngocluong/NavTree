import Testing
import SwiftUI
@testable import NavTree

private struct DummyScreen: NavScreen {
    var body: some View { Text("dummy") }
}

private struct RootScreen: NavRootScreen {
    var body: some View { Text("root") }
}

private struct TabA: NavTabScreen {
    let tabTitle = "A"
    let tabSystemImage = "a.circle"
    var body: some View { Text("A") }
}

private struct TabB: NavTabScreen {
    let tabTitle = "B"
    let tabSystemImage = "b.circle"
    var body: some View { Text("B") }
}

private struct TwoTabs: NavTabBarScreen {
    var content: [any NavTabScreen] {
        TabA()
        TabB()
    }
}

@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(DummyScreen())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ style: NavPresentationStyle) {
    nav.present(DummyScreen(), as: style)
}

@MainActor
private func rootNavigator(ofTab index: Int, in tree: NavTree) -> Navigator {
    let stack = tree.tabs!.tabs[index].stack
    return Navigator(stack: stack, node: stack.root, tree: tree)
}

// MARK: - A modal covers the whole TabView, not just the tab that opened it

@MainActor
struct CrossTabModalTests {

    @Test func currentFollowsModalAfterSwitchingTabUnderIt() {
        let tree = NavTree(root: TwoTabs())
        tree.selectTab(1)
        syncPresent(tree.current, .sheet)
        let sheet = tree.tabs!.tabs[1].stack.root.presented[0]

        tree.selectTab(0) // modal stays on screen after switching tabs
        #expect(tree.selectedTab == 0)
        #expect(tree.current.node === sheet.root)
        #expect(tree.current.isPresented)
    }

    @Test func presentFromOtherTabForwardsIntoOpenModal() {
        let tree = NavTree(root: TwoTabs())
        syncPresent(rootNavigator(ofTab: 1, in: tree), .sheet)
        let sheet = tree.tabs!.tabs[1].stack.root.presented[0]

        // Tab 0 root presents while tab 1's sheet covers the TabView.
        syncPresent(rootNavigator(ofTab: 0, in: tree), .fullScreenCover)
        #expect(tree.tabs!.tabs[0].stack.root.presented.isEmpty)
        #expect(sheet.root.presented.first?.style == .fullScreenCover)
    }

    @Test func deepLinkPushAfterTabSwitchLandsInVisibleModal() {
        let tree = NavTree(root: TwoTabs())
        tree.selectTab(1)
        syncPresent(tree.current, .sheet)
        let sheet = tree.tabs!.tabs[1].stack.root.presented[0]

        tree.selectedTab = 0
        syncPush(tree.current)
        #expect(sheet.path.count == 1)
        #expect(tree.tabs!.tabs[0].stack.path.isEmpty) // no push into the covered tab
    }

    @Test func pushInsideTabStillWorksWithoutModal() {
        let tree = NavTree(root: TwoTabs())
        syncPush(tree.current)
        #expect(tree.tabs!.tabs[0].stack.path.count == 1)
        tree.selectTab(1)
        #expect(tree.current.node === tree.tabs!.tabs[1].stack.root)
    }
}

// MARK: - A zombie Navigator must not pop / dismiss

@MainActor
struct ZombieGuardTests {

    @Test func zombieDismissDoesNotCloseCurrentSheet() {
        let tree = NavTree(root: RootScreen())
        syncPresent(tree.current, .sheet)
        syncPush(tree.current)                 // B inside sheet
        let navB = tree.current
        navB.pop()                             // user pops B
        navB.dismiss(returning: "late")        // old Task calls dismiss late
        #expect(tree.current.isPresented)      // sheet still open
    }

    @Test func zombiePopToRootKeepsNewScreens() {
        let tree = NavTree(root: RootScreen())
        guard case .stack(let stack) = tree.root else { Issue.record("expected stack"); return }
        syncPush(tree.current)                 // B
        let navB = tree.current
        navB.pop()
        syncPush(tree.current)                 // C, opened after B was removed
        syncPush(tree.current)                 // D
        navB.popToRoot()
        #expect(stack.path.count == 2)
    }

    @Test func zombiePopDoesNothing() {
        let tree = NavTree(root: RootScreen())
        guard case .stack(let stack) = tree.root else { Issue.record("expected stack"); return }
        syncPush(tree.current)
        let navB = tree.current
        navB.pop()
        syncPush(tree.current)
        navB.pop()
        #expect(stack.path.count == 1)
    }
}

// MARK: - SwiftUI writes back a stale path

@MainActor
struct StalePathWriteTests {

    @Test func stalePathDoesNotReattachRemovedScreens() {
        let root = NavScreenNode(DummyScreen())
        let stack = NavStack(root: root)
        stack.push(DummyScreen())
        stack.push(DummyScreen())
        let stale = stack.path
        stack.popToRoot()
        stack.path = stale                      // late write from SwiftUI
        #expect(stack.path.isEmpty)
    }

    @Test func stalePathKeepsLivePrefix() {
        let root = NavScreenNode(DummyScreen())
        let stack = NavStack(root: root)
        stack.push(DummyScreen())
        stack.push(DummyScreen())
        stack.push(DummyScreen())
        let stale = stack.path
        stack.pop(stale[1].base)                // removes screens 2 and 3
        stack.path = stale
        #expect(stack.path.count == 1)
        #expect(stack.path.first?.id == stale[0].id)
    }
}

