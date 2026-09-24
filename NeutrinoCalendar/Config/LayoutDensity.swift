import SwiftUI

/// The Compact layout setting: less space between and around rows and sections, for people who
/// would rather see more on one screen than have it breathe. Off by default, which leaves every
/// screen exactly as SwiftUI lays it out.
///
/// Stored per device in UserDefaults, under the app's own `ncal.` prefix. It is a preference
/// about this screen, not about the account, so it has no reason to follow the user elsewhere.
enum LayoutDensity {
    static let storageKey = "ncal.layout.compact"

    /// The row padding compact rows use, in place of the list's default (about 11 points top and
    /// bottom and 20 either side).
    static let compactRowInsets = EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14)
    /// The side margin of a compact list's content, in place of the system's 16–20 points.
    static let compactHorizontalMargin: CGFloat = 8
    /// The shortest a compact row gets, in place of the system's 44 points.
    static let compactMinRowHeight: CGFloat = 34
}

extension View {
    /// Applied to each `List` and `Form`: row height, section spacing and side margins.
    func densityList() -> some View { modifier(DensityListModifier()) }

    /// Applied to each row of a list: the padding around the row's content.
    func densityRow() -> some View { modifier(DensityRowModifier()) }
}

private struct DensityListModifier: ViewModifier {
    @AppStorage(LayoutDensity.storageKey) private var compact = false

    func body(content: Content) -> some View {
        if compact {
            content
                .environment(\.defaultMinListRowHeight, LayoutDensity.compactMinRowHeight)
                .modifier(CompactSpacing())
        } else {
            // Nothing applied at all, rather than the defaults restated: the system's values vary
            // by device and list style, and a restated one would be wrong on some of them.
            content
        }
    }
}

/// Section spacing and content margins are iOS 17 API; on iOS 16 compact rows are still compact,
/// with the default gaps between sections.
private struct CompactSpacing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .listSectionSpacing(.compact)
                .contentMargins(.horizontal, LayoutDensity.compactHorizontalMargin, for: .scrollContent)
        } else {
            content
        }
    }
}

private struct DensityRowModifier: ViewModifier {
    @AppStorage(LayoutDensity.storageKey) private var compact = false

    func body(content: Content) -> some View {
        // `nil` is the list's own default, so the comfortable layout is untouched.
        content.listRowInsets(compact ? LayoutDensity.compactRowInsets : nil)
    }
}
