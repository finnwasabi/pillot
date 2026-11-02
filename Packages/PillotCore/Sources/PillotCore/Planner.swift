import Foundation

/// A dose that is pending or upcoming.
public struct Dose: Equatable, Sendable {
    /// The main time (Vietnam time) this dose belongs to.
    public var slotAt: Date
    /// The main reminder time.
    public var dueAt: Date
    /// The deadline, where a ringing alarm fires.
    public var deadlineAt: Date
    /// Taken after the deadline but before this counts as late; after this it counts as missed.
    public var lateUntil: Date
    /// True when this dose was moved "back to the main time" and exceeds the maximum gap.
    public var exceedsMaxInterval: Bool
    /// The anchor for the deadline: the previous dose, or a virtual one after a miss or a pause.
    var anchor: Date
}

public enum ReminderKind: String, Codable, Sendable {
    case main, `repeat`, hourly, final, deadline
    /// After the deadline: keeps ringing until taken or until the late window ends.
    case overdue
}

public struct ReminderEvent: Equatable, Sendable {
    public var date: Date
    public var kind: ReminderKind
    /// A ringing alarm regardless of the phone's mode. True from the deadline on.
    public var requiresSound: Bool
    public var dueAt: Date
    public var deadlineAt: Date
}

/// Preview of "back to the main time".
public struct ResetPreview: Equatable, Sendable {
    public var dueAt: Date
    public var deadlineAt: Date
    /// True when that dose would be further than the maximum gap from the previous one; the app must warn.
    public var exceedsMaxInterval: Bool

    public init(dueAt: Date, deadlineAt: Date, exceedsMaxInterval: Bool) {
        self.dueAt = dueAt
        self.deadlineAt = deadlineAt
        self.exceedsMaxInterval = exceedsMaxInterval
    }
}

/// Everything the screens show for one medication at `now`, from one walk over the history. Each `Planner` query walks
/// the whole history on its own, and a redraw of Today asked about ten of them per medication.
public struct PlannerSummary: Sendable {
    public let now: Date
    /// Same as `Planner.currentDose`.
    public let dose: Dose
    public let lastTaken: DoseRecord?
    /// Same as `Planner.timeline`.
    public let timeline: [DoseRecord]
    public let missedCount: Int
    public let lateCount: Int
    public let skippedCount: Int
    public let madeUpCount: Int
    /// Same as `Planner.daysTaken`: since pills were last entered or added.
    public let daysTaken: Int
    public let undoableSkip: DoseRecord?
    public let resetPreview: ResetPreview?
    public let restingUntil: Date?
    public let cycleBreakUntil: Date?
    let planner: Planner

    /// Same as `Planner.outstandingMissed`.
    public func outstandingMissed(days: Int = 7) -> [DoseRecord] {
        let since = now.addingTimeInterval(-TimeInterval(days) * VietnamClock.day)
        return timeline.filter { $0.status == .missed && $0.scheduledAt >= since }.reversed()
    }

    /// Same as `Planner.dayStatuses`.
    public func dayStatuses() -> [Date: DoseStatus] { planner.dayStatuses(timeline: timeline, now: now) }

    /// Same as `Planner.events`, without walking the history again.
    public func events(horizonDays: Int = 14, cadence: TimeInterval? = nil) -> [ReminderEvent] {
        planner.events(from: dose, now: now, horizonDays: horizonDays, cadence: cadence)
    }
}

/// Computes the schedule from settings and history. Never reads the clock; `now` is always a parameter.
public struct Planner: Sendable {
    public var settings: ReminderSettings
    /// Dose history: taken doses (`.taken`) and make-ups (`.madeUp`).
    public var history: [DoseRecord]
    /// Timeline records before `settings.scheduleSince`, as they were under the schedule of the time (see `freezeHistory`).
    public var archive: [DoseRecord]

    public init(settings: ReminderSettings = ReminderSettings(), history: [DoseRecord] = [], archive: [DoseRecord] = []) {
        self.settings = settings
        self.history = history
        self.archive = archive
    }

    // MARK: Queries

    /// The dose pending at `now`.
    public func currentDose(now: Date) -> Dose { walk(now: now).dose }

