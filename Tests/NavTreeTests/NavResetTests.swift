import Testing
import SwiftUI
@testable import NavTree

private struct S: NavScreen {
    var body: some View { Text("s") }
}

private struct R: NavRootScreen {
    var body: some View { Text("r") }
}

private struct TA: NavTabScreen {
    let tabTitle = "A"
    let tabSystemImage = "a.circle"
    var body: some View { Text("A") }
}

private struct TB: NavTabScreen {
    let tabTitle = "B"
    let tabSystemImage = "b.circle"
    var body: some View { Text("B") }
}

private struct TwoTabs: NavTabBarScreen {
    var content: [any NavTabScreen] {
        TA()
        TB()
    }
}

@MainActor
private final class Flag {
    var value = false
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(S())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ style: NavPresentationStyle) {
    nav.present(S(), as: style)
}

@MainActor
private func tabStack(_ index: Int, of tree: NavTree) -> NavStack {
    tree.tabs!.tabs[index].stack
}

@MainActor
struct NavResetTests {

    @Test func resetDismissesModalAndPopsEveryTab() {
        let tree = NavTree(root: TwoTabs())
        syncPush(tree.current)                          // tab A: push
        tree.selectTab(1)
        syncPush(tree.current)                          // tab B: push
        syncPresent(tree.current, .sheet)               // sheet che TabView
        syncPush(tree.current)                          // push trong sheet

        tree.reset()
        #expect(tabStack(0, of: tree).path.isEmpty)
        #expect(tabStack(1, of: tree).path.isEmpty)
        #expect(tree.tabs!.presentedModal == nil)
        #expect(tree.selectedTab == 1)                  // tab giữ nguyên
        #expect(tree.current.node === tabStack(1, of: tree).root)
    }

    @Test func selectedTabScopeKeepsOtherTabs() {
        let tree = NavTree(root: TwoTabs())
        syncPush(tree.current)                          // tab A
        tree.selectTab(1)
        syncPush(tree.current)                          // tab B

        tree.reset(.selectedTab)
        #expect(tabStack(0, of: tree).path.count == 1)
        #expect(tabStack(1, of: tree).path.isEmpty)
    }

    @Test func selectedTabScopeStillClosesModalFromOtherTab() {
        let tree = NavTree(root: TwoTabs())
        syncPresent(tree.current, .fullScreenCover)     // cover mở từ tab A
        tree.selectTab(1)                               // cover vẫn che màn hình

        tree.reset(.selectedTab)
        #expect(tree.tabs!.presentedModal == nil)
        #expect(tree.current.isPresented == false)
    }

    @Test func resetOnStackRoot() {
        let tree = NavTree(root: R())
        syncPush(tree.current)
        syncPush(tree.current)
        syncPresent(tree.current, .sheet)
        tree.reset()
        #expect(tree.treeLines() == ["[root] R"])
    }

    @Test func awaitersInResetPartsResumeWithNil() async {
        let tree = NavTree(root: TwoTabs())
        let pushTask = Task { await tree.current.push(S()) }
        await settle()
        let presentTask = Task { await tree.current.present(S(), as: .sheet) }
        await settle()
        tree.reset()
        #expect(await pushTask.value == nil)
        #expect(await presentTask.value == nil)
    }

    @Test func deepLinkFlowResetSelectPush() {
        let tree = NavTree(root: TwoTabs())
        tree.selectTab(1)
        syncPresent(tree.current, .sheet)
        syncPush(tree.current)

        // Deep link: "mở tab A, đẩy màn chi tiết".
        tree.reset()
        tree.selectedTab = 0
        syncPush(tree.current)

        #expect(tree.tabs!.presentedModal == nil)
        #expect(tabStack(0, of: tree).path.count == 1)
        #expect(tabStack(1, of: tree).path.isEmpty)
        #expect(tree.current.node === tabStack(0, of: tree).top)
    }

    @Test func resetWithNothingToDoIsNoop() async {
        let tree = NavTree(root: TwoTabs())
        let before = tree.treeLines()
        tree.reset()
        await tree.reset(until: .disappeared)          // không có gì hiển thị bị gỡ → trả về ngay
        #expect(tree.treeLines() == before)
    }

    // MARK: until: .disappeared

    @Test func resetUntilDisappearedWaitsForVisibleClosingScreens() async {
        let tree = NavTree(root: TwoTabs())
        syncPresent(tree.current, .sheet)
        let sheet = tabStack(0, of: tree).root.presented[0]
        syncPresent(Navigator(stack: sheet, node: sheet.root, tree: tree), .fullScreenCover)
        let cover = sheet.root.presented[0]
        // Như SwiftUI: sheet giữ màn gốc tab hiển thị, cover làm màn sheet khuất.
        tabStack(0, of: tree).root.isVisible = true
        sheet.root.isVisible = false
        cover.root.isVisible = true

        let done = Flag()
        Task {
            await tree.reset(until: .disappeared)
            done.value = true
        }
        await settle()
        #expect(tree.tabs!.presentedModal == nil)       // đã gỡ ngay
        #expect(!done.value)                            // nhưng cover còn đang đóng

        cover.root.isVisible = false                    // onDisappear của cover
        cover.root.resumeDisappear()
        await settle()
        #expect(done.value)
    }

    @Test func resetUntilDisappearedWaitsForPoppedVisibleTop() async {
        let tree = NavTree(root: R())
        syncPush(tree.current)
        let top = tree.current.node!
        top.isVisible = true

        let done = Flag()
        Task {
            await tree.reset(until: .disappeared)
            done.value = true
        }
        await settle()
        #expect(!done.value)
        top.isVisible = false
        top.resumeDisappear()
        await settle()
        #expect(done.value)
    }

    @Test func resetUntilRemovedReturnsImmediately() async {
        let tree = NavTree(root: R())
        syncPush(tree.current)
        tree.current.node?.isVisible = true
        await tree.reset(until: .removed)
        #expect(tree.treeLines() == ["[root] R"])
    }

    @Test func resetWaitDoesNotHangWhenClosingScreenIsReleased() async {
        let tree = NavTree(root: R())
        syncPush(tree.current)
        var view: (any NavNode)? = tree.current.node    // "view" đang giữ màn
        view?.isVisible = true

        let done = Flag()
        Task {
            await tree.reset(until: .disappeared)
            done.value = true
        }
        await settle()
        #expect(!done.value)
        view = nil                                      // view bị huỷ mà không có onDisappear
        await settle()
        #expect(done.value)                             // deinit resume, không treo
        _ = view
    }
}
