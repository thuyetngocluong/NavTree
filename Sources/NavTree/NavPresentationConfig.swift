import SwiftUI

/// Sheet height. Wraps PresentationDetent to keep the API Sendable and stable.
public enum NavDetent: Sendable, Hashable {
    case medium
    case large
    case fraction(CGFloat)
    case height(CGFloat)

    var presentationDetent: PresentationDetent {
        switch self {
        case .medium: .medium
        case .large: .large
        case .fraction(let value): .fraction(value)
        case .height(let value): .height(value)
        }
    }
}

/// Options for one presentation (mostly sheets and popovers).
public struct NavPresentationConfig: Sendable {

    /// Empty means the system default (`.large`).
    public var detents: [NavDetent]

    public var dragIndicator: Visibility

    /// Blocks swipe/tap-outside dismissal; only `dismiss`/`pop` can close it.
    public var interactiveDismissDisabled: Bool

    public init(
        detents: [NavDetent] = [],
        dragIndicator: Visibility = .automatic,
        interactiveDismissDisabled: Bool = false
    ) {
        self.detents = detents
        self.dragIndicator = dragIndicator
        self.interactiveDismissDisabled = interactiveDismissDisabled
    }

    public static let `default` = NavPresentationConfig()
}

/// Applies the config to the presented CONTENT (sheet/popover).
struct NavPresentationModifier: ViewModifier {

    let config: NavPresentationConfig

    func body(content: Content) -> some View {
        content
            .presentationDetents(
                config.detents.isEmpty
                    ? [.large]
                    : Set(config.detents.map(\.presentationDetent))
            )
            .presentationDragIndicator(config.dragIndicator)
            .interactiveDismissDisabled(config.interactiveDismissDisabled)
    }
}