    /// Every query below at once, from a single walk. Use this when drawing a screen.
    public func summary(now: Date) -> PlannerSummary {
        let events = resolutions(upTo: now)
        let state = walk(events, now: now)
        let resolved = resolved(state.records, now: now)
        let lastTake = events.last { $0.status == .taken }
        let since = settings.pills?.countingSince ?? .distantPast
        return PlannerSummary(
            now: now, dose: state.dose, lastTaken: lastTake, timeline: resolved.records,
            missedCount: state.missed, lateCount: state.late, skippedCount: state.skipped, madeUpCount: resolved.matched,
            daysTaken: events.count(where: { $0.status == .taken && $0.takenAt! >= since }),
            undoableSkip: undoableSkip(last: events.last, now: now),
            resetPreview: resetPreview(state, lastTake: lastTake),
            restingUntil: restingUntil(now: now), cycleBreakUntil: cycleBreakUntil(now: now),
            planner: self)
    }

    /// The next reminder time.
    public func nextReminder(now: Date) -> Date { currentDose(now: now).dueAt }

    public func missedCount(now: Date) -> Int { walk(now: now).missed }

    /// Doses taken after the deadline but within the late window.
    public func lateCount(now: Date) -> Int { walk(now: now).late }

    /// Doses taken since pills were last entered or added, or since the start when not counting. With one dose a day
    /// this is the number of days.
    public func daysTaken(now: Date) -> Int {
        let since = settings.pills?.countingSince ?? .distantPast
        return takes(upTo: now).filter { $0.takenAt! >= since }.count
    }

    public func lastTaken(now: Date) -> DoseRecord? { takes(upTo: now).last }

    /// Doses skipped on purpose.
    public func skippedCount(now: Date) -> Int { walk(now: now).skipped }

    /// The latest skip, while it can still be undone.
    public func undoableSkip(now: Date) -> DoseRecord? { undoableSkip(last: resolutions(upTo: now).last, now: now) }

    private func undoableSkip(last: DoseRecord?, now: Date) -> DoseRecord? {
        guard let last, last.status == .skipped, now.timeIntervalSince(last.takenAt!) <= settings.undoWindow else { return nil }
        return last
    }

    /// When the days off end, if `now` is on one.
    public func cycleBreakUntil(now: Date) -> Date? { settings.cycle?.breakEnd(after: now) }

    /// When reminders start again, if they are paused or `now` is on a day off.
    public func restingUntil(now: Date) -> Date? {
        if settings.courseEnded(now: now) { return .distantFuture }
        return [settings.pausedUntil(now: now), cycleBreakUntil(now: now)].compactMap { $0 }.max()
    }

    /// Takes on the Vietnam day of `now`, for a medication taken when needed.
    public func takenToday(now: Date) -> Int {
        let today = VietnamClock.startOfDay(now)
        return takes(upTo: now).count(where: { VietnamClock.startOfDay($0.takenAt!) == today })
    }

    /// For a medication taken when needed: before this, a dose comes sooner than the minimum gap.
    public func nextAllowed(now: Date) -> Date? {
        takes(upTo: now).last.map { $0.takenAt!.addingTimeInterval(settings.minGap) }
    }

    /// Freezes how every past dose turned out under the current schedule, with its day, before the schedule changes.
    /// Without it a new main time, number of doses, gap, cycle or end day re-reads the whole history under the new
    /// schedule: a month of daily doses turned into a month of misses after switching to twice a day.
    public mutating func freezeHistory(now: Date) {
        var records = walk(now: now).records
        for i in records.indices where records[i].day == nil { records[i].day = day(of: records[i]) }
        archive = records
        settings.scheduleSince = now
    }

    /// Full history for display: doses (on time or late), misses, make-ups and paused slots.
    public func timeline(now: Date) -> [DoseRecord] { resolved(walk(now: now).records, now: now).records }

    /// Misses that were made up. `missedCount` still includes them.
    public func madeUpCount(now: Date) -> Int { resolved(walk(now: now).records, now: now).matched }

    /// Misses not made up within the last `days` days, newest first.
    public func outstandingMissed(now: Date, days: Int = 7) -> [DoseRecord] {
        let since = now.addingTimeInterval(-TimeInterval(days) * VietnamClock.day)
        return timeline(now: now).filter { $0.status == .missed && $0.scheduledAt >= since }.reversed()
    }

