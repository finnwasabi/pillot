import Foundation

/// Refill reminder settings. Field names match `refillReminder` in the snapshot.
public struct RefillReminder: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Remind when the remaining pills are at or below this.
    public var daysBefore: Int

    public init(enabled: Bool = true, daysBefore: Int = 7) {
        self.enabled = enabled
        self.daysBefore = daysBefore
    }
}

/// A pause in reminders, [start, end).
public struct PausePeriod: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// Days on and days off, like a 21 + 7 pack. No reminders and no misses on the days off.
public struct DoseCycle: Codable, Equatable, Sendable {
    public var activeDays: Int
    public var breakDays: Int
    /// The first day on of a cycle, as the start of that Vietnam day.
    public var startDay: Date

    public init(activeDays: Int = 21, breakDays: Int = 7, startDay: Date) {
        self.activeDays = max(1, activeDays)
        self.breakDays = max(1, breakDays)
        self.startDay = VietnamClock.calendar.startOfDay(for: startDay)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeDays = try c.decode(Int.self, forKey: .activeDays)
        breakDays = try c.decode(Int.self, forKey: .breakDays)
        startDay = try c.decode(Date.self, forKey: .startDay)
        guard activeDays > 0, breakDays > 0, !activeDays.addingReportingOverflow(breakDays).overflow else {
            throw DecodingError.dataCorruptedError(forKey: .breakDays, in: c, debugDescription: "Invalid cycle lengths")
        }
    }

    /// True on a day off. Days before `startDay` count as days on.
    public func isBreak(_ date: Date) -> Bool {
        breakDaysRemaining(after: date) != nil
    }

    /// Days since 1970 in Vietnam time. Plain arithmetic: Vietnam is UTC+7 with no daylight saving, and this runs for
    /// every planned reminder, where a Calendar call per date made planning twenty times slower.
    static func vietnamDay(_ date: Date) -> Double {
        ((date.timeIntervalSince1970 + VietnamClock.offset) / VietnamClock.day).rounded(.down)
    }

    /// The start of the next day on, if `date` is on a day off.
    public func breakEnd(after date: Date) -> Date? {
        breakDaysRemaining(after: date).map { VietnamClock.startOfDay(date).addingTimeInterval($0 * VietnamClock.day) }
    }

    private func breakDaysRemaining(after date: Date) -> Double? {
        let days = Self.vietnamDay(date) - Self.vietnamDay(startDay)
        let (length, overflow) = activeDays.addingReportingOverflow(breakDays)
        guard days >= 0, activeDays > 0, breakDays > 0, !overflow else { return nil }
        let dayInCycle = days.truncatingRemainder(dividingBy: Double(length))
        return dayInCycle >= Double(activeDays) ? Double(length) - dayInCycle : nil
    }
}

