import Testing
import SwiftUI
@testable import NavTree

// MARK: - Fixtures (round 2)

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
private func navigator(for node: any NavNode, in stack: NavStack) -> Navigator {
    Navigator(stack: stack, node: node, tree: nil)
}

@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(DummyScreen())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ style: NavPresentationStyle) {
    nav.present(DummyScreen(), as: style)
}

private struct SeededRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33) % bound
    }
}

private struct CustomResult: Sendable, Equatable {
    let code: Int
    let tag: String
}

// MARK: - Reentrancy: navigate again right when the continuation resumes

@MainActor
struct ReentrancyTests {

    @Test func pushAgainInsideResumedContinuation() async {
        let (stack, nav) = makeStack()
        let task = Task {
            _ = await nav.push(DummyScreen())
            syncPush(nav)
        }
        await settle()
        stack.popToRoot()
        _ = await task.value
        await settle()
        #expect(stack.path.count == 1)
        stack.popToRoot()
        #expect(stack.path.isEmpty)
    }

    @Test func presentInsideResumedContinuation() async {
        let (stack, nav) = makeStack()
        let task = Task {
            _ = await nav.present(DummyScreen(), as: .sheet)
            syncPresent(nav, .fullScreenCover)
        }
        await settle()
        stack.root.presented[0].dismissSelf()
        _ = await task.value
        await settle()
        #expect(stack.root.presented.count == 1)
        #expect(stack.root.presented[0].style == .fullScreenCover)
        stack.root.presented[0].dismissSelf()
        #expect(stack.root.presented.isEmpty)
    }

    @Test func chainedAwaitsSequentially() async {
        let (stack, nav) = makeStack()
        let task = Task { () -> [String] in
            var results: [String] = []
            for _ in 0..<3 {
                let r = await nav.push(DummyScreen())
                results.append((r as? String) ?? "nil")
            }
            return results
        }
        for expected in ["a", "b", "c"] {
            await settle()
            #expect(stack.path.count == 1)
            let topNav = navigator(for: stack.top, in: stack)
            topNav.pop(returning: expected)
        }
        let results = await task.value
        #expect(results == ["a", "b", "c"])
        #expect(stack.path.isEmpty)
    }
}

// MARK: - Deep recursion & large sizes

@MainActor
struct DeepNestingTests {

    @Test func threeHundredNestedModalsDismissWithoutStackOverflow() {
        let (stack, _) = makeStack()
        var node: any NavNode = stack.root
        for i in 0..<300 {
            let presented = node.present(DummyScreen(), style: i % 2 == 0 ? .sheet : .fullScreenCover)
            presented.push(DummyScreen())
            node = presented.top
        }
        #expect(stack.treeLines().count == 1 + 300 * 2)
        stack.root.presented = []
        #expect(stack.treeLines().count == 1)
    }

    @Test func thousandNodeChainPopToRoot() {
        let (stack, _) = makeStack()
        for _ in 0..<1000 { stack.push(DummyScreen()) }
        #expect(stack.path.count == 1000)
        stack.popToRoot()
        #expect(stack.path.isEmpty)
    }

    @Test func popMiddleNodePrunesTailPresents() async {
        let (stack, _) = makeStack()
        for _ in 0..<6 { stack.push(DummyScreen()) }
        let tailNode = stack.path[4].base
        let tailNav = navigator(for: tailNode, in: stack)
        let task = Task { await tailNav.present(DummyScreen(), as: .sheet) }
        await settle()
        #expect(tailNode.presented.count == 1)
        stack.pop(stack.path[2].base)
        let result = await task.value
        #expect(result == nil)
        #expect(stack.path.count == 2)
    }
}

// MARK: - Results: any type, double-dismiss, mid-pop

@MainActor
struct ResultEdgeTests {