    /// Matches each make-up to the miss it covers. A make-up that no longer matches a miss (for example after an edit
    /// removed the miss) stays in history so it can be deleted, but does not count as made up.
    private func resolved(_ walked: [DoseRecord], now: Date) -> (records: [DoseRecord], matched: Int) {
        var records = walked
        var unused = history.filter { $0.status == .madeUp && ($0.takenAt ?? .distantFuture) <= now }
        var matched = 0
        for i in records.indices where records[i].status == .missed {
            // The nearest make-up within half a period, not an exact match: changing the main time recomputes the
            // reminder time of past misses, and the make-up must stay linked to its miss.
            let missedAt = records[i].scheduledAt
            let distance = { (record: DoseRecord) in record.makesUpFor.map { abs($0.timeIntervalSince(missedAt)) } ?? .infinity }
            guard let k = unused.indices.min(by: { distance(unused[$0]) < distance(unused[$1]) }),
                  distance(unused[k]) < halfPeriod else { continue }
            records[i] = unused.remove(at: k)
            records[i].scheduledAt = missedAt
            matched += 1
        }
        records += unused
        records.sort { $0.scheduledAt < $1.scheduledAt }
        return (records, matched)
    }

    /// Status of each past Vietnam day (keyed by the start of the day), for the calendar and the week strip.
    /// A day with several records takes the worst status: missed, made up, late, taken, paused.
    public func dayStatuses(now: Date) -> [Date: DoseStatus] { dayStatuses(timeline: timeline(now: now), now: now) }

    /// The Vietnam day (its start) a timeline record belongs to, as the calendar shows it. Each record belongs to its
    /// nearest dose time, the same rule that picks the next dose after a take. A make-up belongs to the day of the miss it
    /// covers and a late dose to the day of the dose it was late for, not the day they were taken.
    public func day(of record: DoseRecord) -> Date {
        if let day = record.day { return day }
        let moment = [.madeUp, .late, .skipped].contains(record.status) ? record.scheduledAt : (record.takenAt ?? record.scheduledAt)
        return VietnamClock.startOfDay(firstSlot(after: moment.addingTimeInterval(-halfPeriod)))
    }

    func dayStatuses(timeline: [DoseRecord], now: Date) -> [Date: DoseStatus] {
        var result: [Date: DoseStatus] = [:]
        for record in timeline {
            let day = day(of: record)
            if let existing = result[day], existing.severity >= record.status.severity { continue }
            result[day] = record.status
        }
        // Days off since the first record show as paused.
        if let cycle = settings.cycle, let first = history.compactMap({ $0.takenAt }).min() {
            var day = VietnamClock.startOfDay(first)
            while day <= now {
                if result[day] == nil, cycle.isBreak(day) { result[day] = .paused }
                day = day.addingTimeInterval(VietnamClock.day)
            }
        }
        return result
    }

    /// Reminder events for the next `horizonDays` days, sorted and without duplicate times.
    /// The pending dose gets the whole chain (repeats, hourly, final, deadline, overdue). Doses after it are planned as if
    /// never confirmed, with only their main reminder and the ringing deadline: full chains for every future dose filled
    /// the 300-alarm budget in 57 hours with four medications. "Taken" or opening the app recomputes, and the next dose
    /// then becomes the pending one with its whole chain.
    /// `cadence`: the app's snooze length. The pending dose then rings again every `cadence` after the main time and
    /// after the deadline, until taken; `nil` keeps the spacing from the settings.
    public func events(now: Date, horizonDays: Int = 14, cadence: TimeInterval? = nil) -> [ReminderEvent] {
        events(from: currentDose(now: now), now: now, horizonDays: horizonDays, cadence: cadence)
    }