/// Reminder settings. All intervals are in seconds.
public struct ReminderSettings: Codable, Equatable, Sendable {
    /// Main time in Vietnam time. With several doses a day, the first one; the others follow every `period`.
    public var mainHour: Int
    public var mainMinute: Int
    /// Doses per day, evenly spaced. One of `allowedDosesPerDay`.
    public var dosesPerDay: Int
    /// Maximum gap between two consecutive doses.
    public var maxInterval: TimeInterval
    /// How many repeats follow the main reminder, and their spacing.
    public var repeatCount: Int
    public var repeatInterval: TimeInterval
    /// Cadence after the repeats.
    public var hourlyInterval: TimeInterval
    /// The final window before the deadline and its cadence.
    public var finalWindow: TimeInterval
    public var finalInterval: TimeInterval
    /// Snooze: ring again after this.
    public var snoozeInterval: TimeInterval
    /// How long "Taken" can be undone.
    public var undoWindow: TimeInterval
    /// How long after the deadline an untaken dose becomes missed. Taking it within this counts as late.
    public var lateWindow: TimeInterval
    /// A dose this soon after the deadline still counts as on time, so seconds or minutes do not make it late.
    /// Only affects counting; the alarm still rings at the deadline.
    public var lateTolerance: TimeInterval
    /// The first stretch after the deadline repeats at `finalInterval`, then at `hourlyInterval`.
    public var overdueBurst: TimeInterval
    /// Pill counter; `nil` means not counting.
    public var pills: PillCounter?
    public var refillReminder: RefillReminder
    /// Pauses, including past ones, so nothing inside them counts as missed.
    public var pauses: [PausePeriod]
    /// Days on and off; `nil` means every day.
    public var cycle: DoseCycle?
    /// Pills subtracted per dose (0.5.0).
    public var pillsPerDose: Int
    /// The last day of a course, the start of that Vietnam day; `nil` means no end. Nothing rings after it.
    public var endDay: Date?
    /// Taken only when needed: no schedule, no alarms and no misses. `minGap` and `maxPerDay` are what the app warns about.
    public var asNeeded: Bool
    public var minGap: TimeInterval
    public var maxPerDay: Int
    /// When the schedule last changed. History before it is frozen in `Planner.archive` (0.5.0).
    public var scheduleSince: Date?

    /// Pills per dose allowed in the editor.
    public static let pillsPerDoseRange = 1...10

    /// The moment a scheduled course is over: the end of `endDay`.
    public var courseEnd: Date? { asNeeded ? nil : endDay.map { VietnamClock.startOfDay($0).addingTimeInterval(VietnamClock.day) } }

    public func courseEnded(now: Date) -> Bool { courseEnd.map { now >= $0 } ?? false }

    public init(
        mainHour: Int = 21,
        mainMinute: Int = 0,
        dosesPerDay: Int = 1,
        maxInterval: TimeInterval = 24 * 3600,
        repeatCount: Int = 3,
        repeatInterval: TimeInterval = 5 * 60,
        hourlyInterval: TimeInterval = 3600,
        finalWindow: TimeInterval = 2 * 3600,
        finalInterval: TimeInterval = 15 * 60,
        snoozeInterval: TimeInterval = 9 * 60,
        undoWindow: TimeInterval = 10 * 60,
        lateWindow: TimeInterval = 12 * 3600,
        lateTolerance: TimeInterval = 15 * 60,
        overdueBurst: TimeInterval = 3 * 3600,
        pills: PillCounter? = nil,
        refillReminder: RefillReminder = RefillReminder(),
        pauses: [PausePeriod] = [],
        cycle: DoseCycle? = nil,
        pillsPerDose: Int = 1,
        endDay: Date? = nil,
        asNeeded: Bool = false,
        minGap: TimeInterval = 4 * 3600,
        maxPerDay: Int = 4,
        scheduleSince: Date? = nil
    ) {
        self.mainHour = mainHour
        self.mainMinute = mainMinute
        self.dosesPerDay = Self.allowedDosesPerDay.contains(dosesPerDay) ? dosesPerDay : 1
        self.maxInterval = maxInterval
        self.repeatCount = repeatCount
        self.repeatInterval = repeatInterval
        self.hourlyInterval = hourlyInterval
        self.finalWindow = finalWindow
        self.finalInterval = finalInterval
        self.snoozeInterval = snoozeInterval
        self.undoWindow = undoWindow
        self.lateWindow = lateWindow
        self.lateTolerance = lateTolerance
        self.overdueBurst = overdueBurst
        self.pills = pills
        self.refillReminder = refillReminder
        self.pauses = pauses
        self.cycle = cycle
        self.pillsPerDose = min(max(pillsPerDose, Self.pillsPerDoseRange.lowerBound), Self.pillsPerDoseRange.upperBound)
        self.endDay = endDay.map(VietnamClock.startOfDay)
        self.asNeeded = asNeeded
        self.minGap = minGap
        self.maxPerDay = maxPerDay
        self.scheduleSince = scheduleSince
    }

