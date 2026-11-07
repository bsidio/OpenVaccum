import SwiftUI

/// Spacing and corner radii. Everything on screen uses these values.
enum Metric {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 14
    static let hitTarget: CGFloat = 44
    static let barHeight: CGFloat = 58
}

extension Theme {
    /// The selected segment, in the values the system's own segmented control uses. `paper`
    /// won't do: in dark mode it's the same colour as the track.
    static let pill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 99 / 255, green: 99 / 255, blue: 102 / 255, alpha: 1) : .white
    })
    /// Secondary text that has to reach 4.5:1. `slate` is 3.4:1 on white, and 3.1:1 on a tone's wash.
    static let quietInk = ink.opacity(0.65)
    /// A zone the robot is cleaning now. `green` is only 1.5:1 on a room in light mode, too faint
    /// for a thin line, and this reaches 3:1 on every room colour.
    static let working = Color(uiColor: UIColor { traits in
        let (red, green, blue): (CGFloat, CGFloat, CGFloat) =
            switch (traits.userInterfaceStyle == .dark, traits.accessibilityContrast == .high) {
            case (false, false): (26, 127, 68)
            case (true, false): (94, 212, 154)
            case (false, true): (15, 95, 49)
            case (true, true): (168, 240, 203)
            }
        return UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    })
}

/// How something is doing, in one place, so every screen shows it the same way.
enum Tone {
    case neutral, good, warning, critical

    var color: Color {
        switch self {
        case .neutral: return Theme.slate
        case .good: return Theme.green
        case .warning: return Theme.amber
        case .critical: return Theme.rose
        }
    }

    /// The fill behind a notice. Text on it uses `Theme.ink`: tinted text falls under 4.5:1 here.
    var wash: Color { color.opacity(0.12) }

    var symbol: String {
        switch self {
        case .neutral: return "info.circle.fill"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

// MARK: - Surfaces

extension View {
    /// Liquid Glass on iOS 26, and a system material before that.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            // A material nearly vanishes on the page colour, so it needs an edge and a lift.
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }

    /// The standard card: a solid surface with a continuous corner.
    func card(padding: CGFloat = 16, radius: CGFloat = Metric.cardRadius) -> some View {
        self.padding(padding)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Gives a list or form the app's background.
    func themedList() -> some View {
        scrollContentBackground(.hidden).background(Theme.mist)
    }
}

/// Presses in slightly, like system controls. Used by every custom button.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Icons

/// A white symbol on a coloured tile, as in iOS Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A round glass button holding one symbol, for toolbars over content.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    var tint: Color = Theme.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .glass(in: Circle(), interactive: true)
        .accessibilityLabel(label)
    }
}

// MARK: - Building blocks

/// A tappable tile: a symbol above a short label. Shows when it's working or selected.
struct ActionTile<Icon: View>: View {
    let title: String
    var tint: Color = Theme.cobalt
    var selected = false
    var busy = false
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(selected ? tint : tint.opacity(0.14))
                    if busy {
                        ProgressView().tint(selected ? Theme.onCobalt : tint)
                    } else {
                        icon()
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(selected ? Theme.onCobalt : tint)
                            .symbolEffect(.bounce, value: selected)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 46, height: 46)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .opacity(isEnabled ? 1 : 0.4)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metric.controlRadius + 2, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Metric.controlRadius + 2, style: .continuous)
                        .strokeBorder(tint, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(busy ? "Working" : "")
    }
}

extension ActionTile where Icon == Image {
    init(title: String, symbol: String, tint: Color = Theme.cobalt, selected: Bool = false, busy: Bool = false,
         action: @escaping () -> Void) {
        self.init(title: title, tint: tint, selected: selected, busy: busy, action: action) { Image(systemName: symbol) }
    }
}

/// Something the robot or dock reports: a symbol, a name and its state.
struct StatusTile: View {
    let title: String
    let value: String
    let symbol: String
    var tone: Tone = .good

    private var isAlert: Bool { tone == .warning || tone == .critical }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tone == .neutral ? Theme.slate : tone.color)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.quietInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(isAlert ? tone.wash : Theme.paper, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A large number with a caption, as in the Fitness app.
struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = Theme.cobalt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.footnote)
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, radius: Metric.controlRadius + 2)
        .accessibilityElement(children: .combine)
    }
}

/// A one-line notice. Tappable when it can take you somewhere useful.
struct Banner: View {
    let text: String
    var tone: Tone = .warning
    var action: (() -> Void)?

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: tone.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.quietInk)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: Metric.hitTarget, alignment: .leading)
        .background(tone.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var body: some View {
        if let action {
            Button(action: action) { content }.buttonStyle(.pressable)
        } else {
            content
        }
    }
}