    func events(from pending: Dose, now: Date, horizonDays: Int, cadence: TimeInterval?) -> [ReminderEvent] {
        if settings.asNeeded { return [] }
        let end = now.addingTimeInterval(TimeInterval(horizonDays) * VietnamClock.day)
        var dose = pending
        var byDate: [Date: ReminderEvent] = [:]
        var isPending = true
        while dose.dueAt <= end {
            if let pause = overlappingPause(dose, startedBy: .distantFuture) {
                dose = doseAfterPause(pause.end)
                continue
            }
            let planned = isPending ? chain(for: dose, cadence: cadence) : mainAndDeadline(for: dose)
            isPending = false
            for event in planned where event.date > now && event.date <= end {
                if pauses.contains(where: { $0.contains(event.date) }) { continue }
                if let existing = byDate[event.date], priority(existing.kind) >= priority(event.kind) { continue }
                byDate[event.date] = event
            }
            dose = doseAfterMiss(dose)
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    /// Previews "back to the main time" for the next dose. `nil` when the pending dose does not follow directly from a take
    /// (after a miss or a pause the next dose already starts from the main time).
    public func resetPreview(now: Date) -> ResetPreview? { resetPreview(walk(now: now), lastTake: takes(upTo: now).last) }

    private func resetPreview(_ state: WalkState, lastTake: DoseRecord?) -> ResetPreview? {
        guard state.followsTake, var take = lastTake else { return nil }
        take.nextAtMainTime = true
        let dose = doseAfterTake(take)
        return ResetPreview(dueAt: dose.dueAt, deadlineAt: dose.deadlineAt, exceedsMaxInterval: dose.exceedsMaxInterval)
    }

    // MARK: Actions

    /// "Taken" at `now`. Subtracts a pill when counting.
    @discardableResult
    public mutating func markTaken(at now: Date) -> DoseRecord {
        let used = settings.pills?.consume(settings.pillsPerDose) ?? 0
        let scheduledAt = settings.asNeeded ? now : currentDose(now: now).dueAt
        var record = DoseRecord(scheduledAt: scheduledAt, takenAt: now, status: .taken, consumedPill: used > 0)
        if settings.pillsPerDose > 1 { record.pillsUsed = used }
        history.append(record)
        return record
    }

    /// "Skip this dose" for the dose pending at `now`. Not a miss, uses no pill; the next dose starts at the next dose
    /// time. Deleting the record (History, or undo on Today) brings the dose back.
    @discardableResult
    public mutating func skip(at now: Date) -> DoseRecord {
        let record = DoseRecord(scheduledAt: currentDose(now: now).dueAt, takenAt: now, status: .skipped)
        history.append(record)
        return record
    }

    /// When the next dose would be after skipping the one pending at `now`.
    public func skippingPreview(now: Date) -> Date {
        var copy = self
        copy.skip(at: now)
        return copy.currentDose(now: now).dueAt
    }

    /// Undoes the latest "Taken" if still within `undoWindow`.
    @discardableResult
    public mutating func undoLastTaken(now: Date) -> Bool {
        guard let last = takes(upTo: now).last, now.timeIntervalSince(last.takenAt!) <= settings.undoWindow,
              let index = history.firstIndex(where: { $0.id == last.id }) else { return false }
        history.remove(at: index)
        archive.removeAll { $0.id == last.id }
        settings.pills?.restore(last.pillsToRestore)
        return true
    }

    /// Edits a taken time in history.
    public mutating func editTakenTime(id: UUID, to date: Date) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].takenAt = date
        // A frozen copy keeps its status and day; only the time shown changes.
        if let frozen = archive.firstIndex(where: { $0.id == id }) { archive[frozen].takenAt = date }
    }

    /// Makes up the miss with this `scheduledAt`. Subtracts a pill when counting. Does not change the schedule.
    /// Returns `nil` when there is no such miss or it was already made up.
    @discardableResult
    public mutating func markMadeUp(missedAt scheduledAt: Date, at now: Date) -> DoseRecord? {
        guard timeline(now: now).contains(where: { $0.status == .missed && $0.scheduledAt == scheduledAt }) else { return nil }
        let used = settings.pills?.consume(settings.pillsPerDose) ?? 0
        var record = DoseRecord(scheduledAt: scheduledAt, takenAt: now, status: .madeUp, consumedPill: used > 0, makesUpFor: scheduledAt)
        if settings.pillsPerDose > 1 { record.pillsUsed = used }
        history.append(record)
        return record
    }

    /// Deletes a history record (a mistaken take, make-up or skip) and gives the pill back if one was taken. A deleted take
    /// brings its dose back: still pending if there is time, missed if not.
    public mutating func removeRecord(id: UUID) {
        // A frozen copy goes too; that day then shows no record rather than being re-read under the new schedule.
        archive.removeAll { $0.id == id }
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        // Removed first: inside `settings.pills?.restore(...)` the removal would be skipped when not counting pills.
        let removed = history.remove(at: index)
        settings.pills?.restore(removed.pillsToRestore)
    }

