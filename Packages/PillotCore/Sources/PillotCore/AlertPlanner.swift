import Foundation

/// A decided alert: an AlarmKit alarm or a plain notification, with its texts.
public struct PlannedAlert: Equatable, Sendable {
    public var date: Date
    /// True: an AlarmKit alarm that rings on silent and in Focus. False: a plain notification that follows the phone's mode.
    public var usesAlarm: Bool
    public var title: String
    /// Secondary line, only plain notifications can show it.
    public var body: String
    /// The medications this alert is for. "Taken" on the alert marks all of them.
    public var medicationIDs: [UUID]
    /// Their names, for the lock screen countdown.
    public var names: String
    /// A notification without sound: the heads-up before the dose time.
    public var quiet = false
}

/// One medication's reminders, the input for `AlertPlanner`.
public struct MedicationReminders: Sendable {
    public var id: UUID
    /// Empty means a generic "your pill" in the texts.
    public var name: String
    public var events: [ReminderEvent]
    /// The refill line for this medication, or `nil`.
    public var refillMessage: String?
    /// Missed doses of this medication not made up yet.
    public var missedCount: Int

    public init(id: UUID, name: String, events: [ReminderEvent], refillMessage: String?, missedCount: Int) {
        self.id = id
        self.name = name
        self.events = events
        self.refillMessage = refillMessage
        self.missedCount = missedCount
    }

    /// `cadence`: how often the pending dose rings again, the snooze length (see `Planner.events`).
    public init(_ medication: Medication, now: Date, language: Language, cadence: TimeInterval? = nil) {
        let summary = medication.planner.summary(now: now)
        self.init(
            id: medication.id, name: medication.name, events: summary.events(cadence: cadence),
            refillMessage: medication.settings.pills?.refillMessage(medication.settings.refillReminder, language: language),
            missedCount: summary.outstandingMissed().count)
    }
}

public enum AlertPlanner {
    /// iOS keeps only 64 pending notifications per app.
    public static let notificationLimit = 64
    // ponytail: AlarmKit documents no limit; 300 covers several days for a few medications. Raise after measuring on a device.
    public static let alarmLimit = 300

    /// Turns reminder events into alerts. Medications reminded at the same moment share one alert, so two medications
    /// at 21:00 ring once and one "Taken" marks both.
    /// `vibrateOnly`: reminders are plain notifications, but from the deadline on they are always ringing alarms.
    /// `alarmsAvailable` false (no AlarmKit permission): everything becomes a notification so reminders still happen.
    /// `headsUp`: a quiet notification this long before each dose time, for someone holding the phone; 0 means none.
    /// Only the earliest alerts within the limits are kept; the app refills on every launch and every "Taken".
    public static func alerts(
        for medications: [MedicationReminders], vibrateOnly: Bool, alarmsAvailable: Bool = true, language: Language = .vi,
        headsUp: TimeInterval = 0
    ) -> [PlannedAlert] {
        var byDate: [Date: [(medication: MedicationReminders, event: ReminderEvent)]] = [:]
        var headsUpByDate: [Date: [MedicationReminders]] = [:]
        for medication in medications {
            for event in medication.events {
                byDate[event.date, default: []].append((medication, event))
                // The first ring of a dose. Its kind is not enough: with the default gap the dose time is also the deadline.
                if headsUp > 0, event.date == event.dueAt {
                    headsUpByDate[event.date.addingTimeInterval(-headsUp), default: []].append(medication)
                }
            }
        }
        var notifications = 0, alarms = 0
        var result: [PlannedAlert] = []
        for date in Set(byDate.keys).union(headsUpByDate.keys).sorted() {
            if let soon = headsUpByDate[date], notifications < notificationLimit {
                notifications += 1
                let names = names(soon.map(\.name), language: language)
                let minutes = Int(headsUp / 60)
                result.append(PlannedAlert(
                    date: date, usesAlarm: false,
                    title: language == .en ? "\(names) in \(minutes) min" : "Còn \(minutes) phút nữa tới giờ uống \(names)",
                    body: language == .en ? "Taking it a little early is fine." : "Uống sớm một chút cũng được.",
                    medicationIDs: soon.map(\.id), names: names, quiet: true))
            }
            guard let group = byDate[date] else { continue }
            let event = group.map(\.event).max { priority($0.kind) < priority($1.kind) }!
            let usesAlarm = alarmsAvailable && (!vibrateOnly || group.contains { $0.event.requiresSound })
            if usesAlarm {
                guard alarms < alarmLimit else { continue }
                alarms += 1
            } else {
                guard notifications < notificationLimit else { continue }
                notifications += 1
            }
            let names = names(group.map(\.medication.name), language: language)
            var title = title(for: event.kind, names: names, language: language)
            let refills = group.compactMap { item in
                item.medication.refillMessage.map { group.count > 1 && !item.medication.name.isEmpty ? "\(item.medication.name): \($0)" : $0 }
            }
            for line in [missedMessage(count: group.map(\.medication.missedCount).reduce(0, +), language: language)].compactMap({ $0 }) + refills {
                title += ". " + line.prefix(1).uppercased() + line.dropFirst()
            }
            let deadline = TimeFormatting.vietnamTime(group.map(\.event.deadlineAt).min()!, language: language)
            let body = language == .en ? "Deadline \(deadline)." : "Hạn chót \(deadline)."
            result.append(PlannedAlert(date: date, usesAlarm: usesAlarm, title: title, body: body,
                                       medicationIDs: group.map(\.medication.id), names: names))
        }
        return result
    }

