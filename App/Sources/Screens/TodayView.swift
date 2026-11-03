import PillotCore
import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.editMedication) private var editMedication
    @State private var tapped = 0
    /// The medication whose "skip this dose" waits for confirmation.
    @State private var confirmSkip: Medication?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Side by side normally, stacked at accessibility text sizes so nothing overflows the screen.
    private var rowLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        Group {
            // Redraws every minute for the countdowns. Uses the real time, not `context.date` (the start of the minute),
            // otherwise a dose taken a moment ago lies after `now` and is ignored.
            TimelineView(.everyMinute) { _ in
                let now = Date.now
                // Every card, the sort and the week strip read from these, walked once per data change or minute.
                let summaries = model.summaries(now: now)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(now: now)
                        if let issue = model.issue { Callout(text: issue, icon: "exclamationmark.octagon.fill") }
                        if let message = model.message { messageCard(message) }
                        if model.medications.isEmpty {
                            emptyCard
                        } else {
                            let missed = model.medications.flatMap { med in summaries[med.id]!.outstandingMissed().map { (med, $0) } }
                            if !missed.isEmpty { missedCard(missed) }
                            dueAllButton(now: now, summaries: summaries)
                            ForEach(sorted(summaries)) { medication in doseCard(medication, summaries[medication.id]!, now: now) }
                            weekCard(now: now, summaries: summaries)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    // No animation when a dose is taken: the cards reorder and change shape at once, and animating that
                    // crossfaded the old and new contents on top of each other (0.3.2). The confetti is the feedback.
                }
            }
            .screenBackground()
            .sensoryFeedback(.success, trigger: tapped)
            .overlay { Confetti(trigger: tapped) }
        }
    }

    /// Due first, then by the next reminder; paused ones last.
    private func sorted(_ summaries: [UUID: PlannerSummary]) -> [Medication] {
        model.medications.sorted { a, b in
            let sa = summaries[a.id]!, sb = summaries[b.id]!
            let pa = sa.restingUntil != nil, pb = sb.restingUntil != nil
            if pa != pb { return pb }
            return sa.dose.dueAt < sb.dose.dueAt
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TodayText.dayTitle(now))
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Palette.onFill)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .neo(Palette.mint, radius: 8, shadow: 2)
            Text(model.greeting)
                .font(.largeTitle.weight(.black))
                .foregroundStyle(Palette.text)
                // Long names wrap to two lines and shrink a little rather than push the layout.
                .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                .minimumScaleFactor(0.7)
        }
        .padding(.top, 12)
    }

    private func messageCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Lời nhắn từ \(model.partner)", "A note from \(model.partner)"))
                    .font(.footnote.weight(.heavy))
                Text(message)
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Palette.onFill)
        .card(Palette.pink)
        // A sticky note, slightly crooked.
        .rotationEffect(.degrees(-1.2))
        .padding(.vertical, 4)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconBadge(icon: "pills.fill", fill: Palette.lavender, size: 64)
            Text(L("Chưa có thuốc nào", "No medications yet"))
                .font(.title2.weight(.black))
            Text(L("Thêm thuốc đầu tiên, đặt giờ nhắc, vậy là xong. Mỗi loại thuốc có giờ và số lần uống riêng.",
                   "Add your first one and set a time, that's it. Every medication gets its own times and doses."))
                .font(.body.weight(.medium))
            Button(L("Thêm thuốc", "Add medication")) { editMedication(nil) }
                .buttonStyle(NeoButtonStyle(fill: Palette.surfaceOnFill))
        }
        .foregroundStyle(Palette.onFill)
        .card(Palette.yellow)
    }

    /// One tap for every medication due right now.
    @ViewBuilder
    private func dueAllButton(now: Date, summaries: [UUID: PlannerSummary]) -> some View {
        let due = model.medications.filter { $0.settings.pausedUntil(now: now) == nil && now >= summaries[$0.id]!.dose.dueAt }
        if due.count > 1 {
            Button(L("Đã uống cả \(due.count) thuốc", "Took all \(due.count)")) {
                tapped += 1
                Task { await model.markTaken(due.map(\.id)) }
            }
            .buttonStyle(NeoButtonStyle(fill: Palette.mint))
        }
    }

    @ViewBuilder
    private func doseCard(_ medication: Medication, _ summary: PlannerSummary, now: Date) -> some View {
        let dose = summary.dose
        let last = summary.lastTaken
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(icon: medication.icon, fill: Palette.surfaceOnFill, size: 42)
                VStack(alignment: .leading, spacing: 0) {
                    Text(medication.name)
                        .font(.title3.weight(.black))
                        .lineLimit(3)
                    Text(medication.scheduleSummary)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.onFillSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if medication.settings.courseEnded(now: now), let end = medication.settings.endDay {
                StatusPill(status: .paused)
                Text(L("Đã xong liệu trình, ngày cuối là \(TodayText.dayTitle(end)). Muốn uống tiếp thì sửa ngày kết thúc trong tab Thuốc.",
                       "Course finished, the last day was \(TodayText.dayTitle(end)). To keep going, change the end date in the Meds tab."))
                    .font(.callout.weight(.semibold))
            } else if medication.settings.asNeeded {
                asNeededBlock(medication, summary, now: now)
            } else if let until = medication.settings.pausedUntil(now: now) {
                StatusPill(status: .paused)
                Text(L("Tạm dừng nhắc tới \(TodayText.relativeDay(until, from: now)) \(TimeFormatting.vn(until)).", "Reminders paused until \(TodayText.relativeDay(until, from: now)) \(TimeFormatting.vn(until))."))
                    .font(.callout.weight(.semibold))
                Button(L("Nhắc lại ngay", "Resume now")) { model.update(medication.id) { $0.planner.resume(now: .now) } }
                    .buttonStyle(ChipButtonStyle(fill: Palette.surfaceOnFill))
            } else if now >= dose.dueAt {
                StatusPill(status: now < dose.deadlineAt ? .due : .late)
                timeBlock(title: L("Đã quá giờ uống", "Past dose time by"), time: TodayText.duration(now.timeIntervalSince(dose.dueAt)), showsVN: false,
                          local: L("giờ uống \(TodayText.relativeDay(dose.dueAt, from: now)) \(TimeFormatting.vn(dose.dueAt))",
                                   "dose time \(TodayText.relativeDay(dose.dueAt, from: now)) \(TimeFormatting.vn(dose.dueAt))"))
                Callout(text: now < dose.deadlineAt
                    ? L("Còn \(TodayText.duration(dose.deadlineAt.timeIntervalSince(now))) tới hạn chót", "\(TodayText.duration(dose.deadlineAt.timeIntervalSince(now))) left until the deadline")
                    : L("Đã quá hạn chót \(TodayText.duration(now.timeIntervalSince(dose.deadlineAt))). Xem tờ hướng dẫn thuốc hoặc hỏi bác sĩ, dược sĩ.", "Past the deadline by \(TodayText.duration(now.timeIntervalSince(dose.deadlineAt))). Check the leaflet or ask a doctor or pharmacist."),
                    icon: "exclamationmark.triangle.fill", fill: now < dose.deadlineAt ? Palette.surfaceOnFill : Palette.coral)
                takeButton(medication)
                skipButton(medication)
            } else if let until = summary.cycleBreakUntil {
                StatusPill(status: .paused)
                Text(L("Hôm nay là ngày nghỉ theo chu kỳ. Uống lại từ \(TodayText.relativeDay(until, from: now)), lúc \(TimeFormatting.vn(dose.dueAt)).",
                       "A day off in the cycle. Doses start again \(TodayText.relativeDay(until, from: now)) at \(TimeFormatting.vn(dose.dueAt))."))
                    .font(.callout.weight(.semibold))
            } else if let last, let takenAt = last.takenAt, medication.settings.showsAsTaken(takenAt, now: now) {
                StatusPill(status: .taken)
                timeBlock(title: L("Đã uống lúc", "Taken at"), time: TimeFormatting.clockTime(takenAt, in: VietnamClock.timeZone), showsVN: true,
                          local: TodayText.localLine(takenAt))
                Text(L("Lần sau: \(TodayText.relativeDay(dose.dueAt, from: now)) \(TimeFormatting.vn(dose.dueAt)), hạn chót \(TimeFormatting.clockTime(dose.deadlineAt, in: VietnamClock.timeZone)).", "Next: \(TodayText.relativeDay(dose.dueAt, from: now)) \(TimeFormatting.vn(dose.dueAt)), deadline \(TimeFormatting.clockTime(dose.deadlineAt, in: VietnamClock.timeZone))."))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.onFillSecondary)
                HStack(spacing: 10) {
                    let undoLeft = medication.settings.undoWindow - now.timeIntervalSince(takenAt)
                    if undoLeft > 0 {
                        Button(L("Hoàn tác (\(TodayText.duration(undoLeft)))", "Undo (\(TodayText.duration(undoLeft)))")) { Task { await model.undo(medication.id) } }
                            .buttonStyle(ChipButtonStyle(fill: Palette.surfaceOnFill))
                    }
                    realignButton(medication, summary)
                }
            } else {
                StatusPill(status: .upcoming)
                let day = TodayText.relativeDay(dose.dueAt, from: now)
                timeBlock(title: L("\(day.prefix(1).uppercased() + day.dropFirst()) lúc", "\(day.prefix(1).uppercased() + day.dropFirst()) at"),
                          time: TimeFormatting.clockTime(dose.dueAt, in: VietnamClock.timeZone), showsVN: true,
                          local: TodayText.localLine(dose.dueAt))
                Text(L("Còn \(TodayText.duration(dose.dueAt.timeIntervalSince(now)))", "In \(TodayText.duration(dose.dueAt.timeIntervalSince(now)))"))
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Palette.onFillSecondary)
                realignButton(medication, summary)
                takeButton(medication)
                if let skip = summary.undoableSkip {
                    Button(L("Hoàn tác bỏ qua", "Undo skip")) { model.update(medication.id) { $0.planner.removeRecord(id: skip.id) } }
                        .buttonStyle(ChipButtonStyle(fill: Palette.surfaceOnFill))
                } else {
                    Text(L("Uống sớm cũng được, lần sau sẽ nhắc sớm theo.", "Taking it early is fine, the next reminder moves earlier too."))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Palette.onFillSecondary)
                    skipButton(medication)
                }
            }
            if let pills = medication.settings.pills { pillsRow(pills, refill: medication.settings.refillReminder) }
        }
        .foregroundStyle(Palette.onFill)
        .card(Swatch.color(medication.color))
    }

    /// A medication taken when needed: how many today, when the last one was, and a warning when the next would be too
    /// soon or one too many. Taking it anyway is allowed; the app gives no advice beyond the limits the user set.
    @ViewBuilder
    private func asNeededBlock(_ medication: Medication, _ summary: PlannerSummary, now: Date) -> some View {
        let s = medication.settings
        let today = medication.planner.takenToday(now: now)
        Text(L("Hôm nay: \(today)/\(s.maxPerDay) lần", "Today: \(today) of \(s.maxPerDay)"))
            .font(.title2.weight(.black))
        if let last = summary.lastTaken?.takenAt {
            Text(L("Lần gần nhất: \(TodayText.relativeDay(last, from: now)) \(TimeFormatting.vn(last))", "Last: \(TodayText.relativeDay(last, from: now)) \(TimeFormatting.vn(last))"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.onFillSecondary)
        }
        if today >= s.maxPerDay {
            Callout(text: L("Đã đủ \(s.maxPerDay) lần hôm nay theo mức bạn đặt.", "That is the \(s.maxPerDay) you set for today."), icon: "exclamationmark.triangle.fill", fill: Palette.coral)
        } else if let allowed = medication.planner.nextAllowed(now: now), now < allowed {
            Callout(text: L("Chưa đủ \(TodayText.duration(s.minGap)) từ lần trước, còn \(TodayText.duration(allowed.timeIntervalSince(now))).",
                            "Less than \(TodayText.duration(s.minGap)) since the last one, \(TodayText.duration(allowed.timeIntervalSince(now))) to go."),
                    icon: "hourglass", fill: Palette.surfaceOnFill)
        }
        if let last = summary.lastTaken?.takenAt, now.timeIntervalSince(last) <= s.undoWindow {
            Button(L("Hoàn tác", "Undo")) { Task { await model.undo(medication.id) } }
                .buttonStyle(ChipButtonStyle(fill: Palette.surfaceOnFill))
        }
        takeButton(medication)
    }

    private func takeButton(_ medication: Medication) -> some View {
        Button(L("Đã uống", "Taken")) {
            tapped += 1
            Task { await model.markTaken([medication.id]) }
        }
        .buttonStyle(NeoButtonStyle(fill: Palette.surfaceOnFill))
        .accessibilityLabel(L("Đã uống \(medication.name)", "Taken \(medication.name)"))
    }

    private func skipButton(_ medication: Medication) -> some View {
        Button { confirmSkip = medication } label: {
            Label(L("Bỏ qua lần này", "Skip this dose"), systemImage: "forward.end")
        }
        .buttonStyle(ChipButtonStyle(fill: Palette.surfaceOnFill))
        // On the button: since iOS 26 the dialog is a popover from the view it is attached to, and from the screen it opened
        // off to the side. The card keeps its identity across the minute redraws, so the dialog stays up.
        .confirmationDialog(L("Bỏ qua lần uống này?", "Skip this dose?"),
                            isPresented: Binding(get: { confirmSkip?.id == medication.id }, set: { if !$0 { confirmSkip = nil } }),
                            titleVisibility: .visible) {
            Button(L("Bỏ qua lần này", "Skip this dose")) { model.skip(medication.id) }
        } message: {
            let next = medication.planner.skippingPreview(now: .now)
            Text(L("\(medication.name) thôi nhắc lần này, không tính là hụt và không trừ viên. Lần tới: \(TodayText.relativeDay(next, from: .now)) \(TimeFormatting.vn(next)). Có nên bỏ hay không: hỏi bác sĩ, dược sĩ.",
                   "No more reminders for this dose of \(medication.name). It does not count as missed and uses no pill. Next: \(TodayText.relativeDay(next, from: .now)) \(TimeFormatting.vn(next)). Whether to skip is a question for your doctor or pharmacist."))
        }
    }

    private func pillsRow(_ pills: PillCounter, refill: RefillReminder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("Còn \(pills.remaining)/\(pills.total) viên", "\(pills.remaining)/\(pills.total) pills left"), systemImage: "pills")
                    .font(.subheadline.weight(.heavy))
                Spacer()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceOnFill)
                    Capsule().fill(Palette.onFill)
                        .frame(width: proxy.size.width * CGFloat(pills.remaining) / CGFloat(max(1, pills.total)))
                }
                .overlay(Capsule().strokeBorder(Palette.onFill, lineWidth: 2))
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            if let line = pills.refillMessage(refill, language: AppLanguage.current) {
                Callout(text: line.prefix(1).uppercased() + line.dropFirst(), icon: "cart.fill", fill: Palette.surfaceOnFill)
            }
        }
    }

    /// Missed doses from the last 7 days that are not made up. The app gives no advice on making up, it only points to the leaflet.
    private func missedCard(_ items: [(medication: Medication, record: DoseRecord)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusPill(status: .missed)
            Text(items.count == 1 ? L("Có 1 lần hụt chưa uống bù", "1 missed dose not made up") : L("Có \(items.count) lần hụt chưa uống bù", "\(items.count) missed doses not made up"))
                .font(.headline.weight(.black))
                .foregroundStyle(Palette.text)
            // Two medications can miss at the same moment, so the id needs both.
            ForEach(items.map { (key: "\($0.medication.id)\($0.record.id)", medication: $0.medication, record: $0.record) }, id: \.key) { _, medication, record in
                rowLayout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(medication.name)
                            .font(.body.weight(.heavy))
                            .foregroundStyle(Palette.text)
                        Text("\(TodayText.dayTitle(record.scheduledAt)), \(TimeFormatting.vn(record.scheduledAt))")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Đã uống bù", "Mark made up")) { model.markMadeUp(medication.id, missedAt: record.scheduledAt) }
                        .buttonStyle(ChipButtonStyle(fill: Palette.sky))
                }
            }
            Text(L("Có nên uống bù hay không, uống thế nào: xem tờ hướng dẫn thuốc hoặc hỏi bác sĩ, dược sĩ. Bấm nhầm thì xoá trong Lịch sử.", "Whether and how to make up a missed dose: check the leaflet or ask a doctor or pharmacist. Tapped by mistake? Delete it in History."))
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
        }
        .card()
    }

    /// Shown when an early dose pulled the next reminder before its scheduled time.
    @ViewBuilder
    private func realignButton(_ medication: Medication, _ summary: PlannerSummary) -> some View {
        if summary.dose.dueAt < summary.dose.slotAt.addingTimeInterval(-60), let preview = summary.resetPreview {
            let main = TimeFormatting.clockTime(preview.dueAt, in: VietnamClock.timeZone)
            Button(L("Về lại \(main)", "Back to \(main)")) { model.realignQuestion = .init(medicationID: medication.id, preview: preview) }
                .buttonStyle(ChipButtonStyle(fill: Palette.surfaceOnFill))
        }
    }

    private func timeBlock(title: String, time: String, showsVN: Bool, local: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.onFillSecondary)
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                                          : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))) {
                Text(time)
                    .font(.system(size: 50, weight: .black))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if showsVN {
                    Text(L("giờ VN", "VN time"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Palette.onFillSecondary)
                }
            }
            if let local {
                Text(local)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.onFillSecondary)
            }
        }
    }

    private func weekCard(now: Date, summaries: [UUID: PlannerSummary]) -> some View {
        let calendar = VietnamClock.calendar
        let today = calendar.startOfDay(for: now)
        let statuses = model.derived("week", now: now) { mergedDayStatuses(model.medications.map { summaries[$0.id]!.dayStatuses() }) }
        // The only past day that can lack a record is a pending dose that is due or overdue (still in its late
        // window). Any other gap is before the user started, so it shows "no data", not late.
        var dueDays: [Date: DoseStatus] = [:]
        for medication in model.medications {
            let dose = summaries[medication.id]!.dose
            guard now >= dose.dueAt, medication.settings.pausedUntil(now: now) == nil else { continue }
            let day = calendar.startOfDay(for: dose.slotAt)
            if now >= dose.deadlineAt || dueDays[day] == nil { dueDays[day] = now >= dose.deadlineAt ? .late : .due }
        }
        let days: [(name: String, status: DoseStatus)] = (0..<7).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            let name = TodayText.shortWeekday(calendar.component(.weekday, from: day))
            if let status = statuses[day] { return (name, DoseStatus(status)) }
            if let status = dueDays[day] { return (name, status) }
            return (name, day < today ? .noData : .upcoming)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(L("7 ngày qua", "Last 7 days"))
                .font(.headline.weight(.black))
                .foregroundStyle(Palette.text)
            HStack(spacing: 6) {
                ForEach(days, id: \.name) { day, status in
                    VStack(spacing: 6) {
                        Image(systemName: status.icon)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Palette.onFill)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .neo(status.fill, radius: 10, shadow: 2)
                            .accessibilityLabel("\(day), \(status.label)")
                        Text(day)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            // Seven columns cannot grow forever; the rest of the screen still scales fully.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .card()
    }
}

extension Palette {
    /// A light fill for buttons and chips that sit on a pastel card, in both modes.
    static let surfaceOnFill = Color(hex: 0xFFFDF8)
    static let onFillSecondary = Color(hex: 0x161616).opacity(0.72)
}

extension Medication {
    /// "Mỗi ngày lúc 21:00" or "2 lần/ngày, 08:00 · 20:00".
    var scheduleSummary: String {
        let pills = settings.pillsPerDose > 1 ? L(" · \(settings.pillsPerDose) viên", " · \(settings.pillsPerDose) pills") : ""
        if settings.asNeeded {
            let gap = TodayText.duration(settings.minGap)
            return L("Khi cần, cách ít nhất \(gap)", "When needed, at least \(gap) apart") + pills
        }
        let times = doseTimes.joined(separator: " · ")
        let schedule = settings.dosesPerDay == 1 ? L("Mỗi ngày lúc \(times)", "Daily at \(times)") : L("\(settings.dosesPerDay) lần/ngày, \(times)", "\(settings.dosesPerDay)× a day, \(times)")
        let end = settings.endDay.map { L(" · tới \(TodayText.shortDate($0))", " · until \(TodayText.shortDate($0))") } ?? ""
        return schedule + pills + end
    }

    /// The clock times of the doses, Vietnam time, earliest in the day first.
    var doseTimes: [String] {
        let first = settings.mainHour * 60 + settings.mainMinute
        let step = 24 * 60 / settings.dosesPerDay
        return (0..<settings.dosesPerDay).map { (first + $0 * step) % (24 * 60) }.sorted()
            .map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    }
}

/// Display texts. Days and dose times always follow Vietnam time.
enum TodayText {
    private static let weekdaysVI = ["Chủ Nhật", "Thứ Hai", "Thứ Ba", "Thứ Tư", "Thứ Năm", "Thứ Sáu", "Thứ Bảy"]
    private static let weekdaysEN = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let monthsEN = ["January", "February", "March", "April", "May", "June", "July", "August",
                                   "September", "October", "November", "December"]
    static let shortWeekdaysVI = ["CN", "T2", "T3", "T4", "T5", "T6", "T7"]
    static let shortWeekdaysEN = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    /// Short weekday name for a Calendar `weekday` (1 is Sunday).
    static func shortWeekday(_ weekday: Int) -> String {
        (AppLanguage.current == .en ? shortWeekdaysEN : shortWeekdaysVI)[weekday - 1]
    }

    /// "Thứ Năm, 29 tháng 10" or "Thursday, 29 October", by the Vietnam date.
    static func dayTitle(_ date: Date) -> String {
        let parts = VietnamClock.calendar.dateComponents([.weekday, .day, .month], from: date)
        let weekday = (parts.weekday ?? 1) - 1, day = parts.day ?? 1, month = parts.month ?? 1
        return L("\(weekdaysVI[weekday]), \(day) tháng \(month)", "\(weekdaysEN[weekday]), \(day) \(monthsEN[month - 1])")
    }

    static func monthTitle(month: Int, year: Int) -> String {
        L("Tháng \(month), \(String(year))", "\(monthsEN[month - 1]) \(String(year))")
    }

    /// "7/11", by the Vietnam date.
    static func shortDate(_ date: Date) -> String {
        let parts = VietnamClock.calendar.dateComponents([.day, .month], from: date)
        return "\(parts.day ?? 1)/\(parts.month ?? 1)"
    }

    /// "today", "tomorrow" or a weekday, by the Vietnam date.
    static func relativeDay(_ date: Date, from now: Date) -> String {
        let calendar = VietnamClock.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case -1: return L("hôm qua", "yesterday")
        case 0: return L("hôm nay", "today")
        case 1: return L("mai", "tomorrow")
        default: return dayTitle(date)
        }
    }

    /// "2 giờ 10 phút" or "2 h 10 min". Rounds up so a countdown never shows "0 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return L("\(m) phút", "\(m) min") }
        return m == 0 ? L("\(h) giờ", "\(h) h") : L("\(h) giờ \(m) phút", "\(h) h \(m) min")
    }

    /// The local time where the phone is, hidden when the phone is on Vietnam time.
    static func localLine(_ date: Date) -> String? {
        let zone = TimeZone.autoupdatingCurrent
        guard zone.secondsFromGMT(for: date) != VietnamClock.timeZone.secondsFromGMT(for: date) else { return nil }
        let place = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
        let time = TimeFormatting.clockTime(date, in: zone)
        return L("tức \(time) tại \(place)", "that is \(time) in \(place)")
    }
}

#Preview { TodayView().environment(AppModel.shared) }