    /// "Back to the main time" for the next dose. Returns the preview so the app can warn about the maximum gap.
    @discardableResult
    public mutating func resetToMainTime(now: Date) -> ResetPreview? {
        guard let preview = resetPreview(now: now), let last = takes(upTo: now).last,
              let index = history.firstIndex(where: { $0.id == last.id }) else { return nil }
        history[index].nextAtMainTime = true
        return preview
    }

    /// Changes the main time and realigns the pending dose to it. Without this, the 24 h rule would keep reminding at
    /// the old time forever. Use `previewMainTimeChange` first to warn when the next dose would exceed the maximum gap.
    public mutating func changeMainTime(hour: Int, minute: Int, now: Date) {
        changeSchedule(hour: hour, minute: minute, dosesPerDay: settings.dosesPerDay, now: now)
    }

    /// Changes the main time and the doses per day, and realigns the pending dose. A new number of doses per day also
    /// moves the maximum gap into the new allowed range.
    public mutating func changeSchedule(hour: Int, minute: Int, dosesPerDay: Int, now: Date) {
        settings.mainHour = hour
        settings.mainMinute = minute
        if dosesPerDay != settings.dosesPerDay, ReminderSettings.allowedDosesPerDay.contains(dosesPerDay) {
            settings.dosesPerDay = dosesPerDay
            settings.maxInterval = settings.period
        }
        guard walk(now: now).followsTake, let last = takes(upTo: now).last,
              let index = history.firstIndex(where: { $0.id == last.id }) else { return }
        history[index].nextAtMainTime = true
    }

    /// What the pending dose would become after `changeMainTime`.
    public func previewMainTimeChange(hour: Int, minute: Int, now: Date) -> ResetPreview {
        previewScheduleChange(hour: hour, minute: minute, dosesPerDay: settings.dosesPerDay, now: now)
    }

    /// What the pending dose would become after `changeSchedule`.
    public func previewScheduleChange(hour: Int, minute: Int, dosesPerDay: Int, now: Date) -> ResetPreview {
        var copy = self
        copy.changeSchedule(hour: hour, minute: minute, dosesPerDay: dosesPerDay, now: now)
        let dose = copy.currentDose(now: now)
        return ResetPreview(dueAt: dose.dueAt, deadlineAt: dose.deadlineAt, exceedsMaxInterval: dose.exceedsMaxInterval)
    }

    /// "Pause reminders for N days" starting at `now`.
    public mutating func pause(days: Int, now: Date) {
        guard days > 0 else { return }
        settings.pauses.append(PausePeriod(start: now, end: now.addingTimeInterval(TimeInterval(days) * VietnamClock.day)))
    }

    /// Ends any pause at `now`.
    public mutating func resume(now: Date) {
        for i in settings.pauses.indices where settings.pauses[i].contains(now) {
            settings.pauses[i].end = now
        }
    }

    /// Adds pills, or starts counting if not counting yet.
    public mutating func addPills(_ count: Int, now: Date) {
        if settings.pills == nil {
            settings.pills = PillCounter(count: count, at: now)
        } else {
            settings.pills?.add(count, at: now)
        }
    }

    // MARK: Scheduling

    private struct WalkState {
        var dose: Dose
        var missed = 0
        var late = 0
        var skipped = 0
        var records: [DoseRecord] = []
        /// The pending dose follows directly from the last take, with no miss or pause in between.
        var followsTake = false
    }

    private func takes(upTo now: Date) -> [DoseRecord] {
        history
            .filter { $0.status == .taken && ($0.takenAt.map { $0 <= now } ?? false) }
            .sorted { $0.takenAt! < $1.takenAt! }
    }

    /// Takes and skips up to `now`, in time order: the events that resolve a dose.
    private func resolutions(upTo now: Date) -> [DoseRecord] {
        history
            .filter { ($0.status == .taken || $0.status == .skipped) && ($0.takenAt.map { $0 <= now } ?? false) }
            .sorted { $0.takenAt! < $1.takenAt! }
    }

    /// Walks the takes and skips up to `now`, counting misses, and returns the pending dose.
    private func walk(now: Date) -> WalkState { walk(resolutions(upTo: now), now: now) }

