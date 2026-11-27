import PillotCore
import SwiftUI
import UIKit

// Neubrutalism, the cute way: flat pastel fills, a thick ink outline and a hard offset shadow with no blur.
// Pressing a button pushes it into its shadow. Ink flips in dark mode (cream outlines on a dark page) so the
// outlines and shadows stay visible; text on pastel fills is always dark ink, which keeps it above WCAG AA.
enum Palette {
    /// Outlines, hard shadows and main text.
    static let ink = Color(light: 0x161616, dark: 0xF4EDE4)
    static let text = ink
    static let textSecondary = Color(light: 0x4F4742, dark: 0xC9BFB5)
    /// Text and icons on pastel fills, in both modes.
    static let onFill = Color(hex: 0x161616)

    static let background = Color(light: 0xFFF3E6, dark: 0x17131C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x262030)

    static let pink = Color(hex: 0xFF8FC0)
    static let yellow = Color(hex: 0xFFD84D)
    static let mint = Color(hex: 0x7CE3B8)
    static let lavender = Color(hex: 0xB8A6FF)
    static let sky = Color(hex: 0x88CBFF)
    static let peach = Color(hex: 0xFFAF7A)
    static let coral = Color(hex: 0xFF7B7B)
    static let stone = Color(hex: 0xE3DAD0)

    static let primary = pink
}

/// The selection pill of a row of equal-width items, drawn behind them and moved by offset, so it always slides
/// under the labels.
struct SlidingPill: View {
    let index: Int
    let count: Int
    let spacing: CGFloat
    let radius: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(max(1, count))
            if width.isFinite, width > 0 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.yellow)
                    .strokeBorder(Palette.ink, lineWidth: lineWidth)
                    .frame(width: width)
                    .offset(x: CGFloat(index) * (width + spacing))
            }
        }
    }
}

/// A short burst of paper bits when a dose is taken. One Canvas draws every piece, and the timeline only runs while a
/// burst is in the air. With Reduce Motion there is no burst; the haptic still plays.
struct Confetti: View {
    /// Bumped once per burst.
    let trigger: Int
    @State private var start: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let duration: TimeInterval = 1.5
    private static let gravity: Double = 950

    private struct Piece {
        let angle, speed, spin: Double
        let color: Color
        let size: CGSize
    }

    // Fixed scatter from the index, so every burst looks alike and nothing random is drawn per frame.
    private static let pieces: [Piece] = (0..<48).map { i in
        let f = Double(i)
        // Cheap repeatable noise in 0..<1.
        func noise(_ seed: Double) -> Double { abs(sin(f * 12.9898 + seed) * 43758.5453).truncatingRemainder(dividingBy: 1) }
        return Piece(angle: -.pi / 2 + (noise(1) - 0.5) * 2.4,
                     speed: 220 + 620 * noise(7),
                     spin: (i.isMultiple(of: 2) ? 1 : -1) * (4 + f.truncatingRemainder(dividingBy: 5)),
                     color: Swatch.colors[i % Swatch.colors.count],
                     size: i.isMultiple(of: 3) ? CGSize(width: 11, height: 11) : CGSize(width: 8, height: 16))
    }

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            Canvas { canvas, size in
                guard let start else { return }
                let t = context.date.timeIntervalSince(start)
                guard t >= 0, t < Self.duration else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.8)
                let fade = min(1, (Self.duration - t) / 0.35)
                for piece in Self.pieces {
                    let x = origin.x + cos(piece.angle) * piece.speed * t
                    let y = origin.y + sin(piece.angle) * piece.speed * t + 0.5 * Self.gravity * t * t
                    var bit = canvas
                    bit.opacity = fade
                    bit.translateBy(x: x, y: y)
                    bit.rotate(by: .radians(piece.spin * t))
                    let rect = CGRect(origin: CGPoint(x: -piece.size.width / 2, y: -piece.size.height / 2), size: piece.size)
                    let shape = Path(roundedRect: rect, cornerRadius: 2)
                    bit.fill(shape, with: .color(piece.color))
                    bit.stroke(shape, with: .color(Palette.ink), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            guard !reduceMotion else { return }
            let burst = Date.now
            start = burst
            Task {
                try? await Task.sleep(for: .seconds(Self.duration))
                // A newer burst keeps its own clock.
                if start == burst { start = nil }
            }
        }
    }
}

