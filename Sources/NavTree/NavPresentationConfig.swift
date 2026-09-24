import SwiftUI

/// Kích thước sheet — bọc PresentationDetent để API Sendable và ổn định.
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

/// Cấu hình cho một lần present (chủ yếu cho sheet / popover).
public struct NavPresentationConfig: Sendable {

    /// Rỗng = mặc định của hệ thống (.large).
    public var detents: [NavDetent]

    public var dragIndicator: Visibility

    /// Chặn vuốt / tap-ngoài để đóng — chỉ đóng được bằng dismissBranch/pop.
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

/// Áp config lên NỘI DUNG được present (sheet/popover content).
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
