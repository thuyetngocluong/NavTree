import Testing
import SwiftUI
@testable import NavTree

private struct DummyScreen: NavScreen {
    var body: some View { Text("dummy") }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func makeBranch() -> (NavBranch, Navigator) {
    let root = NavNodeItem(DummyScreen())
    let branch = NavBranch(root: root)
    let nav = Navigator(branch: branch, node: root, root: branch, forest: nil)
    return (branch, nav)
}

@MainActor
private func syncPresent(_ nav: Navigator, _ kind: NavBranchKind) {
    nav.present(DummyScreen(), as: kind)
}

@MainActor
struct PresentationConfigTests {

    @Test func configIsStoredOnBranch() {
        let (branch, nav) = makeBranch()
        nav.present(
            DummyScreen(),
            as: .sheet,
            config: .init(detents: [.medium, .large], dragIndicator: .visible, interactiveDismissDisabled: true)
        )
        let sheet = branch.root.presents[0]
        #expect(sheet.config.detents == [.medium, .large])
        #expect(sheet.config.dragIndicator == .visible)
        #expect(sheet.config.interactiveDismissDisabled)
    }

    @Test func defaultConfigIsEmpty() {
        let (branch, nav) = makeBranch()
        nav.present(DummyScreen(), as: .sheet)
        let sheet = branch.root.presents[0]
        #expect(sheet.config.detents.isEmpty)
        #expect(!sheet.config.interactiveDismissDisabled)
    }

    @Test func popoverBehavesLikeOtherKinds() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.present(DummyScreen(), as: .popover) }
        await settle()
        let popover = branch.root.presents[0]
        #expect(popover.kind == .popover)

        // Present tiếp khi popover đang mở → forward xuống leaf của popover
        syncPresent(nav, .sheet)
        #expect(branch.root.presents.count == 1)
        #expect(popover.root.presents.first?.kind == .sheet)

        // Dismiss popover → cả sheet lồng bên trong chết theo, awaiter nhận kết quả
        let popNav = Navigator(branch: popover, node: popover.root, root: branch, forest: nil)
        popNav.dismissBranch(returning: "pop-done")
        let result = await task.value
        #expect(result as? String == "pop-done")
        #expect(branch.root.presents.isEmpty)
    }

    @Test func treeLinesLabelsPopover() {
        let (branch, nav) = makeBranch()
        nav.present(DummyScreen(), as: .popover)
        let lines = branch.treeLines()
        #expect(lines.contains { $0.contains("[popover]") })
    }
}
