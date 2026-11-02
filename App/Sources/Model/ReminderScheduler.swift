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
    /// Which medications each scheduled alarm is for. AlarmKit does not hand the metadata back, so it lives here.
    private static let alarmMedicationsKey = "alarmMedications"

    /// The key each scheduled alarm was made from (`PlannedAlert.key`), so the next pass can leave it alone.
    private static let alarmKeysKey = "alarmKeys"
    /// Bumped when the alarm's buttons or intents change, so alarms set by an older version are all replaced once.
    /// 2: Stop snoozes and Taken is the secondary button (0.4.2).
    /// 3: Slide to stop (and the side button) is Taken, the button is Snooze (0.5.1).
    private static let buttonsVersion = 3
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
    }

    /// Brings the scheduled alarms and notifications in line with `alerts`, touching only what differs.
    /// `cancelActiveFor`: alarms of these medications that are ringing or snoozed are stopped too. Others keep ringing,
    /// so taking one medication never silences another one's reminder.
    func apply(_ alerts: [PlannedAlert], cancelActiveFor taken: Set<UUID>, snooze: TimeInterval, language: Language) async -> Report {
        var report = Report()
        let snoozeMinutes = Int(snooze / 60)
        // Notification button titles follow the selected language.
        Self.registerCategory()
        let manager = AlarmManager.shared
        let defaults = UserDefaults.standard
        let known = defaults.dictionary(forKey: Self.alarmMedicationsKey) as? [String: [String]] ?? [:]
        let knownKeys = defaults.dictionary(forKey: Self.alarmKeysKey) as? [String: String] ?? [:]
        let takenIDs = Set(taken.map(\.uuidString))
        var kept: [String: [String]] = [:]
        var keptKeys: [String: String] = [:]
        var scheduled: [String: String] = [:]
        // Without the list every planned alarm would look new and be scheduled twice, so a failed read ends the pass.
        guard let current = try? manager.alarms else {
            report.failures += 1
            return report
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
                if let key = knownKeys[id] { scheduled[id] = key } else { try? manager.cancel(id: alarm.id) }
                continue
            }
            // Ringing or snoozed. One without a record comes from a version before medications; any "Taken" stops it.
            let belongsToTaken = meds.map { !takenIDs.isDisjoint(with: $0) } ?? !taken.isEmpty
            if belongsToTaken {
                try? manager.cancel(id: alarm.id)
            } else if let meds {
                kept[id] = meds
            }
        }
        let plannedAlarms = alerts.filter(\.usesAlarm)
        let alarmKeys = plannedAlarms.map { "b\(Self.buttonsVersion)|" + $0.key(snoozeMinutes: snoozeMinutes, language: language) }
        let alarmDiff = AlertDiff.diff(scheduled: scheduled, planned: alarmKeys)
        for id in alarmDiff.cancel.compactMap(UUID.init(uuidString:)) { try? manager.cancel(id: id) }
        let cancelled = Set(alarmDiff.cancel)
        for (id, key) in scheduled where !cancelled.contains(id) {
            kept[id] = known[id]
            keptKeys[id] = key
        }
        var failed: Set<Int> = []
        for index in alarmDiff.add {
            let alert = plannedAlarms[index], id = UUID()
            do {
                _ = try await manager.schedule(id: id, configuration: Self.configuration(for: alert, snooze: snooze))
                kept[id.uuidString] = alert.medicationIDs.map(\.uuidString)
                keptKeys[id.uuidString] = alarmKeys[index]
            } catch {
                failed.insert(index)
                report.failures += 1
                report.firstError = report.firstError ?? String(describing: error)
            }
        }
        defaults.set(kept, forKey: Self.alarmMedicationsKey)
        defaults.set(keptKeys, forKey: Self.alarmKeysKey)
        report.alarms = kept.count
        report.changed = alarmDiff.cancel.count + alarmDiff.add.count
        report.lastAlert = plannedAlarms.indices.filter { !failed.contains($0) }.map { plannedAlarms[$0].date }.max()

        // Notifications use the key as their identifier, so the pending list itself says what is already scheduled.
        let center = UNUserNotificationCenter.current()
        if !taken.isEmpty {
            let delivered = await center.deliveredNotifications().filter { note in
                let meds = note.request.content.userInfo[Self.medicationsKey] as? [String] ?? []
                return meds.isEmpty || !takenIDs.isDisjoint(with: meds)
            }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier))
        }
        let notes = alerts.filter { !$0.usesAlarm && $0.date.timeIntervalSinceNow >= 1 }
        let noteKeys = notes.map { $0.key(snoozeMinutes: snoozeMinutes, language: language) }
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let noteDiff = AlertDiff.diff(scheduled: Dictionary(uniqueKeysWithValues: pending.map { ($0, $0) }), planned: noteKeys)
        center.removePendingNotificationRequests(withIdentifiers: noteDiff.cancel)
        report.notifications = pending.count - noteDiff.cancel.count
        for index in noteDiff.add {
            let alert = notes[index]
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.categoryIdentifier = Self.doseCategory
            content.userInfo = [Self.medicationsKey: alert.medicationIDs.map(\.uuidString)]
            // Seconds from now: the absolute time is in the key, so a kept request still fires when planned.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, alert.date.timeIntervalSinceNow), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: noteKeys[index], content: content, trigger: trigger))
                report.notifications += 1
            } catch {
                report.failures += 1
                report.firstError = report.firstError ?? String(describing: error)
            }
        }
        report.changed += noteDiff.cancel.count + noteDiff.add.count
        if let last = notes.last?.date { report.lastAlert = max(report.lastAlert ?? last, last) }
        return report
    }

    private static func configuration(for alert: PlannedAlert, snooze: TimeInterval) -> AlarmManager.AlarmConfiguration<DoseAlarmMetadata> {
        configuration(date: alert.date, title: alert.title, names: alert.names, ids: alert.medicationIDs.map(\.uuidString).joined(separator: ","), snooze: snooze)
    }

    private static func configuration(date: Date, title: String, names: String, ids: String, snooze: TimeInterval) -> AlarmManager.AlarmConfiguration<DoseAlarmMetadata> {
        AlarmManager.AlarmConfiguration(
            // Keep a countdown duration: with nil, AlarmKit refused every alarm (error code 0) in 0.5.1. The Snooze button is
            // `.custom` and never starts it.
            countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snooze),
            schedule: .fixed(date),
            attributes: attributes(title: title, names: names, snooze: snooze),
            stopIntent: StopIntent(medications: ids),
            secondaryIntent: SnoozeIntent(medications: ids)
        )
    }

    /// Like the Clock app: the button snoozes, sliding to stop (iOS 26.1 and later; the side button presses the same
    /// control) is the dose taken. The button does not start a system countdown. The reminders already repeat every
    /// snooze length, so a countdown of its own would ring between two of them.
    private static func attributes(title: String, names: String, snooze: TimeInterval) -> AlarmAttributes<DoseAlarmMetadata> {
        let minutes = Int(snooze / 60)
        let snoozeButton = AlarmButton(text: LocalizedStringResource(stringLiteral: L("Hoãn \(minutes) phút", "Snooze \(minutes) min")), textColor: .white, systemImageName: "zzz")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), secondaryButton: snoozeButton, secondaryButtonBehavior: .custom)
        } else {
            let stop = AlarmButton(text: LocalizedStringResource(stringLiteral: L("Đã uống", "Taken")), textColor: .black, systemImageName: "checkmark")
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop, secondaryButton: snoozeButton, secondaryButtonBehavior: .custom)
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

    /// The Snooze button: silences the ringing alarm of these medications. The next reminder is already scheduled.
    func silence(_ ids: [UUID]) {
        let manager = AlarmManager.shared
        let known = UserDefaults.standard.dictionary(forKey: Self.alarmMedicationsKey) as? [String: [String]] ?? [:]
        let wanted = Set(ids.map(\.uuidString))
        for alarm in (try? manager.alarms) ?? [] where alarm.state == .alerting {
            // One without a record comes from an older version; the button silences it too.
            guard known[alarm.id.uuidString].map({ !wanted.isDisjoint(with: $0) }) ?? true else { continue }
            try? manager.cancel(id: alarm.id)
        }
    }

    /// An alarm in a minute with the real buttons and no medication, to try slide, button and side button.
    func scheduleTest(snooze: TimeInterval) async -> String? {
        let id = UUID()
        let names = "Pillot"
        let configuration = Self.configuration(date: .now.addingTimeInterval(60), title: L("Thử báo thức Pillot", "Pillot alarm test"), names: names, ids: Self.testIDs, snooze: snooze)
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        } catch {
            return String(describing: error)
        }
        UserDefaults.standard.set(id.uuidString, forKey: Self.testAlarmKey)
        return nil
    }

    /// The `medications` text of the test alarm's intents: they log what was pressed and change nothing else.
    static let testIDs = "test"

    /// A "Taken" button right on the notification, without opening the app.
    static func registerCategory() {
        let taken = UNNotificationAction(identifier: takenAction, title: L("Đã uống", "Taken"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: doseCategory, actions: [taken], intentIdentifiers: []),
        ])
    }
}