    /// `events` must be `resolutions(upTo: now)`.
    private func walk(_ events: [DoseRecord], now: Date) -> WalkState {
        if settings.asNeeded {
            // No schedule: every take is just a take, nothing is pending, nothing is missed.
            let far = Date.distantFuture
            return WalkState(dose: Dose(slotAt: far, dueAt: far, deadlineAt: far, lateUntil: far, exceedsMaxInterval: false, anchor: far),
                             records: events.filter { $0.status == .taken })
        }
        guard let since = settings.scheduleSince else { return walkLive(events, now: now) }
        // The live walk starts at the last take or skip before the change, so the next dose still follows from it.
        let start = events.last(where: { $0.takenAt! < since })?.takenAt ?? since
        var state = walkLive(events.filter { $0.takenAt! >= start }, now: now)
        let frozen = Set(archive.map(\.id))
        state.records = archive + state.records.filter { !frozen.contains($0.id) && ($0.takenAt ?? $0.scheduledAt) >= start }
        state.missed = state.records.count(where: { $0.status == .missed })
        state.late = state.records.count(where: { $0.status == .late })
        state.skipped = state.records.count(where: { $0.status == .skipped })
        return state
    }

    private func walkLive(_ events: [DoseRecord], now: Date) -> WalkState {
        var state: WalkState?
        for event in events {
            let t = event.takenAt!
            // `take()` moves the state out: `guard var current = state` left a second reference to `records`, so every
            // append copied the whole array and the walk was quadratic (7 ms for one year of a 6-a-day dose).
            guard var current = state.take() else {
                if event.status == .taken {
                    // The first take ever: nothing was pending before it.
                    state = WalkState(dose: doseAfterTake(event), records: [event], followsTake: true)
                    continue
                }
                // A skip before any take: the dose pending then was the next dose time.
                var fresh = WalkState(dose: doseFromMainTime(activeSlot(firstSlot(after: t))))
                apply(event, to: &fresh)
                state = fresh
                continue
            }
            advance(&current, before: t)
            apply(event, to: &current)
            state = current
        }
        guard var final = state.take() else {
            // No history yet: the first dose is the next dose time after `now`.
            var fresh = WalkState(dose: doseFromMainTime(activeSlot(firstSlot(after: now))))
            advance(&fresh, before: now)
            return fresh
        }
        advance(&final, before: now)
        return final
    }

    /// Resolves the pending dose with a take or a skip.
    private func apply(_ event: DoseRecord, to state: inout WalkState) {
        let t = event.takenAt!
        var record = event
        if event.status == .skipped {
            record.scheduledAt = state.dose.dueAt
            state.records.append(record)
            state.skipped += 1
            state.dose = doseAfterSkip(state.dose, at: t)
            state.followsTake = false
            return
        }
        if t > state.dose.deadlineAt.addingTimeInterval(max(0, settings.lateTolerance)) {
            record.status = .late
            record.scheduledAt = state.dose.dueAt
            state.late += 1
        }
        state.records.append(record)
        state.dose = doseAfterTake(event)
        state.followsTake = true
    }

    /// Skips doses inside pauses and counts doses whose late window ended before `t`.
    private func advance(_ state: inout WalkState, before t: Date) {
        while true {
            if let pause = overlappingPause(state.dose, startedBy: t) {
                // After the end of a course there is no dose at all, not a paused one, so the calendar stays blank.
                if pause.end != .distantFuture { state.records.append(DoseRecord(derived: state.dose.dueAt, status: .paused)) }
                state.dose = doseAfterPause(pause.end)
                state.followsTake = false
            } else if state.dose.lateUntil < t {
                state.missed += 1
                state.records.append(DoseRecord(derived: state.dose.dueAt, status: .missed))
                state.dose = doseAfterMiss(state.dose)
                state.followsTake = false
            } else {
                return
            }
        }
    }

    /// The pauses, plus everything after the end of a course.
    private var pauses: [PausePeriod] {
        guard let end = settings.courseEnd else { return settings.pauses }
        return settings.pauses + [PausePeriod(start: end, end: .distantFuture)]
    }

    private func overlappingPause(_ dose: Dose, startedBy t: Date) -> PausePeriod? {
        pauses.first { $0.start <= t && $0.start < $0.end && dose.dueAt < $0.end && dose.lateUntil >= $0.start }
    }

