import Testing
import SwiftUI
@testable import NavTree

private struct DummyScreen: NavScreen {
    var body: some View { Text("dummy") }
}

private struct RootScreen: NavRootScreen {
    var body: some View { Text("root") }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(DummyScreen())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ style: NavPresentationStyle) {
    nav.present(DummyScreen(), as: style)
}

// MARK: - Vòng đời: cây bị huỷ khi còn awaiter treo

@MainActor
struct LifetimeTests {

    @Test func treeDroppedWhileAwaitingPushResumesWithNil() async {
        weak var weakRoot: AnyObject?
        weak var weakPushed: AnyObject?
        let task: Task<(any Sendable)?, Never>
        do {
            let root = NavScreenNode(DummyScreen())
            let stack = NavStack(root: root)
            let nav = Navigator(stack: stack, node: root, tree: nil)
            task = Task { await nav.push(DummyScreen()) }
            await settle()
            weakRoot = root
            weakPushed = root.pushed
            #expect(weakPushed != nil)
        }
        await settle()
        #expect(weakRoot == nil)
        #expect(weakPushed == nil)
        // Chỉ await khi đã giải phóng — nếu vòng tham chiếu quay lại, test fail thay vì treo.
        if weakPushed == nil {
            #expect(await task.value == nil)
        }
    }

    @Test func treeDroppedWhileAwaitingPresentResumesWithNil() async {
        weak var weakTree: NavTree?
        weak var weakModal: NavStack?
        let task: Task<(any Sendable)?, Never>
        do {
            let tree = NavTree(root: RootScreen())
            let nav = tree.current
            task = Task { await nav.present(DummyScreen(), as: .sheet) }
            await settle()
            weakTree = tree
            weakModal = tree.current.stack
            #expect(weakModal?.style == .sheet)
        }
        await settle()
        #expect(weakTree == nil)
        #expect(weakModal == nil)
        if weakModal == nil {
            #expect(await task.value == nil)
        }
    }

    @Test func navigatorDoesNotKeepTreeAlive() {
        weak var weakTree: NavTree?
        let nav: Navigator
        do {
            let tree = NavTree(root: RootScreen())
            weakTree = tree
            nav = tree.current
        }
        #expect(weakTree == nil)
        // Navigator mồ côi: mọi lệnh là no-op an toàn.
        syncPush(nav)
        nav.pop()
        nav.dismiss()
        #expect(nav.treeLines().isEmpty)
    }
}

// MARK: - Present chuyển tiếp theo cả stack, không chỉ theo màn đang gọi

@MainActor
struct PresentForwardingTests {

    @Test func presentFromCoveredScreenForwardsIntoExistingModal() {
        // A push B, B mở sheet; navigator của A (bị che) present tiếp.
        let a = NavScreenNode(DummyScreen())
        let stack = NavStack(root: a)
        let navA = Navigator(stack: stack, node: a, tree: nil)
        syncPush(navA)
        let navB = Navigator(stack: stack, node: stack.top, tree: nil)
        syncPresent(navB, .sheet)
        let sheet = stack.top.presented[0]

        syncPresent(navA, .sheet)
        #expect(a.presented.isEmpty)                 // không gắn vào A — SwiftUI sẽ bỏ qua
        #expect(sheet.root.presented.count == 1)     // chuyển tiếp vào sheet đang mở
    }

    @Test func presentFromScreenAboveModalOwnerForwards() {
        // A mở sheet, rồi push B bên dưới sheet; navigator của B present tiếp.
        let a = NavScreenNode(DummyScreen())
        let stack = NavStack(root: a)
        let navA = Navigator(stack: stack, node: a, tree: nil)
        syncPresent(navA, .sheet)
        let sheet = a.presented[0]
        syncPush(navA)
        let b = stack.top
        let navB = Navigator(stack: stack, node: b, tree: nil)

        syncPresent(navB, .fullScreenCover)
        #expect(b.presented.isEmpty)
        #expect(sheet.root.presented.first?.style == .fullScreenCover)
    }

    @Test func awaitPresentFromCoveredScreenResolvesWhenDismissed() async {
        let a = NavScreenNode(DummyScreen())
        let stack = NavStack(root: a)
        let navA = Navigator(stack: stack, node: a, tree: nil)
        syncPush(navA)
        syncPresent(Navigator(stack: stack, node: stack.top, tree: nil), .sheet)
        let sheet = stack.top.presented[0]

        let task = Task { await navA.present(DummyScreen(), as: .sheet) }
        await settle()
        let forwarded = sheet.root.presented[0]
        Navigator(stack: forwarded, node: forwarded.root, tree: nil).dismiss(returning: "ok")
        #expect(await task.value as? String == "ok")
    }

    @Test func currentFindsModalPresentedFromNonTopScreen() {
        let tree = NavTree(root: RootScreen())
        guard case .stack(let rootStack) = tree.root else { Issue.record("expected stack"); return }
        let rootNav = Navigator(stack: rootStack, node: rootStack.root, tree: tree)
        syncPresent(rootNav, .sheet)
        let sheet = rootStack.root.presented[0]
        syncPush(rootNav) // push bên dưới sheet → màn gốc không còn là top
        #expect(tree.current.node === sheet.root)
    }
}
