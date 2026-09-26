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
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func rootStack(of tree: NavTree) -> NavStack {
    guard case .stack(let stack) = tree.root else { fatalError("expected stack root") }
    return stack
}

/// Mỗi case tạo NavTree riêng — không còn state toàn cục, không cần `.serialized`.
@MainActor
struct NavTreeCurrentTests {

    @Test func emptyNavigatorIsSafeNoop() {
        let nav = Navigator()
        #expect(nav.stack == nil)
        #expect(nav.node == nil)
        // Mọi lệnh phải là no-op an toàn, không crash
        syncPush(nav)
        nav.pop()
        nav.popToRoot()
        nav.dismiss()
        nav.selectTab(0)
        #expect(nav.treeLines().isEmpty)
    }

    @Test func treeExistsBeforeAnyViewAppears() {
        let tree = NavTree(root: RootScreen())
        // Không cần NavRootView / onAppear — dùng được ngay sau init.
        syncPush(tree.current)
        #expect(rootStack(of: tree).path.count == 1)
        #expect(tree.treeLines().count == 2)
    }

    @Test func currentFollowsPushedTopOfSingleRoot() {
        let tree = NavTree(root: RootScreen())
        let root = rootStack(of: tree)

        #expect(tree.current.node === root.root)

        syncPush(tree.current)
        syncPush(tree.current)
        #expect(root.path.count == 2)
        #expect(tree.current.node === root.top)

        tree.current.pop()
        #expect(root.path.count == 1)
        tree.current.popToRoot()
        #expect(root.path.isEmpty)
    }

    @Test func currentDescendsIntoDeepestPresentedStack() {
        let tree = NavTree(root: RootScreen())
        let root = rootStack(of: tree)

        syncPresent(tree.current, .sheet)
        let sheet = root.root.presented[0]
        #expect(tree.current.node === sheet.root)
        #expect(tree.current.isPresented)

        // push/present tiếp đều áp vào ngữ cảnh sâu nhất
        syncPush(tree.current)
        #expect(sheet.path.count == 1)
        syncPresent(tree.current, .fullScreenCover)
        let cover = sheet.top.presented[0]
        #expect(tree.current.node === cover.root)

        tree.current.dismiss()
        #expect(sheet.top.presented.isEmpty)
        #expect(tree.current.node === sheet.top)
    }

    @Test func currentFollowsSelectedTab() {
        let tree = NavTree(root: TwoTabs())
        let tabs = tree.tabs!.tabs

        #expect(tree.current.node === tabs[0].stack.root)
        syncPush(tree.current)
        #expect(tabs[0].stack.path.count == 1)
        #expect(tabs[1].stack.path.isEmpty)

        tree.current.selectTab(1)
        #expect(tree.current.node === tabs[1].stack.root)
        syncPush(tree.current)
        #expect(tabs[1].stack.path.count == 1)
        #expect(tabs[0].stack.path.count == 1) // tab A giữ nguyên stack

        // treeLines từ .current phủ cả các tab
        #expect(tree.current.treeLines().filter { $0.contains("[tab]") }.count == 2)
    }

    @Test func awaitViaCurrentResumesOnPop() async {
        let tree = NavTree(root: RootScreen())
        let root = rootStack(of: tree)

        let task = Task { await tree.current.push(DummyScreen()) }
        await settle()
        #expect(root.path.count == 1)
        tree.current.pop(returning: "from-current")
        let result = await task.value
        #expect(result as? String == "from-current")
    }

    @Test func twoTreesAreIndependent() {
        // Hai Scene (cửa sổ) = hai cây, không ảnh hưởng nhau.
        let a = NavTree(root: RootScreen())
        let b = NavTree(root: RootScreen())
        syncPush(a.current)
        #expect(rootStack(of: a).path.count == 1)
        #expect(rootStack(of: b).path.isEmpty)
        #expect(a.current != b.current)
    }

    @Test func selectedTabReadsAndWrites() {
        let tree = NavTree(root: TwoTabs())
        #expect(tree.selectedTab == 0)
        tree.selectedTab = 1
        #expect(tree.selectedTab == 1)
        #expect(tree.current.node === tree.tabs!.tabs[1].stack.root)
        tree.selectedTab = 7   // ngoài phạm vi → bỏ qua
        #expect(tree.selectedTab == 1)
        tree.current.selectTab(0)  // đổi qua Navigator cũng phản ánh ra selectedTab
        #expect(tree.selectedTab == 0)
    }

    @Test func selectedTabIsObservable() {
        let tree = NavTree(root: TwoTabs())
        // onChange là @Sendable → ghi cờ qua một box thay vì var bị capture.
        // onChange chạy đồng bộ trong selectTab trên MainActor nên không có race thật.
        final class Flag: @unchecked Sendable { var value = false }
        let fired = Flag()
        withObservationTracking {
            _ = tree.selectedTab
        } onChange: {
            fired.value = true
        }
        tree.selectTab(1)
        #expect(fired.value)
    }

    @Test func selectedTabOnStackRootIsNoop() {
        let tree = NavTree(root: RootScreen())
        #expect(tree.selectedTab == 0)
        tree.selectedTab = 1
        #expect(tree.selectedTab == 0)
    }

    @Test func navigatorCarriesTreeForTabSwitchingFromDeepScreen() {
        let tree = NavTree(root: TwoTabs())
        syncPresent(tree.current, .sheet)
        let deep = tree.current
        #expect(deep.isPresented)
        deep.selectTab(1) // đổi tab từ trong modal vẫn có tác dụng
        #expect(tree.tabs!.selection == tree.tabs!.tabs[1].id)
    }
}
