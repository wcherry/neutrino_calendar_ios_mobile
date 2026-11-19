import SwiftUI

// MARK: - AvailabilityFill

/// The fill behind an event on the calendar, by its availability, always in its calendar's
/// colour. The same four as the web (`calendar/availability.module.css`):
///
/// - busy: the tint every event had before availability existed.
/// - tentative: the tint in diagonal stripes.
/// - free: hollow, with a dashed outline.
/// - away (out of office): a deeper fill.
struct AvailabilityFill: View {
    let availability: EventAvailability
    let color: Color
    var cornerRadius: CGFloat = 4
    /// How strong a busy event's tint is; the others are measured from it.
    var tint: Double = 0.18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        switch availability {
        case .busy:
            shape.fill(color.opacity(tint))
        case .tentative:
            DiagonalStripes(color: color.opacity(min(1, tint * 1.6)))
                .background(color.opacity(tint * 0.3))
                .clipShape(shape)
        case .free:
            shape.strokeBorder(color.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        case .away:
            shape.fill(color.opacity(min(1, tint * 2.5)))
        }
    }
}

// MARK: - DiagonalStripes

/// Stripes at 45°, as wide as the gaps between them.
private struct DiagonalStripes: View {
    let color: Color
    var width: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += width * 2 * 2.squareRoot()
            }
            context.stroke(path, with: .color(color), lineWidth: width)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - AvailabilityDot

/// A month day's dot for one event: filled, or a ring for a free event, which doesn't take the
/// time. The other kinds are too small to tell apart at 5pt and are shown in the day's list.
struct AvailabilityDot: View {
    let availability: EventAvailability
    let color: Color

    var body: some View {
        if availability == .free {
            Circle().strokeBorder(color, lineWidth: 1)
        } else {
            Circle().fill(color)
        }
    }
}

extension EventOccurrence {
    /// A task on the calendar has none of its own and reads as busy.
    var availability: EventAvailability { task == nil ? event.availability : .busy }
}