    private var maxInterval: TimeInterval { max(60, settings.maxInterval) }
    private var period: TimeInterval { settings.period }
    private var halfPeriod: TimeInterval { settings.period / 2 }
    /// Never longer than half a period, so with several doses a day a dose turns missed before the one after next is due.
    private var lateWindow: TimeInterval { min(max(0, settings.lateWindow), halfPeriod) }
    private var overdueBurst: TimeInterval { min(max(0, settings.overdueBurst), lateWindow) }

    /// The first scheduled dose time strictly after `date`. Doses repeat every `period` from the main time; 24 h is a
    /// multiple of the period and Vietnam has no daylight saving, so this is plain arithmetic.
    func firstSlot(after date: Date) -> Date {
        let base = VietnamClock.mainTime(onDayOf: date, hour: settings.mainHour, minute: settings.mainMinute)
        return base.addingTimeInterval((floor(date.timeIntervalSince(base) / period) + 1) * period)
    }

    /// The first scheduled dose time at or after `date`.
    func firstSlot(atOrAfter date: Date) -> Date {
        let base = VietnamClock.mainTime(onDayOf: date, hour: settings.mainHour, minute: settings.mainMinute)
        return base.addingTimeInterval(ceil(date.timeIntervalSince(base) / period) * period)
    }

    private func dose(slot: Date, anchor: Date) -> Dose {
        let deadline = anchor.addingTimeInterval(maxInterval)
        return Dose(slotAt: slot, dueAt: min(slot, deadline), deadlineAt: deadline, lateUntil: deadline.addingTimeInterval(lateWindow),
                    exceedsMaxInterval: false, anchor: anchor)
    }

    /// After a take at T: the next dose belongs to the first dose time after T + half a period, so the take at T
    /// counts for its nearest dose time. Reminder = min(that time, T + maximum gap).
    private func doseAfterTake(_ take: DoseRecord) -> Dose {
        let t = take.takenAt!
        let slot = firstSlot(after: t.addingTimeInterval(halfPeriod))
        // The next dose falls after days off: start fresh there, like after a pause.
        if activeSlot(slot) != slot { return doseFromMainTime(activeSlot(slot)) }
        guard take.nextAtMainTime else { return dose(slot: slot, anchor: t) }
        // Realigned (back to the main time, or the schedule changed): the next dose time at least a quarter period after
        // the take, so moving the time earlier takes effect on the next dose instead of being swallowed by the half rule.
        let aligned = firstSlot(after: t.addingTimeInterval(period / 4))
        if activeSlot(aligned) != aligned { return doseFromMainTime(activeSlot(aligned)) }
        let normalDeadline = t.addingTimeInterval(maxInterval)
        let deadline = max(aligned, normalDeadline)
        return Dose(slotAt: aligned, dueAt: aligned, deadlineAt: deadline, lateUntil: deadline.addingTimeInterval(lateWindow),
                    exceedsMaxInterval: aligned > normalDeadline, anchor: t)
    }

    /// After a miss: the virtual anchor is the deadline that passed (capped at dose time + half a period so it cannot
    /// drift), so two consecutive ringing alarms are never further apart than the maximum gap.
    private func doseAfterMiss(_ previous: Dose) -> Dose {
        let anchor = min(previous.deadlineAt, previous.slotAt.addingTimeInterval(halfPeriod))
        var slot = previous.slotAt.addingTimeInterval(period)
        while slot <= previous.deadlineAt { slot = slot.addingTimeInterval(period) }
        if activeSlot(slot) != slot { return doseFromMainTime(activeSlot(slot)) }
        return dose(slot: slot, anchor: anchor)
    }

    /// After "skip this dose" at `t`: the next dose starts fresh at the next dose time, as if the skipped one had been
    /// taken on time. Skipping is a choice, so it does not ring harder to catch up.
    private func doseAfterSkip(_ skipped: Dose, at t: Date) -> Dose {
        doseFromMainTime(activeSlot(firstSlot(after: max(skipped.slotAt, t))))
    }

