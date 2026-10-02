import SwiftUI

// Compiled into both the app and the widget extension, like the rest of Shared/.

extension Color {
    /// A calendar's `#rrggbb` (or `rrggbb`), or nil for anything else, so a bad value falls back
    /// to the caller's default instead of drawing black.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
