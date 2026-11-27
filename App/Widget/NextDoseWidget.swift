import AppIntents
import PillotCore
import SwiftUI
import WidgetKit

/// The small and lock screen widgets: one medication. Edit Widget picks which; without a pick it follows the next due
/// dose. The kind stays "NextDose", so small widgets placed before 0.4.0 keep working unpicked.
struct NextDoseWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NextDose", intent: SelectMedicationIntent.self, provider: NextDoseProvider()) { entry in
            NextDoseView(entry: entry)
        }
        .configurationDisplayName("Pillot")
        .description(NextDoseEntry.english ? "One medication. Touch and hold, Edit Widget to pick it." : "Một thuốc. Giữ widget, chọn Sửa widget để chọn thuốc.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

/// The medium widget lists the next three doses, so it has nothing to pick (0.4.0 gave it the picker too).
struct NextDoseListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextDoseList", provider: NextDoseListProvider()) { entry in
            NextDoseView(entry: entry)
        }
        .configurationDisplayName("Pillot")
        .description(NextDoseEntry.english ? "Your next doses." : "Các lần uống sắp tới.")
        .supportedFamilies([.systemMedium])
    }
}

struct NextDoseEntry: TimelineEntry {
    enum State { case due, late, upcoming, taken, resting }

    struct Item: Identifiable {
        let id: UUID
        let name: String
        let color: Int
        let icon: String
        let state: State
        /// The dose time, when it was taken, or when reminders start again while resting.
        let time: Date

        /// Due or late.
        var isDue: Bool { state == .due || state == .late }
        /// The home screen widgets offer "Taken" whenever the app does: due, late, or early for the next dose.
        var canTake: Bool { isDue || state == .upcoming }
    }

    let date: Date
    let items: [Item]
    /// False when the widget cannot read the app's data (no App Group after signing, or never opened).
    let readable: Bool

    static var english: Bool { SharedStorage.defaults?.string(forKey: "language") == "en" }

    /// `pinned` comes first when it still exists, then the rest in the usual order.
    static func make(_ medications: [Medication]?, at now: Date, pinned: UUID? = nil) -> NextDoseEntry {
        guard let medications else { return NextDoseEntry(date: now, items: [], readable: false) }
        // Taken-when-needed and finished medications have no next dose to show.
        let scheduled = medications.filter { !$0.settings.asNeeded && !$0.settings.courseEnded(now: now) }
        let items = scheduled.compactMap { medication -> Item? in
            let summary = medication.planner.summary(now: now)
            let dose = summary.dose
            guard dose.dueAt != .distantFuture else { return nil }
            let state: State
            var time = dose.dueAt
            if let until = summary.restingUntil, now < dose.dueAt {
                state = .resting
                time = max(until, dose.dueAt)
            } else if now >= dose.dueAt {
                state = now < dose.deadlineAt ? .due : .late
            } else if let taken = summary.lastTaken?.takenAt, medication.settings.showsAsTaken(taken, now: now) {
                // The same rule as Today, so the widget never says "Next" for a dose the app shows as taken.
                state = .taken
                // When it was taken, not the next dose: "Taken 21:00" must not read as a time still to come.
                time = taken
            } else {
                state = .upcoming
            }
            return Item(id: medication.id, name: medication.name, color: medication.color, icon: medication.icon, state: state, time: time)
        }
        // Due and late first, then by time.
        let rank: (State) -> Int = { [.late: 0, .due: 1, .upcoming: 2, .taken: 3, .resting: 4][$0]! }
        let sorted = items.sorted { (rank($0.state), $0.time) < (rank($1.state), $1.time) }
        let first = sorted.filter { $0.id == pinned }
        return NextDoseEntry(date: now, items: first + sorted.filter { $0.id != pinned }, readable: true)
    }
}

