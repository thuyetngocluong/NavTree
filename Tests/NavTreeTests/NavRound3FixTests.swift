import Testing
import SwiftUI
@testable import NavTree

// Hồi quy cho hai lỗi tìm ra ở vòng stress test thứ 3.

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

// MARK: - `.disappeared` resume sớm khi màn đang bị fullScreenCover che

@MainActor
struct DisappearedUnderCoverTests {

    /// Sheet có một cover đè lên. fullScreenCover làm màn bên dưới nhận onDisappear (isVisible = false),
    /// nên khi đóng sheet, awaiter `.disappeared` resume ngay — trong khi cover vẫn đang chạy animation đóng.
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
        sheet.root.isVisible = false            // bị cover che → onDisappear
        cover.root.isVisible = true

        Navigator(stack: sheet, node: sheet.root, tree: nil).dismiss()
        await settle()
        #expect(!done.value, "resume khi cover vẫn đang trên màn hình")

        cover.root.isVisible = false            // animation đóng của cover kết thúc
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

        rootNav.popToRoot()                     // ví dụ deep link reset về gốc
        await settle()
        #expect(!done.value, "resume khi cover vẫn đang trên màn hình")

        cover.root.isVisible = false
        cover.root.resumeDisappear()
        await settle()
        #expect(done.value)
    }

    /// Màn chờ bị một màn push phía sau che; cả hai bị gỡ cùng lúc → chờ animation pop của màn đang hiển thị.
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

// MARK: - Path cũ từ SwiftUI xoá mất màn mới push

@MainActor
struct StalePathKillsNewScreensTests {

    /// Code pop về gốc rồi push C, cùng lúc SwiftUI ghi lại path cũ [A] (A đã bị gỡ).
    /// Setter hiện dừng ở A rồi cắt đuôi → C bị gỡ dù người dùng chưa từng thấy nó bị đóng.
    @Test func staleWriteKeepsScreenPushedAfterIt() {
        let root = NavScreenNode(S())
        let stack = NavStack(root: root)
        stack.push(S())                         // A
        let stale = stack.path                  // [A]
        stack.popToRoot()
        stack.push(S())                         // C
        stack.path = stale
        #expect(stack.path.count == 1, "màn C bị path cũ xoá")
    }

    @Test func staleWriteKeepsScreensAfterLivePrefix() {
        let root = NavScreenNode(S())
        let stack = NavStack(root: root)
        stack.push(S())                         // A
        stack.push(S())                         // B
        let stale = stack.path                  // [A, B]
        stack.pop(stale[1].base)                // gỡ B
        stack.push(S())                         // D
        stack.path = stale
        #expect(stack.path.count == 2, "màn D bị path cũ xoá")
    }
}

// MARK: - Round 5: modal đã rời cây nhưng còn đang đóng

@MainActor
struct ClosingModalHandoffTests {

    /// Màn chờ `.disappeared` mở một cover; code đóng cover rồi pop màn đó trong CÙNG lượt xử lý
    /// (ví dụ reset cho deep link). Cover đã rời cây con khi màn bị gỡ, nhưng vẫn đang chạy animation đóng.
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
        awaited.isVisible = false               // bị cover che
        cover.root.isVisible = true

        Navigator(stack: cover, node: cover.root, tree: nil).dismiss()
        rootNav.popToRoot()
        await settle()
        #expect(!done.value, "resume khi cover vẫn đang đóng")

        cover.root.isVisible = false
        cover.root.resumeDisappear()
        await settle()
        #expect(done.value)
    }
}
