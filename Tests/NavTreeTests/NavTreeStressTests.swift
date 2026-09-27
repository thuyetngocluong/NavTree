import Testing
import SwiftUI
@testable import NavTree

// MARK: - Fixtures

private struct DummyScreen: NavScreen {
    var body: some View { Text("dummy") }
}

/// Let child tasks (await push/present) run to their suspension point on MainActor.
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
private func navigator(for node: any NavNode, in stack: NavStack) -> Navigator {
    Navigator(stack: stack, node: node, tree: nil)
}

// Sync helper to call the non-async overload from an async test.
@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(DummyScreen())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ style: NavPresentationStyle) {
    nav.present(DummyScreen(), as: style)
}

// Deterministic LCG so fuzz runs are reproducible.
private struct SeededRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33) % bound
    }
}

// MARK: - Tree structure

@MainActor
struct TreeStructureTests {

    @Test func pushStormThenPopToRoot() {
        let (stack, _) = makeStack()
        for _ in 0..<200 {
            stack.push(DummyScreen())
        }
        #expect(stack.path.count == 200)
        stack.popToRoot()
        #expect(stack.path.isEmpty)
        #expect(stack.root.pushed == nil)
    }

    @Test func pathSetterReattachesChain() {
        let (stack, _) = makeStack()
        for _ in 0..<10 { stack.push(DummyScreen()) }
        let keep = Array(stack.path.prefix(4))
        stack.path = keep
        #expect(stack.path.count == 4)
        #expect(stack.path.map(\.id) == keep.map(\.id))
        stack.path = []
        #expect(stack.root.pushed == nil)
    }

    @Test func popMiddleNodeCutsTail() {
        let (stack, _) = makeStack()
        for _ in 0..<5 { stack.push(DummyScreen()) }
        let middle = stack.path[2].base
        stack.pop(middle)
        #expect(stack.path.count == 2)
    }

    @Test func popRemovedNodeIsNoop() {
        let (stack, _) = makeStack()
        stack.push(DummyScreen())
        let node = stack.path[0].base
        stack.pop(node)
        stack.pop(node) // 2nd time: node already left the tree
        #expect(stack.path.isEmpty)
    }

    @Test func presentForwardsToDeepestLeaf() {
        let (stack, nav) = makeStack()
        nav.present(DummyScreen(), as: .sheet)
        nav.present(DummyScreen(), as: .sheet) // root already has a sheet, forwards to leaf
        let firstSheet = stack.root.presented.first
        #expect(stack.root.presented.count == 1)
        #expect(firstSheet?.root.presented.count == 1)
    }

    @Test func coverForwardsOnTopOfSheet() {
        let (stack, nav) = makeStack()
        nav.present(DummyScreen(), as: .sheet)
        nav.present(DummyScreen(), as: .fullScreenCover)
        let sheet = stack.root.presented.first
        #expect(sheet?.style == .sheet)
        #expect(sheet?.root.presented.first?.style == .fullScreenCover)
    }

    @Test func dismissPrunesNestedSubtree() {
        let (stack, nav) = makeStack()
        nav.present(DummyScreen(), as: .sheet)
        let sheet = stack.root.presented[0]
        sheet.push(DummyScreen())
        sheet.push(DummyScreen())
        let innerNav = navigator(for: sheet.top, in: sheet)
        innerNav.present(DummyScreen(), as: .fullScreenCover)
        sheet.dismissSelf()
        #expect(stack.root.presented.isEmpty)
        #expect(stack.treeLines().count == 1)
    }

    @Test func nodesDeallocateAfterPop() {
        let (stack, _) = makeStack()
        weak var weakNode: AnyObject?
        do {
            stack.push(DummyScreen())
            weakNode = stack.path[0].base
        }
        #expect(weakNode != nil)
        stack.popToRoot()
        #expect(weakNode == nil)
    }

    @Test func stackDeallocatesAfterDismiss() {
        let (stack, nav) = makeStack()
        weak var weakStack: NavStack?
        nav.present(DummyScreen(), as: .sheet)
        weakStack = stack.root.presented.first
        #expect(weakStack != nil)
        weakStack?.dismissSelf()
        #expect(stack.root.presented.isEmpty)
        #expect(weakStack == nil)
    }
}

// MARK: - Await / continuation

@MainActor
struct AwaitTests {

