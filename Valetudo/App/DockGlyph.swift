import SwiftUI

/// The robot parked against its dock. SF Symbols has nothing that reads as a robot's dock, and a
/// lightning bolt reads as power or charging, so the app draws its own.
struct DockGlyph: View {
    /// Pass this wherever a symbol name is expected, and `AppSymbol` draws the dock instead.
    static let symbolName = "app.robot.dock"

    var body: some View {
        // A hidden symbol sizes the glyph from the current font, like any SF Symbol.
        Image(systemName: "square.fill")
            .hidden()
            .overlay {
                GeometryReader { proxy in
                    let rect = CGRect(origin: .zero, size: proxy.size)
                    ZStack {
                        Self.dock(in: rect).fill(.foreground).opacity(0.45)
                        Self.robot(in: rect).fill(.foreground)
                    }
                }
            }
            .accessibilityHidden(true)
    }

    /// The dock seen from above, as on the floor plan: a wide base the robot backs into.
    /// Drawn in a 24 by 24 grid scaled into `rect`.
    static func dock(in rect: CGRect) -> Path {
        let (o, s) = grid(rect)
        return Path(roundedRect: CGRect(x: o.x + 2.5 * s, y: o.y + 1.5 * s, width: 19 * s, height: 6.5 * s),
                    cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s), style: .continuous)
    }

    /// The robot seen from above, with an arrow cut out pointing it into the dock.
    static func robot(in rect: CGRect) -> Path {
        let (o, s) = grid(rect)
        let body = Path(ellipseIn: CGRect(x: o.x + 4.5 * s, y: o.y + 9 * s, width: 15 * s, height: 15 * s))
        var arrow = Path()
        arrow.move(to: CGPoint(x: o.x + 12 * s, y: o.y + 20.5 * s))
        arrow.addLine(to: CGPoint(x: o.x + 12 * s, y: o.y + 12.5 * s))
        arrow.move(to: CGPoint(x: o.x + 8.75 * s, y: o.y + 15.75 * s))
        arrow.addLine(to: CGPoint(x: o.x + 12 * s, y: o.y + 12.5 * s))
        arrow.addLine(to: CGPoint(x: o.x + 15.25 * s, y: o.y + 15.75 * s))
        // Subtracted rather than even-odd filled, so the arrow's overlapping strokes stay one clean cut.
        return body.subtracting(arrow.strokedPath(StrokeStyle(lineWidth: 2.2 * s, lineCap: .round, lineJoin: .round)))
    }

    private static func grid(_ rect: CGRect) -> (CGPoint, CGFloat) {
        let s = min(rect.width, rect.height) / 24
        return (CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s), s)
    }

    /// For `Canvas`, which can't host a view: the same glyph drawn straight into the context.
    static func draw(in context: GraphicsContext, rect: CGRect, color: Color) {
        context.fill(dock(in: rect), with: .color(color.opacity(0.45)))
        context.fill(robot(in: rect), with: .color(color))
    }
}

/// An SF Symbol, or the app's own dock glyph when given `DockGlyph.symbolName`.
struct AppSymbol: View {
    let name: String

    var body: some View {
        if name == DockGlyph.symbolName {
            DockGlyph()
        } else {
            Image(systemName: name)
        }
    }
}