/// A medication as the widget's Edit Widget menu lists it.
struct MedicationEntity: AppEntity {
    let id: UUID
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Medication"
    static let defaultQuery = MedicationQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// Reads the medications from the App Group, like the widget itself.
struct MedicationQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [MedicationEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MedicationEntity] { all() }

    private func all() -> [MedicationEntity] {
        (NextDoseProvider.load() ?? []).map { MedicationEntity(id: $0.id, name: $0.name) }
    }
}

struct SelectMedicationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Medication"
    static let description = IntentDescription("The medication shown first. Leave it empty to follow the next due dose.")

    @Parameter(title: "Medication")
    var medication: MedicationEntity?
}

struct NextDoseProvider: AppIntentTimelineProvider {
    static func load() -> [Medication]? {
        guard let url = SharedStorage.sharedStateURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? PlanStore(url: url).load()
    }

    func placeholder(in context: Context) -> NextDoseEntry {
        NextDoseEntry(date: .now, items: [.init(id: UUID(), name: "Vitamin D", color: 1, icon: "sun.max.fill", state: .upcoming, time: .now.addingTimeInterval(3600))], readable: true)
    }

    func snapshot(for configuration: SelectMedicationIntent, in context: Context) async -> NextDoseEntry {
        context.isPreview ? placeholder(in: context) : NextDoseEntry.make(Self.load(), at: .now, pinned: configuration.medication?.id)
    }

    func timeline(for configuration: SelectMedicationIntent, in context: Context) async -> Timeline<NextDoseEntry> {
        Self.timeline(pinned: configuration.medication?.id)
    }

    /// Entries at the next dose's transitions, so the widget can update without the app running.
    static func timeline(pinned: UUID?) -> Timeline<NextDoseEntry> {
        let now = Date.now
        let medications = load()
        var moments: Set<Date> = []
        let tomorrow = now.addingTimeInterval(24 * 3600)
        for medication in medications ?? [] where !medication.settings.asNeeded && !medication.settings.courseEnded(now: now) {
            let planner = medication.planner
            let dose = planner.currentDose(now: now)
            // The planner considers the dose pending up to and including lateUntil.
            let momentsForDose: [Date?] = [dose.dueAt, dose.deadlineAt, dose.lateUntil.addingTimeInterval(1),
                                          planner.restingUntil(now: now), medication.settings.courseEnd]
            for moment in momentsForDose.compactMap({ $0 }) where moment > now && moment < tomorrow {
                moments.insert(moment)
            }
        }
        let entries = [now] + moments.sorted().prefix(20)
        return Timeline(entries: entries.map { NextDoseEntry.make(medications, at: $0, pinned: pinned) }, policy: .after(now.addingTimeInterval(6 * 3600)))
    }
}

struct NextDoseListProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextDoseEntry { NextDoseProvider().placeholder(in: context) }

    func getSnapshot(in context: Context, completion: @escaping (NextDoseEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NextDoseEntry.make(NextDoseProvider.load(), at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextDoseEntry>) -> Void) {
        completion(NextDoseProvider.timeline(pinned: nil))
    }
}

/// The app's look, repeated here because the widget is a separate target: pastel fills, ink outlines.
private enum WidgetLook {
    static let swatches: [UInt32] = [0xFF8FC0, 0xFFD84D, 0x7CE3B8, 0xB8A6FF, 0x88CBFF, 0xFFAF7A]
    static let ink = Color(red: 0.086, green: 0.086, blue: 0.086)