    @Test func awaitPushResumesOnPop() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.push(DummyScreen()) }
        await settle()
        #expect(stack.path.count == 1)
        stack.popToRoot()
        let result = await task.value
        #expect(result == nil)
    }

    @Test func awaitPushReceivesResult() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.push(DummyScreen()) }
        await settle()
        let pushedNav = navigator(for: stack.top, in: stack)
        pushedNav.pop(returning: "42")
        let result = await task.value
        #expect(result as? String == "42")
    }

    @Test func awaitPresentReceivesResultOnDismiss() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.present(DummyScreen(), as: .sheet) }
        await settle()
        let sheet = stack.root.presented[0]
        let sheetNav = navigator(for: sheet.root, in: sheet)
        sheetNav.dismiss(returning: "done")
        let result = await task.value
        #expect(result as? String == "done")
    }

    @Test func popAtStackRootResolvesPresentAwaiter() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.present(DummyScreen(), as: .sheet) }
        await settle()
        let sheet = stack.root.presented[0]
        let sheetNav = navigator(for: sheet.root, in: sheet)
        sheetNav.pop(returning: "via-pop") // pop at a presented stack's root = dismiss
        let result = await task.value
        #expect(result as? String == "via-pop")
        #expect(stack.root.presented.isEmpty)
    }

    @Test func allAwaitersResumeWhenSubtreeCollapses() async {
        let (stack, nav) = makeStack()
        var tasks: [Task<(any Sendable)?, Never>] = []
        for _ in 0..<5 {
            let current = stack.top
            let currentNav = navigator(for: current, in: stack)
            tasks.append(Task { await currentNav.push(DummyScreen()) })
            await settle()
        }
        let midNode = stack.path[2].base
        let midNav = navigator(for: midNode, in: stack)
        tasks.append(Task { await midNav.present(DummyScreen(), as: .sheet) })
        await settle()

        nav.popToRoot()
        for task in tasks {
            let result = await task.value
            #expect(result == nil)
        }
        #expect(stack.path.isEmpty)
        #expect(stack.root.presented.isEmpty)
    }

    @Test func replacingTailResumesOldAwaiter() async {
        let (stack, nav) = makeStack()
        let first = Task { await nav.push(DummyScreen()) }
        await settle()
        let second = Task { await nav.push(DummyScreen()) }
        await settle()
        let firstResult = await first.value
        #expect(firstResult == nil)
        #expect(stack.path.count == 1)
        stack.popToRoot()
        _ = await second.value
    }

    @Test func zombiePushFromRemovedNodeReturnsImmediately() async {
        let (stack, nav) = makeStack()
        syncPush(nav)
        let removed = stack.path[0].base
        let removedNav = navigator(for: removed, in: stack)
        stack.popToRoot()
        let result = await removedNav.push(DummyScreen())
        #expect(result == nil)
        #expect(stack.path.isEmpty)
        let presentResult = await removedNav.present(DummyScreen(), as: .sheet)
        #expect(presentResult == nil)
        #expect(stack.root.presented.isEmpty)
    }

    @Test func disappearedAwaiterResumesImmediatelyWhenNodeInvisible() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.push(DummyScreen(), until: .disappeared) }
        await settle()
        let pushedNav = navigator(for: stack.top, in: stack)
        pushedNav.pop(returning: "gone")
        let result = await task.value
        #expect(result as? String == "gone")
    }

    @Test func disappearedAwaiterWaitsForVisibleNode() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.push(DummyScreen(), until: .disappeared) }
        await settle()
        let pushed = stack.top
        pushed.isVisible = true
        let pushedNav = navigator(for: pushed, in: stack)
        pushedNav.pop(returning: "animated")
        await settle()
        #expect(pushed.isRemoved)
        #expect(!pushed.disappearAwaiters.isEmpty)
        pushed.isVisible = false
        pushed.resumeDisappear()
        let result = await task.value
        #expect(result as? String == "animated")
    }

    @Test func stackDisappearedTransfersToVisibleTop() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.present(DummyScreen(), as: .sheet, until: .disappeared) }
        await settle()
        let sheet = stack.root.presented[0]
        sheet.push(DummyScreen())
        let top = sheet.top
        top.isVisible = true
        sheet.pendingResult = "closed"
        sheet.dismissSelf()
        await settle()
        #expect(!top.disappearAwaiters.isEmpty)
        top.isVisible = false
        top.resumeDisappear()
        let result = await task.value
        #expect(result as? String == "closed")
    }
}

// MARK: - Deterministic fuzz

@MainActor
struct FuzzTests {

    @Test func randomOperationStormKeepsTreeConsistent() async {
        let (rootStack, _) = makeStack()
        var rng = SeededRandom(state: 0xDEADBEEF)
        var awaitTasks: [Task<(any Sendable)?, Never>] = []

        func liveStacks() -> [NavStack] {
            var result: [NavStack] = []
            func walk(_ stack: NavStack) {
                result.append(stack)
                var node: (any NavNode)? = stack.root
                while let n = node {
                    for presented in n.presented { walk(presented) }
                    node = n.pushed
                }
            }
            walk(rootStack)
            return result
        }

        for i in 0..<500 {
            let stacks = liveStacks()
            let stack = stacks[rng.next(stacks.count)]
            let nav = navigator(for: stack.top, in: stack)
            switch rng.next(7) {
            case 0, 1:
                syncPush(nav)
            case 2:
                syncPresent(nav, [.sheet, .fullScreenCover, .popover][rng.next(3)])
            case 3:
                nav.pop(returning: i)
            case 4:
                nav.popToRoot()
            case 5:
                nav.dismiss(returning: i)
            default:
                let node = stack.top
                let nodeNav = navigator(for: node, in: stack)
                awaitTasks.append(Task { await nodeNav.push(DummyScreen()) })
                await settle()
            }
            let lines = rootStack.treeLines()
            #expect(!lines.isEmpty)
            var count = 0
            var node = rootStack.root.pushed
            while let n = node { count += 1; node = n.pushed }
            #expect(rootStack.path.count == count)
        }

        rootStack.popToRoot()
        rootStack.root.presented = []
        for task in awaitTasks {
            _ = await task.value
        }
        #expect(rootStack.treeLines().count == 1)
    }
}