    /// Divisors of 24, so the doses fall on the same clock times every day.
    public static let allowedDosesPerDay = [1, 2, 3, 4, 6]

    /// Time between two scheduled doses: 24 h divided by `dosesPerDay`.
    public var period: TimeInterval { 24 * 3600 / TimeInterval(dosesPerDay) }

    /// The range the maximum gap may be set to: from one period up to two (48 h for a daily dose, 0.4.2; 1.5 before).
    /// Never shorter than a period: every dose would pull the next one earlier, so a 12 h gap on a daily dose would
    /// really be two doses a day. The app says to pick more doses a day instead.
    public var maxIntervalRange: ClosedRange<TimeInterval> { period...(period * 2) }

    /// Whether a dose taken at `takenAt` still shows as "Taken" at `now`, on Today and in the widget: for half the time
    /// to the next dose or while it can be undone. A daily dose also stays "Taken" for the rest of its Vietnam day, so a
    /// morning dose is not offered again in the evening.
    public func showsAsTaken(_ takenAt: Date, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(takenAt)
        if elapsed < period / 2 || elapsed <= undoWindow { return true }
        return dosesPerDay == 1 && DoseCycle.vietnamDay(takenAt) == DoseCycle.vietnamDay(now)
    }

    /// When the pause ends, if `now` is inside one.
    public func pausedUntil(now: Date) -> Date? {
        guard !asNeeded else { return nil }
        return pauses.filter { $0.contains(now) }.map(\.end).max()
    }

    // Tolerant decoding: missing fields fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReminderSettings()
        mainHour = try c.decodeIfPresent(Int.self, forKey: .mainHour) ?? d.mainHour
        mainMinute = try c.decodeIfPresent(Int.self, forKey: .mainMinute) ?? d.mainMinute
        let doses = try c.decodeIfPresent(Int.self, forKey: .dosesPerDay) ?? d.dosesPerDay
        dosesPerDay = Self.allowedDosesPerDay.contains(doses) ? doses : d.dosesPerDay
        maxInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .maxInterval) ?? d.maxInterval
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? d.repeatCount
        repeatInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .repeatInterval) ?? d.repeatInterval
        hourlyInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .hourlyInterval) ?? d.hourlyInterval
        finalWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .finalWindow) ?? d.finalWindow
        finalInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .finalInterval) ?? d.finalInterval
        snoozeInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .snoozeInterval) ?? d.snoozeInterval
        undoWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .undoWindow) ?? d.undoWindow
        lateWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .lateWindow) ?? d.lateWindow
        lateTolerance = try c.decodeIfPresent(TimeInterval.self, forKey: .lateTolerance) ?? d.lateTolerance
        overdueBurst = try c.decodeIfPresent(TimeInterval.self, forKey: .overdueBurst) ?? d.overdueBurst
        pills = try c.decodeIfPresent(PillCounter.self, forKey: .pills)
        refillReminder = try c.decodeIfPresent(RefillReminder.self, forKey: .refillReminder) ?? d.refillReminder
        pauses = try c.decodeIfPresent([PausePeriod].self, forKey: .pauses) ?? d.pauses
        cycle = try c.decodeIfPresent(DoseCycle.self, forKey: .cycle)
        pillsPerDose = try c.decodeIfPresent(Int.self, forKey: .pillsPerDose) ?? d.pillsPerDose
        endDay = try c.decodeIfPresent(Date.self, forKey: .endDay)
        asNeeded = try c.decodeIfPresent(Bool.self, forKey: .asNeeded) ?? d.asNeeded
        minGap = try c.decodeIfPresent(TimeInterval.self, forKey: .minGap) ?? d.minGap
        maxPerDay = try c.decodeIfPresent(Int.self, forKey: .maxPerDay) ?? d.maxPerDay
        scheduleSince = try c.decodeIfPresent(Date.self, forKey: .scheduleSince)
    }
}
