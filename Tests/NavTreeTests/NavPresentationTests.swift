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
private func makeStack() -> (NavStack, Navigator) {
    let root = NavScreenNode(DummyScreen())
    let stack = NavStack(root: root)
    let nav = Navigator(stack: stack, node: root, tree: nil)
    return (stack, nav)
}

@MainActor
private func syncPresent(_ nav: Navigator, _ style: NavPresentationStyle) {
    nav.present(DummyScreen(), as: style)
}

@MainActor
struct PresentationConfigTests {

    @Test func configIsStoredOnStack() {
        let (stack, nav) = makeStack()
        nav.present(
            DummyScreen(),
            as: .sheet,
            config: .init(detents: [.medium, .large], dragIndicator: .visible, interactiveDismissDisabled: true)
        )
        let sheet = stack.root.presented[0]
        #expect(sheet.config.detents == [.medium, .large])
        #expect(sheet.config.dragIndicator == .visible)
        #expect(sheet.config.interactiveDismissDisabled)
    }

    @Test func defaultConfigIsEmpty() {
        let (stack, nav) = makeStack()
        nav.present(DummyScreen(), as: .sheet)
        let sheet = stack.root.presented[0]
        #expect(sheet.config.detents.isEmpty)
        #expect(!sheet.config.interactiveDismissDisabled)
    }

    @Test func popoverBehavesLikeOtherKinds() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.present(DummyScreen(), as: .popover) }
        await settle()
        let popover = stack.root.presented[0]
        #expect(popover.style == .popover)

        // Presenting while the popover is open forwards to the popover's leaf
        syncPresent(nav, .sheet)
        #expect(stack.root.presented.count == 1)
        #expect(popover.root.presented.first?.style == .sheet)

        // Dismissing the popover also removes the nested sheet; the awaiter gets the result
        let popNav = Navigator(stack: popover, node: popover.root, tree: nil)
        popNav.dismiss(returning: "pop-done")
        let result = await task.value
        #expect(result as? String == "pop-done")
        #expect(stack.root.presented.isEmpty)
    }

    @Test func treeLinesLabelsPopover() {
        let (stack, nav) = makeStack()
        nav.present(DummyScreen(), as: .popover)
        let lines = stack.treeLines()
        #expect(lines.contains { $0.contains("[popover]") })
    }
}