/// Motion for small state changes: quick, a touch of spring, never in the way. With Reduce Motion, changes are instant.
enum Motion {
    static let snappy = Animation.snappy(duration: 0.3, extraBounce: 0.06)

    static func snappy(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : snappy }
}

enum Neo {
    /// Outline of cards and large controls.
    static let border: CGFloat = 2.25
    /// Small elements (chips, pills, cells) read heavier at the same width, so they get a thinner line.
    static let thinBorder: CGFloat = 2
    static let shadow: CGFloat = 4
    static let radius: CGFloat = 16
}

/// The colors and icons a medication can wear. Stored as indexes and names, so the data stays UI free.
enum Swatch {
    static let colors: [Color] = [Palette.pink, Palette.yellow, Palette.mint, Palette.lavender, Palette.sky, Palette.peach]
    static let icons = ["pills.fill", "capsule.fill", "drop.fill", "heart.fill", "leaf.fill", "sun.max.fill", "moon.fill", "sparkles"]

    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

// Dose status. Fixed colors: green = taken, yellow = late, blue = missed but made up, red = missed, grey = paused.
// Always paired with a label and an icon, never color alone.
enum DoseStatus {
    case taken, late, madeUp, missed, paused, upcoming, skipped
    /// Due now, before the deadline: not late yet.
    case due
    /// A past day before the user started, with nothing to report.
    case noData

    var label: String {
        switch self {
        case .taken: L("Đã uống", "Taken")
        case .late: L("Uống trễ", "Late")
        case .madeUp: L("Uống bù", "Made up")
        case .missed: L("Hụt", "Missed")
        case .paused: L("Tạm dừng", "Paused")
        case .skipped: L("Bỏ qua", "Skipped")
        case .upcoming: L("Sắp tới", "Upcoming")
        case .due: L("Tới giờ", "Due now")
        case .noData: L("Chưa có dữ liệu", "No data")
        }
    }

    var icon: String {
        switch self {
        case .taken: "checkmark"
        case .late: "clock.badge.exclamationmark"
        case .madeUp: "arrow.uturn.backward"
        case .missed: "xmark"
        case .paused: "pause.fill"
        case .skipped: "forward.end.fill"
        case .upcoming: "hourglass"
        case .due: "bell.fill"
        case .noData: "minus"
        }
    }

    var fill: Color {
        switch self {
        case .taken: Color(hex: 0x7CE3A6)
        case .late, .due: Palette.yellow
        case .madeUp: Palette.sky
        case .skipped: Palette.lavender
        case .missed: Palette.coral
        case .paused, .upcoming, .noData: Palette.stone
        }
    }
}

extension DoseStatus {
    init(_ status: PillotCore.DoseStatus) {
        switch status {
        case .taken: self = .taken
        case .late: self = .late
        case .missed: self = .missed
        case .paused: self = .paused
        case .madeUp: self = .madeUp
        case .skipped: self = .skipped
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: Surfaces

extension View {
    /// A flat fill with an ink outline and a hard shadow. `shadow` 0 draws the pressed state.
    func neo(_ fill: Color = Palette.surface, radius: CGFloat = Neo.radius, shadow: CGFloat = Neo.shadow) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(fill, in: shape)
            .overlay(shape.strokeBorder(Palette.ink, lineWidth: radius <= 12 ? Neo.thinBorder : Neo.border))
            .background(shape.fill(Palette.ink).offset(x: shadow, y: shadow))
    }

    /// A padded card.
    func card(_ fill: Color = Palette.surface) -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neo(fill)
    }
}

/// A rounded square sticker with an SF Symbol, for medications and section headers.
struct IconBadge: View {
    let icon: String
    var fill: Color = Palette.pink
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(Palette.onFill)
            .frame(width: size, height: size)
            .neo(fill, radius: size * 0.3, shadow: 2.5)
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let status: DoseStatus