    /// `slot`, or the first dose time after the days off it falls on.
    func activeSlot(_ slot: Date) -> Date {
        guard let cycle = settings.cycle else { return slot }
        var slot = slot
        // Bounded: at most every slot of one stretch of days off.
        for _ in 0...(cycle.breakDays * settings.dosesPerDay + 1) where cycle.isBreak(slot) {
            slot = slot.addingTimeInterval(period)
        }
        return slot
    }

    /// After a pause: the next dose starts from the first dose time at or after the pause ends.
    private func doseAfterPause(_ end: Date) -> Dose {
        doseFromMainTime(activeSlot(firstSlot(atOrAfter: end)))
    }

    /// A dose at its scheduled time, as if the previous one was taken on time one period before.
    private func doseFromMainTime(_ slot: Date) -> Dose {
        dose(slot: slot, anchor: slot.addingTimeInterval(-min(maxInterval, period)))
    }

    /// The light plan for a dose after the pending one.
    private func mainAndDeadline(for dose: Dose) -> [ReminderEvent] {
        [ReminderEvent(date: dose.dueAt, kind: .main, requiresSound: false, dueAt: dose.dueAt, deadlineAt: dose.deadlineAt),
         ReminderEvent(date: dose.deadlineAt, kind: .deadline, requiresSound: true, dueAt: dose.dueAt, deadlineAt: dose.deadlineAt)]
    }

    private func chain(for dose: Dose, cadence: TimeInterval?) -> [ReminderEvent] {
        func event(_ date: Date, _ kind: ReminderKind) -> ReminderEvent {
            ReminderEvent(date: date, kind: kind, requiresSound: kind == .deadline || kind == .overdue, dueAt: dose.dueAt, deadlineAt: dose.deadlineAt)
        }
        let due = dose.dueAt, deadline = dose.deadlineAt
        let hourly = max(60, settings.hourlyInterval)
        // With a cadence, the first stretch after the main time rings every `cadence` (like a snooze that nobody has to press),
        // as long as the stretch after the deadline. ponytail: the stretches are capped at `overdueBurst` and then go hourly,
        // because 9-minute rings for the whole 12-hour window would take 80 alarms per dose out of the 300.
        let repeatStep = cadence.map { max(60, $0) } ?? max(60, settings.repeatInterval)
        let repeatCount = cadence.map { Int(overdueBurst / max(60, $0)) } ?? max(0, settings.repeatCount)
        let finalStep = cadence.map { max(60, $0) } ?? max(60, settings.finalInterval)
        var list = [event(due, .main)]
        for i in stride(from: 1, through: repeatCount, by: 1) {
            list.append(event(due.addingTimeInterval(TimeInterval(i) * repeatStep), .repeat))
        }
        let lastRepeat = due.addingTimeInterval(TimeInterval(repeatCount) * repeatStep)
        let finalStart = deadline.addingTimeInterval(-max(0, settings.finalWindow))
        var next = lastRepeat.addingTimeInterval(hourly)
        while next < finalStart {
            list.append(event(next, .hourly))
            next = next.addingTimeInterval(hourly)
        }
        var final = finalStart
        while final < deadline {
            if final >= due { list.append(event(final, .final)) }
            final = final.addingTimeInterval(finalStep)
        }
        list.append(event(deadline, .deadline))
        // Past the deadline, all ringing: repeats like after the main time, then the final cadence until `overdueBurst`,
        // then hourly until the late window ends.
        let burstEnd = deadline.addingTimeInterval(overdueBurst)
        var overdue: [Date] = (0..<repeatCount).map { deadline.addingTimeInterval(TimeInterval($0 + 1) * repeatStep) }
        next = (overdue.last ?? deadline).addingTimeInterval(finalStep)
        while next <= burstEnd {
            overdue.append(next)
            next = next.addingTimeInterval(finalStep)
        }
        next = max(burstEnd, overdue.last ?? deadline).addingTimeInterval(hourly)
        while next <= dose.lateUntil {
            overdue.append(next)
            next = next.addingTimeInterval(hourly)
        }
        let before = list.filter { $0.date >= due && $0.date <= deadline }
        return before + overdue.filter { $0 <= dose.lateUntil }.map { event($0, .overdue) }
    }

    private func priority(_ kind: ReminderKind) -> Int {
        switch kind {
        case .deadline: 5
        case .overdue: 4
        case .main: 3
        case .repeat: 2
        case .final: 1
        case .hourly: 0
        }
    }
}