    static func color(_ index: Int) -> Color {
        let hex = swatches[((index % swatches.count) + swatches.count) % swatches.count]
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct NextDoseView: View {
    let entry: NextDoseEntry
    @Environment(\.widgetFamily) private var family

    private var en: Bool { NextDoseEntry.english }

    private func label(_ state: NextDoseEntry.State) -> String {
        switch state {
        case .due: en ? "Due now" : "Tới giờ"
        case .late: en ? "Late" : "Trễ rồi"
        case .upcoming: en ? "Next" : "Sắp tới"
        case .taken: en ? "Taken" : "Đã uống"
        case .resting: en ? "Paused" : "Tạm nghỉ"
        }
    }

    private func clock(_ date: Date) -> String { TimeFormatting.clockTime(date, in: VietnamClock.timeZone) }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family == .systemSmall, let first = entry.items.first { WidgetLook.color(first.color) } else { Color(white: 0.98) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !entry.readable || entry.items.isEmpty {
            Text(entry.readable ? (en ? "No scheduled doses" : "Không có liều theo lịch") : (en ? "Open Pillot once" : "Mở Pillot một lần"))
                .font(.headline.weight(.heavy))
        } else {
            switch family {
            case .accessoryInline:
                let item = entry.items[0]
                Label("\(clock(item.time)) \(item.name)", systemImage: item.icon)
            case .accessoryCircular:
                let item = entry.items[0]
                VStack(spacing: 0) {
                    Image(systemName: item.state == .due || item.state == .late ? "bell.fill" : item.icon)
                    Text(clock(item.time)).font(.caption.weight(.bold)).minimumScaleFactor(0.6)
                }
            case .accessoryRectangular:
                let item = entry.items[0]
                let rows = VStack(alignment: .leading, spacing: 1) {
                    Text("\(clock(item.time)) · \(item.name)").font(.headline).lineLimit(1)
                    Text(item.isDue ? (en ? "Tap when taken" : "Chạm khi đã uống") : label(item.state)).font(.caption).lineLimit(1)
                }
                if item.isDue {
                    Button(intent: MarkTakenIntent(id: item.id, dueAt: item.time)) { rows }.buttonStyle(.plain)
                } else {
                    rows
                }
            case .systemSmall:
                small(entry.items[0])
            default:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.items.prefix(3)) { item in row(item) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func small(_ item: NextDoseEntry.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: item.icon).font(.title3.weight(.bold))
            Spacer(minLength: 0)
            Text(item.name).font(.headline.weight(.heavy)).lineLimit(2)
            Text(clock(item.time)).font(.system(size: 30, weight: .black, design: .rounded)).minimumScaleFactor(0.7)
            if item.isDue {
                takenButton(item, title: en ? "Taken" : "Đã uống")
            } else {
                HStack {
                    Text(label(item.state)).font(.caption.weight(.heavy))
                    Spacer(minLength: 4)
                    if item.canTake { takenButton(item, title: nil) }
                }
            }
        }
        .foregroundStyle(WidgetLook.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: NextDoseEntry.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.caption.weight(.bold))
                .frame(width: 26, height: 26)
                .background(WidgetLook.color(item.color), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WidgetLook.ink, lineWidth: 1.5))
            Text(item.name).font(.subheadline.weight(.heavy)).lineLimit(1)
            Spacer(minLength: 4)
            Text(label(item.state)).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text(clock(item.time)).font(.subheadline.weight(.black).monospacedDigit())
            if item.canTake { takenButton(item, title: nil) }
        }
        .foregroundStyle(WidgetLook.ink)
    }

    /// Marks this medication as taken without opening the app. The app saves, reschedules and reloads the widget.
    private func takenButton(_ item: NextDoseEntry.Item, title: String?) -> some View {
        Button(intent: MarkTakenIntent(id: item.id, dueAt: item.time)) {
            Label(title ?? (en ? "Taken" : "Đã uống"), systemImage: "checkmark")
                .labelStyle(TakenLabelStyle(showsTitle: title != nil))
                .font(.caption.weight(.black))
                .foregroundStyle(WidgetLook.ink)
                .padding(.horizontal, title == nil ? 6 : 10)
                .frame(minHeight: 26)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WidgetLook.ink, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(en ? "Taken \(item.name)" : "Đã uống \(item.name)")
    }
}

/// Icon only in a list row, icon and title on the small widget.
private struct TakenLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}