    var body: some View {
        Label(status.label, systemImage: status.icon)
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(Palette.onFill)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .neo(status.fill, radius: 10, shadow: 2)
    }
}

/// A callout inside a card: warnings, refill notes, sync errors.
struct Callout: View {
    let text: String
    let icon: String
    var fill: Color = Palette.coral

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.weight(.bold))
        .foregroundStyle(Palette.onFill)
        .padding(12)
        .neo(fill, radius: 12, shadow: 2.5)
    }
}

/// A section title above a group of cards.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.weight(.black))
            .foregroundStyle(Palette.text)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Controls

/// The chunky button. Disabled buttons look flat and faded, or users think the app froze.
struct NeoButtonStyle: ButtonStyle {
    var fill: Color = Palette.primary
    var large = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        let depth = isEnabled ? (pressed ? 0 : Neo.shadow) : 0
        configuration.label
            .font(large ? .title3.weight(.black) : .body.weight(.heavy))
            .multilineTextAlignment(.center)
            .foregroundStyle(Palette.onFill)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: large ? 58 : 46)
            .neo(fill, radius: large ? 16 : 12, shadow: depth)
            .offset(x: Neo.shadow - depth, y: Neo.shadow - depth)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.snappy(duration: 0.12), value: pressed)
    }
}

/// A small inline action, like "Undo" or "Mark made up". Always a light or pastel fill with dark text.
struct ChipButtonStyle: ButtonStyle {
    var fill: Color = Palette.surfaceOnFill
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let depth: CGFloat = configuration.isPressed ? 0 : 2.5
        configuration.label
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(Palette.onFill)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .neo(fill, radius: 10, shadow: depth)
            .offset(x: 2.5 - depth, y: 2.5 - depth)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// An outlined pill switch.
struct NeoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Palette.mint : Palette.stone)
                        .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: Neo.thinBorder))
                        .frame(width: 54, height: 32)
                    Circle().fill(Color.white)
                        .overlay(Circle().strokeBorder(Palette.ink, lineWidth: Neo.thinBorder))
                        .frame(width: 32, height: 32)
                }
                .animation(.snappy(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Segmented choice in the same style, for two to four short options.
struct NeoSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(selected ? Palette.onFill : Palette.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // One pill behind every label that slides to the selection.
        .background {
            if let index = options.firstIndex(where: { $0.value == selection }) {
                SlidingPill(index: index, count: options.count, spacing: 6, radius: 10, lineWidth: Neo.thinBorder)
            }
        }
        .padding(5)
        .neo(Palette.background, radius: 14, shadow: 0)
        .animation(Motion.snappy(reduceMotion), value: selection)
    }
}

/// Minus and plus buttons around a value, in the same style. Holding a button repeats it; with `editable`, the value
/// can also be typed.
struct NeoStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// Shown after the value, for example "phút" or "pills".
    let unit: String
    var step = 1
    var editable = false

    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus").frame(width: 22) }
                .buttonStyle(ChipButtonStyle())
                .buttonRepeatBehavior(.enabled)
                .disabled(value <= range.lowerBound)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                if editable {
                    TextField("", text: $text)
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .fixedSize()
                        .frame(minWidth: 28)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onChange(of: text) { _, typed in
                            let digits = String(typed.filter(\.isNumber).prefix(String(range.upperBound).count))
                            if digits != typed { text = digits }
                            if let number = Int(digits), range.contains(number) { value = number }
                        }
                        .onChange(of: focused) { _, isFocused in if !isFocused { text = String(value) } }
                        .onChange(of: value) { _, number in if !focused || Int(text) != number { text = String(number) } }
                        .onAppear { text = String(value) }
                } else {
                    Text("\(value)")
                        .contentTransition(.numericText(value: Double(value)))
                        .animation(Motion.snappy(reduceMotion), value: value)
                }
                Text(unit)
            }
            .font(.body.weight(.heavy).monospacedDigit())
            .foregroundStyle(Palette.text)
            // Wide enough for the longest value, so the plus button does not move while counting.
            .frame(minWidth: 110)
            Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus").frame(width: 22) }
                .buttonStyle(ChipButtonStyle())
                .buttonRepeatBehavior(.enabled)
                .disabled(value >= range.upperBound)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: editable ? .contain : .ignore)
        .accessibilityLabel("\(value) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

/// A text field in an outlined box.
struct NeoField: View {
    let title: String
    @Binding var text: String
    var limit = AppModel.nameLimit

    var body: some View {
        TextField(title, text: Binding(get: { text }, set: { text = String($0.prefix(limit)) }))
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .neo(Palette.surface, radius: 14, shadow: 0)
    }
}

/// A row inside a settings card: a label on the left, a control or value on the right.
struct NeoRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                labels
                Spacer(minLength: 8)
                trailing
            }
            VStack(alignment: .leading, spacing: 8) {
                labels
                trailing
            }
        }
        .frame(minHeight: 44)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.text)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

