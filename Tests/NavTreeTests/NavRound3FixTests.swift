import Testing
import SwiftUI
@testable import NavTree

// Regressions for two bugs found in stress test round 3.

private struct S: NavScreen {
    var body: some View { Text("s") }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private final class Flag {
    var value = false
}

@MainActor
private func syncPresent(_ nav: Navigator, _ style: NavPresentationStyle) {
    nav.present(S(), as: style)
}

// MARK: - `.disappeared` resumes early when the screen is covered by a fullScreenCover

@MainActor
struct DisappearedUnderCoverTests {

    /// A cover sits on the sheet. fullScreenCover gives the screen below onDisappear (isVisible = false),
    /// so closing the sheet resumed `.disappeared` at once, while the cover was still animating closed.
    @Test func presentDisappearedWaitsForCoverOnTop() async {
        let root = NavScreenNode(S())
        let rootStack = NavStack(root: root)
        let rootNav = Navigator(stack: rootStack, node: root, tree: nil)
        let done = Flag()
        Task {
            await rootNav.present(S(), as: .sheet, until: .disappeared)
            done.value = true
        }
        await settle()
        let sheet = root.presented[0]
        sheet.root.isVisible = true
        syncPresent(Navigator(stack: sheet, node: sheet.root, tree: nil), .fullScreenCover)
        let cover = sheet.root.presented[0]
        sheet.root.isVisible = false            // covered by the cover, onDisappear
        cover.root.isVisible = true

        Navigator(stack: sheet, node: sheet.root, tree: nil).dismiss()
        await settle()
        #expect(!done.value, "resumed while the cover is still on screen")

        cover.root.isVisible = false            // cover's close animation ends
        cover.root.resumeDisappear()
        await settle()
        #expect(done.value)
    }

    @Test func pushDisappearedWaitsForCoverOnTop() async {
        let root = NavScreenNode(S())
        let stack = NavStack(root: root)
        let rootNav = Navigator(stack: stack, node: root, tree: nil)
        let done = Flag()
        Task {
            await rootNav.push(S(), until: .disappeared)
            done.value = true
        }
        await settle()
        let pushed = stack.top
        pushed.isVisible = true
        syncPresent(Navigator(stack: stack, node: pushed, tree: nil), .fullScreenCover)
        let cover = pushed.presented[0]
        pushed.isVisible = false
        cover.root.isVisible = true

        rootNav.popToRoot()                     // e.g. a deep link resetting to root
        await settle()
        #expect(!done.value, "resumed while the cover is still on screen")

        cover.root.isVisible = false
        cover.root.resumeDisappear()
        await settle()
        #expect(done.value)
    }

    /// The awaited screen is covered by a later push; both are removed together, so wait for the visible one's pop animation.
    @Test func pushDisappearedWaitsForVisibleScreenPushedAfterIt() async {
        let root = NavScreenNode(S())
        let stack = NavStack(root: root)
        let rootNav = Navigator(stack: stack, node: root, tree: nil)
        let done = Flag()
        Task {
            await rootNav.push(S(), until: .disappeared)
            done.value = true
        }
        await settle()
        let awaited = stack.top
        stack.push(S())
        let onTop = stack.top
        awaited.isVisible = false
        onTop.isVisible = true

        rootNav.popToRoot()
        await settle()
        #expect(!done.value)

        onTop.isVisible = false
        onTop.resumeDisappear()
        await settle()
        #expect(done.value)
    }

}

// MARK: - A stale path from SwiftUI removes newly pushed screens

@MainActor
struct StalePathKillsNewScreensTests {

    /// Code pops to root then pushes C, while SwiftUI writes back the stale path [A] (A already removed).
    /// The setter stopped at A and cut the tail, so C was removed though the user never saw it close.
    @Test func staleWriteKeepsScreenPushedAfterIt() {
        let root = NavScreenNode(S())
        let stack = NavStack(root: root)
        stack.push(S())                         // A
        let stale = stack.path                  // [A]
        stack.popToRoot()
        stack.push(S())                         // C
        stack.path = stale
        #expect(stack.path.count == 1, "screen C removed by stale path")
    }

    @Test func staleWriteKeepsScreensAfterLivePrefix() {
        let root = NavScreenNode(S())
        let stack = NavStack(root: root)
        stack.push(S())                         // A
        stack.push(S())                         // B
        let stale = stack.path                  // [A, B]
        stack.pop(stale[1].base)                // remove B
        stack.push(S())                         // D
        stack.path = stale
        #expect(stack.path.count == 2, "screen D removed by stale path")
    }
}

// MARK: - Round 5: modal already left the tree but is still closing

@MainActor
struct ClosingModalHandoffTests {

    /// A screen awaiting `.disappeared` opens a cover; code dismisses the cover then pops the screen in the SAME tick
    /// (e.g. a deep link reset). The cover left the subtree when the screen was removed, but is still animating closed.
    @Test func dismissThenPopSameTickWaitsForClosingCover() async {
        let root = NavScreenNode(S())
        let stack = NavStack(root: root)
        let rootNav = Navigator(stack: stack, node: root, tree: nil)
        let done = Flag()
        Task {
            await rootNav.push(S(), until: .disappeared)
            done.value = true
        }
        await settle()
        let awaited = stack.top
        let awaitedNav = Navigator(stack: stack, node: awaited, tree: nil)
        syncPresent(awaitedNav, .fullScreenCover)
        let cover = awaited.presented[0]
        awaited.isVisible = false               // covered by the cover
        cover.root.isVisible = true

        Navigator(stack: cover, node: cover.root, tree: nil).dismiss()
        rootNav.popToRoot()
        await settle()
        #expect(!done.value, "resumed while the cover is still closing")

        cover.root.isVisible = false
        cover.root.resumeDisappear()
        await settle()
        #expect(done.value)
    }
}