    /// A single schedule without a name, as before medications had names.
    public static func alerts(
        for events: [ReminderEvent], vibrateOnly: Bool, alarmsAvailable: Bool = true, refillMessage: String?,
        missedMessage: String? = nil, language: Language = .vi
    ) -> [PlannedAlert] {
        var alerts = alerts(for: [MedicationReminders(id: UUID(), name: "", events: events, refillMessage: nil, missedCount: 0)],
                            vibrateOnly: vibrateOnly, alarmsAvailable: alarmsAvailable, language: language)
        for i in alerts.indices {
            for line in [missedMessage, refillMessage].compactMap({ $0 }) {
                alerts[i].title += ". " + line.prefix(1).uppercased() + line.dropFirst()
            }
        }
        return alerts
    }

    /// Line added to every alert while missed doses are not made up. Short because alarm titles get truncated; it gives no advice,
    /// the pointer to the leaflet lives on the missed card in the app.
    public static func missedMessage(count: Int, language: Language = .vi) -> String? {
        guard count > 0 else { return nil }
        return language == .en ? "\(count) missed \(count == 1 ? "dose" : "doses") not made up" : "còn \(count) lần hụt chưa uống bù"
    }

    /// "Vitamin D", "Vitamin D, Iron" or "Vitamin D, Iron +2". Empty names fall back to a generic word.
    public static func names(_ names: [String], language: Language) -> String {
        let named = names.filter { !$0.isEmpty }
        guard !named.isEmpty else { return language == .en ? "your pill" : "thuốc" }
        let shown = named.prefix(2).joined(separator: ", ")
        return named.count > 2 ? "\(shown) +\(named.count - 2)" : shown
    }

    static func title(for kind: ReminderKind, names: String? = nil, language: Language = .vi) -> String {
        if language == .en {
            let n = names ?? "your pill"
            switch kind {
            case .main: return "Time to take \(n)"
            case .repeat: return "Reminder: \(n) not taken yet"
            case .hourly: return "Still haven't taken \(n)"
            case .final: return "Deadline soon, take \(n) now"
            case .deadline: return "Deadline reached: take \(n)"
            case .overdue: return "Past the deadline, take \(n) now"
            }
        }
        let n = names ?? "thuốc"
        return switch kind {
        case .main: "Tới giờ uống \(n)"
        case .repeat: "Nhắc lại: chưa uống \(n)"
        case .hourly: "Vẫn chưa uống \(n)"
        case .final: "Sắp tới hạn chót, uống \(n) ngay nhé"
        case .deadline: "Tới hạn chót: uống \(n)"
        case .overdue: "Đã quá hạn chót, uống \(n) ngay"
        }
    }

    static func priority(_ kind: ReminderKind) -> Int {
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

extension PlannedAlert {
    /// Everything the phone shows or does with this alert. An alarm or notification already scheduled under the same key
    /// is left alone, so a change to one medication no longer cancels and reschedules every alert (0.3.5 redid up to 300
    /// alarms, about 2 seconds, after each change).
    public func key(snoozeMinutes: Int, language: Language) -> String {
        let ids = medicationIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "\(Int(date.timeIntervalSince1970.rounded()))|\(usesAlarm ? "alarm" : "note")|\(ids)|\(snoozeMinutes)|\(language.rawValue)|\(title)|\(body)"
    }
}

public enum AlertDiff {
    /// Matches what is scheduled (id to key) against the planned keys. Returns the ids to cancel and the positions in
    /// `planned` that still need scheduling. A key scheduled twice keeps one copy.
    public static func diff(scheduled: [String: String], planned: [String]) -> (cancel: [String], add: [Int]) {
        var free = Dictionary(grouping: scheduled.keys.sorted(), by: { scheduled[$0]! })
        var add: [Int] = []
        for (index, key) in planned.enumerated() {
            if free[key]?.isEmpty == false {
                free[key]!.removeFirst()
            } else {
                add.append(index)
            }
        }
        return (free.values.flatMap { $0 }.sorted(), add)
    }
}
