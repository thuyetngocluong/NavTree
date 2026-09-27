import SwiftUI

/// A screen that can be pushed or presented. Write `body` like any View.
public protocol NavScreen: View {}

/// Root screen of an app without a tab bar. Use with `NavTree(root:)` or `NavRootView(root:)`.
public protocol NavRootScreen: NavScreen {}

/// Root screen of one tab.
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

/// The app's tab bar. Declare only `content` (the tabs); `body` is provided.
/// Deliberately NOT a NavScreen: a tab bar lives at the root and can't be pushed or presented.
/// Use it via `NavTree(root:)` or `NavRootView(root:)`; the implicit `body` is a preview shortcut.
public protocol NavTabBarScreen: View {
    @NavTabBuilder var content: [any NavTabScreen] { get }
}

public extension NavTabBarScreen {
    var body: some View {
        NavRootView(root: self)
    }
}
