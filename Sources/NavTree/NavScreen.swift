import SwiftUI

/// Màn hình push / present được — khai `body` như một View bình thường.
public protocol NavScreen: View {}

/// Màn gốc của app khi không dùng tab bar — dùng với `NavRootView(root:)`.
public protocol NavRootScreen: NavScreen {}

/// Màn gốc của một tab.
public protocol NavTabScreen: NavScreen {
    var tabTitle: String { get }
    var tabSystemImage: String { get }
}

@resultBuilder
public enum NavTabBuilder {
    public static func buildExpression(_ screen: some NavTabScreen) -> [any NavTabScreen] { [screen] }
    public static func buildBlock(_ parts: [any NavTabScreen]...) -> [any NavTabScreen] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [any NavTabScreen]?) -> [any NavTabScreen] { part ?? [] }
    public static func buildEither(first: [any NavTabScreen]) -> [any NavTabScreen] { first }
    public static func buildEither(second: [any NavTabScreen]) -> [any NavTabScreen] { second }
    public static func buildArray(_ parts: [[any NavTabScreen]]) -> [any NavTabScreen] { parts.flatMap { $0 } }
}

/// Màn tab bar của app — chỉ khai `content` (danh sách tab), thân được gán ngầm.
public protocol NavTabBarScreen: View {
    @NavTabBuilder var content: [any NavTabScreen] { get }
}

public extension NavTabBarScreen {
    var body: some View {
        NavTabBarHost(tabs: content)
    }
}
