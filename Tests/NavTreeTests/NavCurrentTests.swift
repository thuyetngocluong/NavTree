import Testing
import SwiftUI
@testable import NavTree

private struct DummyScreen: NavScreen {
    var body: some View { Text("dummy") }
}

@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(DummyScreen())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ kind: NavBranchKind) {
    nav.present(DummyScreen(), as: kind)
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

/// `.serialized` vì các case dùng chung NavRegistry (state toàn cục).
@MainActor
@Suite(.serialized)
struct NavigatorCurrentTests {

    @Test func emptyWhenNoRootRegistered() {
        NavRegistry.reset()
        let nav = Navigator.current
        #expect(nav.branch == nil)
        #expect(nav.node == nil)
        // Mọi lệnh phải là no-op an toàn, không crash
        syncPush(nav)
        nav.pop()
        nav.popToRoot()
        nav.dismissBranch()
        nav.selectTab(0)
        #expect(nav.treeLines().isEmpty)
    }

    @Test func currentFollowsPushedTopOfSingleRoot() {
        NavRegistry.reset()
        let root = NavBranch(root: NavNodeItem(DummyScreen()))
        NavRegistry.register(rootBranch: root)

        #expect(Navigator.current.node === root.root)

        syncPush(Navigator.current)
        syncPush(Navigator.current)
        #expect(root.path.count == 2)
        #expect(Navigator.current.node === root.current)

        Navigator.current.pop()
        #expect(root.path.count == 1)
        Navigator.current.popToRoot()
        #expect(root.path.isEmpty)
    }

    @Test func currentDescendsIntoDeepestPresentedBranch() {
        NavRegistry.reset()
        let root = NavBranch(root: NavNodeItem(DummyScreen()))
        NavRegistry.register(rootBranch: root)

        syncPresent(Navigator.current, .sheet)
        let sheet = root.root.presents[0]
        #expect(Navigator.current.node === sheet.root)
        #expect(Navigator.current.isPresented)

        // push/present tiếp đều áp vào ngữ cảnh sâu nhất
        syncPush(Navigator.current)
        #expect(sheet.path.count == 1)
        syncPresent(Navigator.current, .fullScreenCover)
        let cover = sheet.current.presents[0]
        #expect(Navigator.current.node === cover.root)

        Navigator.current.dismissBranch()
        #expect(sheet.current.presents.isEmpty)
        #expect(Navigator.current.node === sheet.current)
    }

    @Test func currentFollowsSelectedTab() {
        NavRegistry.reset()
        let tabs = [
            NavTab("A", systemImage: "a.circle", root: NavNodeItem(DummyScreen())),
            NavTab("B", systemImage: "b.circle", root: NavNodeItem(DummyScreen())),
        ]
        let forest = NavForest(tabs: tabs)
        NavRegistry.register(forest: forest)

        #expect(Navigator.current.node === tabs[0].branch.root)
        syncPush(Navigator.current)
        #expect(tabs[0].branch.path.count == 1)
        #expect(tabs[1].branch.path.isEmpty)

        Navigator.current.selectTab(1)
        #expect(Navigator.current.node === tabs[1].branch.root)
        syncPush(Navigator.current)
        #expect(tabs[1].branch.path.count == 1)
        #expect(tabs[0].branch.path.count == 1) // tab A giữ nguyên stack

        // treeLines từ .current phủ cả forest
        #expect(Navigator.current.treeLines().filter { $0.contains("[tab]") }.count == 2)
    }

    @Test func awaitViaCurrentResumesOnPop() async {
        NavRegistry.reset()
        let root = NavBranch(root: NavNodeItem(DummyScreen()))
        NavRegistry.register(rootBranch: root)

        let task = Task { await Navigator.current.push(DummyScreen()) }
        await settle()
        #expect(root.path.count == 1)
        Navigator.current.pop(returning: "from-current")
        let result = await task.value
        #expect(result as? String == "from-current")
    }

    @Test func registeringSameRootTwiceIsIdempotent() {
        NavRegistry.reset()
        let root = NavBranch(root: NavNodeItem(DummyScreen()))
        NavRegistry.register(rootBranch: root)
        NavRegistry.register(rootBranch: root) // onAppear có thể chạy lại — không được assert
        #expect(Navigator.current.node === root.root)
    }
}
