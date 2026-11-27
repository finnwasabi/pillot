import AlarmKit
import AppIntents
import PillotCore
import SwiftUI
import UserNotifications

/// Feeds planned alerts into AlarmKit (ringing alarms) and UserNotifications (plain notifications).
/// Times are always absolute: `.fixed` for alarms and seconds from now for notifications,
/// so changing the phone's time zone never shifts them.
nonisolated struct ReminderScheduler: Sendable {
    static let doseCategory = "dose"
    static let takenAction = "taken"
    static let medicationsKey = "medications"
    static let dosesDueAtKey = "dosesDueAt"
    /// Which medications each scheduled alarm is for. AlarmKit does not hand the metadata back, so it lives here.
    private static let alarmMedicationsKey = "alarmMedications"

    /// The key each scheduled alarm was made from (`PlannedAlert.key`), so the next pass can leave it alone.
    private static let alarmKeysKey = "alarmKeys"
    /// Bumped when the alarm's buttons or intents change, so alarms set by an older version are all replaced once.
    /// 2: Stop snoozes and Taken is the secondary button (0.4.2).
    /// 3: Slide to stop (and the side button) is Taken, the button is Snooze (0.5.1).
    /// 4: Slide to stop and the side button only silence this ring, the button is Taken (0.5.3).
    /// 5: Taken opens the app and asks first (0.5.4).
    /// 6: Stop targets its own alarm, and Taken asks about the doses in that alarm.
    private static let buttonsVersion = 6
    /// The alarm made by "Test alarm" in Settings; reschedules leave it alone.
    private static let testAlarmKey = "testAlarmID"

    /// What one pass did, for the Diagnostics section in Settings.
    struct Report: Sendable {
        /// Alarms the app holds after the pass, ringing or snoozed ones included.
        var alarms = 0
        var notifications = 0
        /// Alarms and notifications cancelled or added by this pass; the rest stayed as they were.
        var changed = 0
        var failures = 0
        /// What AlarmKit or the notification center said the first time something could not be scheduled.
        var firstError: String?
        /// The latest alert that is scheduled: reminders stop after this unless the app runs again.
        var lastAlert: Date?

        mutating func recordFailure(_ error: Error) {
            failures += 1
            firstError = firstError ?? String(describing: error)
        }
    }

    /// Brings the scheduled alarms and notifications in line with `alerts`, touching only what differs.
    /// `cancelActiveFor`: also stops ringing or snoozed alarms that include any of these medications.
    func apply(_ alerts: [PlannedAlert], cancelActiveFor taken: Set<UUID>, snooze: TimeInterval, language: Language) async -> Report {
        // Notification button titles follow the selected language.
        Self.registerCategory()
        let takenIDs = Set(taken.map(\.uuidString))
        let alarms = alerts.filter(\.usesAlarm)
        let (alarmReport, failedAlarms) = await applyAlarms(alarms, cancelActiveFor: takenIDs, snooze: snooze, language: language)
        var report = alarmReport

        // Notifications use the key as their identifier, so the pending list itself says what is already scheduled.
        let center = UNUserNotificationCenter.current()
        if !takenIDs.isEmpty {
            let delivered = await center.deliveredNotifications().filter { note in
                let meds = note.request.content.userInfo[Self.medicationsKey] as? [String] ?? []
                return meds.isEmpty || !takenIDs.isDisjoint(with: meds)
            }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier))
        }
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        func noteKey(_ alert: PlannedAlert) -> String {
            alert.key(snoozeMinutes: Int(snooze / 60), language: language)
        }
        var notes = alerts.filter { !$0.usesAlarm }
        let fallbackCandidates = failedAlarms ?? alarms
        if !fallbackCandidates.isEmpty {
            let pendingKeys = Set(pending)
            let now = Date.now
            let fallbacks = fallbackCandidates.compactMap { alarm -> PlannedAlert? in
                guard alarm.date > now else { return nil }
                var note = alarm
                note.usesAlarm = false
                // If AlarmKit's state is unknown, keep existing fallbacks but never add duplicates.
                if failedAlarms == nil, !pendingKeys.contains(noteKey(note)) { return nil }
                return note
            }
            if !fallbacks.isEmpty {
                let limit = AlertPlanner.notificationLimit
                let primary = (notes.filter { !$0.quiet } + fallbacks).sorted { $0.date < $1.date }.prefix(limit)
                let quiet = notes.filter(\.quiet).prefix(limit - primary.count)
                notes = (primary + quiet).sorted { $0.date < $1.date }
            }
        }
        let noteKeys = notes.map(noteKey)
        let noteDiff = AlertDiff.diff(scheduled: Dictionary(uniqueKeysWithValues: pending.map { ($0, $0) }), planned: noteKeys)
        center.removePendingNotificationRequests(withIdentifiers: noteDiff.cancel)
        report.notifications = pending.count - noteDiff.cancel.count
        let additions = Set(noteDiff.add)
        for index in notes.indices {
            let alert = notes[index]
            if additions.contains(index) {
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                content.sound = alert.quiet ? nil : .default
                content.categoryIdentifier = Self.doseCategory
                content.userInfo = [
                    Self.medicationsKey: alert.medicationIDs.map(\.uuidString),
                    Self.dosesDueAtKey: Dictionary(uniqueKeysWithValues: alert.dosesDueAt.map { ($0.key.uuidString, $0.value) }),
                ]
                // Seconds from now: the absolute time is in the key, so a kept request still fires when planned.
                let interval = alert.date.timeIntervalSinceNow
                guard interval > 0 else { continue }
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                do {
                    try await center.add(UNNotificationRequest(identifier: noteKeys[index], content: content, trigger: trigger))
                    report.notifications += 1
                    report.changed += 1
                } catch {
                    report.recordFailure(error)
                    continue
                }
            }
            report.lastAlert = max(report.lastAlert ?? alert.date, alert.date)
        }
        report.changed += noteDiff.cancel.count
        return report
    }

    /// A nil list of failed alarms means the daemon's scheduled state could not be read.
    private func applyAlarms(_ plannedAlarms: [PlannedAlert], cancelActiveFor takenIDs: Set<String>, snooze: TimeInterval, language: Language) async -> (Report, [PlannedAlert]?) {
        var report = Report()
        let manager = AlarmManager.shared
        let defaults = UserDefaults.standard
        let known = defaults.dictionary(forKey: Self.alarmMedicationsKey) as? [String: [String]] ?? [:]
        let knownKeys = defaults.dictionary(forKey: Self.alarmKeysKey) as? [String: String] ?? [:]
        var kept: [String: [String]] = [:]
        var keptKeys: [String: String] = [:]
        var scheduled: [String: String] = [:]
        // Without the list every planned alarm would look new. Notifications can still be reconciled independently.
        let current: [Alarm]
        do {
            current = try manager.alarms
        } catch {
            report.recordFailure(error)
            return (report, nil)
        }
        func cancel(_ id: UUID) -> Bool {
            do {
                try manager.cancel(id: id)
                report.changed += 1
                return true
            } catch {
                report.recordFailure(error)
                return false
            }
        }
        let testID = defaults.string(forKey: Self.testAlarmKey)
        for alarm in current {
            let id = alarm.id.uuidString
            let meds = known[id]
            if id == testID {
                kept[id] = meds ?? []
                keptKeys[id] = knownKeys[id] ?? "test"
                continue
            }
            if alarm.state == .scheduled {
                // Alarms from before 0.3.6 have no key: they are replaced once.
                if let key = knownKeys[id] { scheduled[id] = key } else { _ = cancel(alarm.id) }
                continue
            }
            // Ringing or snoozed. One without a record comes from a version before medications; any "Taken" stops it.
            let belongsToTaken = meds.map { !takenIDs.isDisjoint(with: $0) } ?? !takenIDs.isEmpty
            if belongsToTaken, cancel(alarm.id) { continue }
            kept[id] = meds
            keptKeys[id] = knownKeys[id]
        }
        let alarmKeys = plannedAlarms.map { "b\(Self.buttonsVersion)|" + $0.key(snoozeMinutes: Int(snooze / 60), language: language) }
        let alarmDiff = AlertDiff.diff(scheduled: scheduled, planned: alarmKeys)
        let cancelled = Set(alarmDiff.cancel.filter { id in
            UUID(uuidString: id).map(cancel) ?? false
        })
        for (id, key) in scheduled where !cancelled.contains(id) {
            kept[id] = known[id]
            keptKeys[id] = key
        }
        var failed: Set<Int> = []
        for index in alarmDiff.add {
            let alert = plannedAlarms[index], id = UUID()
            do {
                _ = try await manager.schedule(id: id, configuration: Self.configuration(
                    date: alert.date, title: alert.title, names: alert.names, id: id, dosesDueAt: alert.dosesDueAt, snooze: snooze))
                kept[id.uuidString] = alert.medicationIDs.map(\.uuidString)
                keptKeys[id.uuidString] = alarmKeys[index]
                report.changed += 1
            } catch {
                failed.insert(index)
                report.recordFailure(error)
            }
        }
        defaults.set(kept, forKey: Self.alarmMedicationsKey)
        defaults.set(keptKeys, forKey: Self.alarmKeysKey)
        report.alarms = kept.count
        report.lastAlert = plannedAlarms.indices.filter { !failed.contains($0) }.map { plannedAlarms[$0].date }.max()
        return (report, failed.sorted().map { plannedAlarms[$0] })
    }

    private static func configuration(date: Date, title: String, names: String, id: UUID, dosesDueAt: [UUID: Date], snooze: TimeInterval) -> AlarmManager.AlarmConfiguration<DoseAlarmMetadata> {
        AlarmManager.AlarmConfiguration(
            // Keep a countdown duration: with nil, AlarmKit refused every alarm (error code 0) in 0.5.1. No button starts it.
            countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snooze),
            schedule: .fixed(date),
            attributes: attributes(title: title, names: names, snooze: snooze),
            stopIntent: StopIntent(alarmID: id),
            secondaryIntent: ConfirmTakenIntent(alarmID: id, dosesDueAt: dosesDueAt)
        )
    }

    /// Slide to stop and the side button only silence this ring, and the next reminder follows within the snooze length.
    /// Taken opens the app, which asks before logging: on a locked phone a hardware button press ran Stop once and the
    /// Taken button another time (0.5.2 and 0.5.3 on a phone, 02/11/2026), so no button on the alarm may log a dose by
    /// itself. The Simulator shows the alarm only as a banner on an unlocked screen, so this cannot be tried there.
    private static func attributes(title: String, names: String, snooze: TimeInterval) -> AlarmAttributes<DoseAlarmMetadata> {
        let taken = AlarmButton(text: LocalizedStringResource(stringLiteral: L("Đã uống", "Taken")), textColor: .black, systemImageName: "checkmark")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), secondaryButton: taken, secondaryButtonBehavior: .custom)
        } else {
            let stop = AlarmButton(text: LocalizedStringResource(stringLiteral: L("Hoãn \(Int(snooze / 60)) phút", "Snooze \(Int(snooze / 60)) min")), textColor: .white, systemImageName: "zzz")
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop, secondaryButton: taken, secondaryButtonBehavior: .custom)
        }
        let presentation = AlarmPresentation(
            alert: alert,
            countdown: AlarmPresentation.Countdown(title: LocalizedStringResource(stringLiteral: L("Đang hoãn: \(names)", "Snoozed: \(names)")))
        )
        return AlarmAttributes<DoseAlarmMetadata>(
            presentation: presentation,
            metadata: DoseAlarmMetadata(language: AppLanguage.current.rawValue, names: names),
            tintColor: Palette.primary)
    }

    /// Slide to stop or the side button: silences the ringing alarm of these medications. The next reminder is already scheduled.
    func silence(_ ids: [UUID]) {
        let manager = AlarmManager.shared
        let known = UserDefaults.standard.dictionary(forKey: Self.alarmMedicationsKey) as? [String: [String]] ?? [:]
        let wanted = Set(ids.map(\.uuidString))
        for alarm in (try? manager.alarms) ?? [] where alarm.state == .alerting {
            // One without a record comes from an older version; silencing stops it too.
            guard known[alarm.id.uuidString].map({ !wanted.isDisjoint(with: $0) }) ?? true else { continue }
            try? manager.cancel(id: alarm.id)
        }
    }

    /// An alarm in a minute with the real buttons and no medication, to try slide, button and side button.
    func scheduleTest(snooze: TimeInterval) async -> String? {
        let id = UUID()
        let configuration = Self.configuration(date: .now.addingTimeInterval(60), title: L("Thử báo thức Pillot", "Pillot alarm test"), names: "Pillot", id: id, dosesDueAt: [:], snooze: snooze)
        // Recorded before scheduling: a reschedule running meanwhile would otherwise cancel it as an unknown alarm.
        UserDefaults.standard.set(id.uuidString, forKey: Self.testAlarmKey)
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        } catch {
            return String(describing: error)
        }
        return nil
    }

    /// The `medications` text of the test alarm's intents: they log what was pressed and change nothing else.
    static let testIDs = "test"

    /// Stops the test alarm. A `.custom` button does not stop the ringing by itself.
    static func stopTestAlarm() {
        guard let id = UserDefaults.standard.string(forKey: testAlarmKey).flatMap(UUID.init(uuidString:)) else { return }
        try? AlarmManager.shared.cancel(id: id)
    }

    /// A "Taken" button right on the notification, without opening the app.
    static func registerCategory() {
        let taken = UNNotificationAction(identifier: takenAction, title: L("Đã uống", "Taken"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: doseCategory, actions: [taken], intentIdentifiers: []),
        ])
    }
}