    @Test func customStructAndIntResults() async {
        let (stack, nav) = makeStack()
        let pushTask = Task { await nav.push(DummyScreen()) }
        await settle()
        let custom = CustomResult(code: 7, tag: "vip")
        navigator(for: stack.top, in: stack).pop(returning: custom)
        #expect(await pushTask.value as? CustomResult == custom)

        let presentTask = Task { await nav.present(DummyScreen(), as: .sheet) }
        await settle()
        let sheet = stack.root.presented[0]
        navigator(for: sheet.root, in: sheet).dismiss(returning: 999)
        #expect(await presentTask.value as? Int == 999)
    }

    @Test func secondDismissDoesNotOverrideResult() async {
        let (stack, nav) = makeStack()
        let task = Task { await nav.present(DummyScreen(), as: .sheet) }
        await settle()
        let sheet = stack.root.presented[0]
        let sheetNav = navigator(for: sheet.root, in: sheet)
        sheetNav.dismiss(returning: "first")
        sheetNav.dismiss(returning: "second")
        let result = await task.value
        #expect(result as? String == "first")
    }

    @Test func popMiddleDeliversResultOnlyToThatNode() async {
        let (stack, nav) = makeStack()
        let firstTask = Task { await nav.push(DummyScreen()) }
        await settle()
        let firstNode = stack.top
        let secondTask = Task { await navigator(for: firstNode, in: stack).push(DummyScreen()) }
        await settle()
        #expect(stack.path.count == 2)
        navigator(for: firstNode, in: stack).pop(returning: "mine")
        #expect(await firstTask.value as? String == "mine")
        #expect(await secondTask.value == nil)
    }
}

// MARK: - Tabs

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
struct TabsEdgeTests {

    @Test func selectTabOutOfBoundsIsNoop() {
        let tree = NavTree(root: TwoTabs())
        let tabs = tree.tabs!
        let nav = tree.current
        let before = tabs.selection
        nav.selectTab(5)
        nav.selectTab(-1)
        #expect(tabs.selection == before)
        nav.selectTab(1)
        #expect(tabs.selection == tabs.tabs[1].id)
    }

    @Test func treeLinesCoversAllTabs() {
        let tree = NavTree(root: TwoTabs())
        let tabs = tree.tabs!
        tabs.tabs[1].stack.push(DummyScreen())
        // Tab A's Navigator can still print the whole tree since it holds the tree.
        let lines = tree.current.treeLines()
        #expect(lines.count == 5)
        #expect(lines.filter { $0.contains("[tab]") }.count == 2)
        #expect(tree.treeLines() == lines)
    }
}

// MARK: - Multi-seed fuzz + simulated visibility

@MainActor
struct FuzzRound2Tests {

    @Test(arguments: [UInt64(0xCAFEBABE), 0x12345678, 0x0BADF00D])
    func multiSeedStormWithVisibilityFlips(seed: UInt64) async {
        let (rootStack, _) = makeStack()
        var rng = SeededRandom(state: seed)
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

        for i in 0..<300 {
            let stacks = liveStacks()
            let stack = stacks[rng.next(stacks.count)]
            let node = stack.top
            let nav = navigator(for: node, in: stack)
            switch rng.next(9) {
            case 0, 1:
                syncPush(nav)
            case 2:
                syncPresent(nav, [.sheet, .fullScreenCover, .popover][rng.next(3)])
            case 3:
                nav.pop(returning: i)
            case 4:
                nav.popToRoot()
            case 5:
                nav.dismiss(returning: "d\(i)")
            case 6:
                node.isVisible = rng.next(2) == 0
            case 7:
                awaitTasks.append(Task { await nav.push(DummyScreen()) })
                await settle()
            default:
                // .disappeared needs real UI to fire onDisappear, so fuzz uses only .removed.
                // .disappeared has its own deterministic tests.
                awaitTasks.append(Task { await nav.present(DummyScreen(), as: .sheet) })
                await settle()
            }
            var count = 0
            var walker = rootStack.root.pushed
            while let n = walker { count += 1; walker = n.pushed }
            #expect(rootStack.path.count == count)
        }

        rootStack.popToRoot()
        rootStack.root.presented = []
        rootStack.root.isVisible = false
        for task in awaitTasks {
            _ = await task.value
        }
        #expect(rootStack.treeLines().count == 1)
    }
}