/// A heading for a group of tiles, matching list section headers.
struct GroupTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The app's segmented control: a sliding pill over the robot's options.
struct SlidingPicker<Value: Hashable>: View {
    private static var segmentHeight: CGFloat { 36 }
    /// How far a segment takes touches past its edges, to reach `Metric.hitTarget` without
    /// making the control taller. The floor plan editor sets aside a fixed height for it.
    private static var hitOverhang: CGFloat { (Metric.hitTarget - segmentHeight) / 2 }

    let options: [Value]
    let selection: Value?
    let title: (Value) -> String
    let onSelect: (Value) -> Void
    @Namespace private var pill
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button { onSelect(option) } label: {
                    Text(title(option))
                        .font(.subheadline.weight(isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? Theme.ink : Theme.slate)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: Self.segmentHeight)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Theme.pill)
                                    .strokeBorder(Theme.ink.opacity(contrast == .increased ? 0.6 : 0), lineWidth: 1)
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .padding(.vertical, Self.hitOverhang)
                        .contentShape(Rectangle())
                        .padding(.vertical, -Self.hitOverhang)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .animation(.snappy(duration: 0.25), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Floor plan

/// A dropped pin: a teardrop whose head sits well above its tip, so a finger doesn't cover
/// it and it can't be mistaken for the round robot marker.
struct PlanPin: View {
    /// From the tip to the middle of the head.
    static let headRise: CGFloat = 44
    static let headSize: CGFloat = 34
    private static let tipSize: CGFloat = 6
    /// From the middle of this view down to the tip, for placing the tip on a point.
    static let tipDrop = (headRise + (headSize - tipSize) / 2) / 2

    /// Off the floor, where lifting would send it back.
    var faded = false

    private var color: Color { faded ? Theme.slate : Theme.cobalt }

    /// The same pin for a Canvas, with its tip on `tip`.
    static func draw(at tip: CGPoint, in context: GraphicsContext) {
        let head = CGPoint(x: tip.x, y: tip.y - headRise)
        let disc = Path(ellipseIn: CGRect(x: head.x - headSize / 2, y: head.y - headSize / 2, width: headSize, height: headSize))
        var marker = context
        marker.addFilter(.shadow(color: .black.opacity(0.25), radius: 3, y: 2))
        marker.drawLayer { layer in
            layer.fill(Path(CGRect(x: tip.x - 1, y: head.y, width: 2, height: headRise)), with: .color(Theme.cobalt))
            layer.fill(Path(ellipseIn: CGRect(x: tip.x - tipSize / 2, y: tip.y - tipSize / 2, width: tipSize, height: tipSize)),
                       with: .color(Theme.cobalt))
            layer.fill(disc, with: .style(Theme.cobalt.gradient))
            layer.stroke(disc, with: .color(.white), lineWidth: 2.5)
            layer.draw(Text(Image(systemName: "mappin")).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onCobalt), at: head)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(color.gradient)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .overlay(Image(systemName: "mappin").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onCobalt))
                .frame(width: Self.headSize, height: Self.headSize)
            Rectangle()
                .fill(color)
                .frame(width: 2, height: Self.headRise - (Self.headSize + Self.tipSize) / 2)
            Circle()
                .fill(color)
                .frame(width: Self.tipSize, height: Self.tipSize)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }
}

// MARK: - Feedback

/// A short note above the floating bar, for anything that was refused. It leaves by itself,
/// and VoiceOver reads it out, so the top toast and its warning buzz aren't spent on a stray tap.
struct BarNote: View {
    private static let seconds = 2.5

    let text: String
    let onDone: () -> Void

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glass(in: Capsule())
            .allowsHitTesting(false)
            .task {
                AccessibilityNotification.Announcement(text).post()
                try? await Task.sleep(for: .seconds(Self.seconds))
                // Also on leaving the screen, or the note would be waiting on the way back.
                onDone()
            }
    }
}

/// A short confirmation that something happened.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var symbol = "checkmark.circle.fill"
    var isProblem = false

    private static var lastClaimed: UUID?

    /// True only the first time it's asked. A sheet's host and the one beneath it both see
    /// every toast, and the haptic and the spoken message should still happen once.
    func claim() -> Bool {
        guard Self.lastClaimed != id else { return false }
        Self.lastClaimed = id
        return true
    }
}

/// Shows toasts as glass at the top of the screen: a capsule for one line, and a rounded panel
/// for more. There's no line limit: a firmware error can run to 200 characters at any text size,
/// and its ending is often the part that says what to do.
struct ToastHost: ViewModifier {
    let toast: Toast?
    var haptic: (PlanHaptic) -> Void = { $0.play() }
    var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    Label(toast.message, systemImage: toast.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .glass(in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                        .padding(.top, 6)
                        .padding(.horizontal, 24)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .id(toast.id)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.snappy(duration: 0.3), value: toast)
            // Initial as well: a failure while connecting is up before this screen is.
            .onChange(of: toast, initial: true) { _, new in
                guard let new, new.claim() else { return }
                haptic(new.isProblem ? .warning : .success)
                announce(new.message)
            }
    }
}