/// Stop on the alarm, which is slide to stop and the side button: silences this ring and changes nothing else. Runs in the
/// background without opening the app.
struct StopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop"
    static let isDiscoverable = false

    /// Used by alarms already on the phone when updating.
    @Parameter(title: "Medications")
    var medications: String

    @Parameter(title: "Alarm ID")
    var alarmID: String?

    init() { medications = "" }

    init(alarmID: UUID) {
        medications = ""
        self.alarmID = alarmID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AlarmLog.record(L("Kéo hoặc nút nguồn: tắt lần này", "Slide or side button: silenced this ring"))
        if let id = alarmID.flatMap(UUID.init(uuidString:)) {
            try? AlarmManager.shared.stop(id: id)
        } else if medications != ReminderScheduler.testIDs {
            AppModel.shared.silence(medications.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }
        return .result()
    }
}

/// Taken on the alarm: opens the app, silences the ring and asks "Taken?". Logging needs that second tap, so a hardware
/// button that presses this button by accident logs nothing.
struct ConfirmTakenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Taken"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    /// Used by alarms already on the phone when updating.
    @Parameter(title: "Medications")
    var medications: String

    @Parameter(title: "Alarm ID")
    var alarmID: String?

    @Parameter(title: "Dose dates")
    var doseDates: String?

    init() { medications = "" }

    init(alarmID: UUID, dosesDueAt: [UUID: Date]) {
        medications = dosesDueAt.isEmpty ? ReminderScheduler.testIDs : ""
        self.alarmID = alarmID.uuidString
        doseDates = (try? JSONEncoder().encode(dosesDueAt)).map { String(decoding: $0, as: UTF8.self) }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AlarmLog.record(L("Nút Đã uống: mở app hỏi xác nhận", "Taken button: asked in the app"))
        if let id = alarmID.flatMap(UUID.init(uuidString:)) {
            try? AlarmManager.shared.stop(id: id)
        } else if medications == ReminderScheduler.testIDs {
            ReminderScheduler.stopTestAlarm()
        } else {
            AppModel.shared.silence(medications.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }
        if medications == ReminderScheduler.testIDs {
            AppModel.shared.askTestTaken()
        } else if let doseDates, let doses = try? JSONDecoder().decode([UUID: Date].self, from: Data(doseDates.utf8)) {
            AppModel.shared.askTaken(dosesDueAt: doses)
        } else {
            AppModel.shared.openToday = true
        }
        return .result()
    }
}

/// The last things pressed on an alarm, newest first, for Diagnostics: the Simulator shows no alarm screen to press.
enum AlarmLog {
    private static let key = "alarmLog"

    static func record(_ what: String, at date: Date = .now) {
        #if DEBUG
        NSLog("PILLOTDBG alarm button: %@", what)
        #endif
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        lines.insert("\(TimeFormatting.vn(date)) \(what)", at: 0)
        UserDefaults.standard.set(Array(lines.prefix(5)), forKey: key)
    }

    static var lines: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Tapping the notification itself opens the app on Today, where the dose is.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { AppModel.shared.openToday = true }
        }
        if response.actionIdentifier == ReminderScheduler.takenAction {
            let userInfo = response.notification.request.content.userInfo
            let dates = userInfo[ReminderScheduler.dosesDueAtKey] as? [String: Date] ?? [:]
            let doses = dates.reduce(into: [UUID: Date]()) { result, date in
                if let id = UUID(uuidString: date.key) { result[id] = date.value }
            }
            await AppModel.shared.markTaken(dosesDueAt: doses)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound]
    }
}