/// Slide to stop on the alarm, or the side button on iOS 26.1 and later: the dose is taken. Runs in the background without opening the app.
struct StopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop"
    static let isDiscoverable = false

    /// Medication ids separated by commas.
    @Parameter(title: "Medications")
    var medications: String

    init() { medications = "" }

    init(medications: String) { self.medications = medications }

    @MainActor
    func perform() async throws -> some IntentResult {
        AlarmLog.record(L("Kéo hoặc nút nguồn: ghi Đã uống", "Slide or side button: logged Taken"))
        if medications != ReminderScheduler.testIDs {
            await AppModel.shared.markTaken(medications.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }
        return .result()
    }
}

/// The Snooze button on the alarm: silences this ring; the next reminder follows in the snooze length.
struct SnoozeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze"
    static let isDiscoverable = false

    /// Medication ids separated by commas.
    @Parameter(title: "Medications")
    var medications: String

    init() { medications = "" }

    init(medications: String) { self.medications = medications }

    @MainActor
    func perform() async throws -> some IntentResult {
        AlarmLog.record(L("Nút Hoãn", "Snooze button"))
        if medications != ReminderScheduler.testIDs {
            AppModel.shared.snooze(medications.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }
        return .result()
    }
}

/// The last things pressed on an alarm, newest first, for Diagnostics: the side button cannot be tried in the Simulator.
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
        if response.actionIdentifier == ReminderScheduler.takenAction {
            let ids = (response.notification.request.content.userInfo[ReminderScheduler.medicationsKey] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            await AppModel.shared.markTaken(ids)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