/// A thin ink divider between rows of a card.
struct InkDivider: View {
    var body: some View {
        Rectangle().fill(Palette.ink.opacity(0.15)).frame(height: 1.5)
    }
}

/// A full-height screen that still scrolls when large text or the keyboard needs more room.
/// Spacers inside keep their centering at normal sizes because the content is at least as tall as the screen.
struct FullScreenScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// A faint pattern of small pills and dots behind every screen, so the cream background is not one flat colour.
/// It is drawn in screen coordinates, so the part behind the tab bar lines up with the part behind the screen, and it
/// stays put while the content scrolls over it. One Canvas per area, redrawn only when its size changes.
struct PillPattern: View {
    private static let step: CGFloat = 46

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            Canvas { context, size in
                let ink = GraphicsContext.Shading.color(Palette.ink.opacity(0.06))
                let step = Self.step
                let startRow = Int(floor(origin.y / step)) - 1
                let rows = Int(ceil(size.height / step)) + 2
                let startColumn = Int(floor(origin.x / step)) - 1
                let columns = Int(ceil(size.width / step)) + 2
                for row in startRow..<(startRow + rows) {
                    for column in startColumn..<(startColumn + columns) {
                        // Every other row shifts half a step, like a brick wall, so no straight lines run down the screen.
                        let x = (CGFloat(column) + (row.isMultiple(of: 2) ? 0 : 0.5)) * step - origin.x
                        let y = CGFloat(row) * step - origin.y
                        if (row + column).isMultiple(of: 3) {
                            context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: ink)
                        } else {
                            var pill = context
                            pill.translateBy(x: x, y: y)
                            pill.rotate(by: .degrees((row + column).isMultiple(of: 2) ? -35 : 35))
                            let shape = Path(roundedRect: CGRect(x: -8, y: -3.5, width: 16, height: 7), cornerRadius: 3.5)
                            pill.stroke(shape, with: ink, lineWidth: 1.5)
                            pill.stroke(Path { $0.move(to: CGPoint(x: 0, y: -3.5)); $0.addLine(to: CGPoint(x: 0, y: 3.5)) }, with: ink, lineWidth: 1.5)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The screen background: cream with the faint pill pattern.
    func screenBackground() -> some View {
        background { ZStack { Palette.background; PillPattern() }.ignoresSafeArea() }
    }
}
