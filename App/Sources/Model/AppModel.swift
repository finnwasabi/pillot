import AlarmKit
import BackgroundTasks
import Foundation
import Network
import PillotCore
import Observation
import SwiftUI
import WidgetKit

/// App state: loads and saves data and reschedules reminders after every change.
/// Shared by the screens, the alarm App Intent and the notification action.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var medications: [Medication] {
        didSet { summaryCache = nil }
    }
    /// Load, save or scheduling errors. Shown on the Today screen, never swallowed.
    var issue: String? { scheduleIssue ?? dataIssue }
    private var dataIssue: String?
    private var scheduleIssue: String?
    /// The latest message the partner sent through the bot, received on sync.
    private(set) var message: String? = UserDefaults.standard.string(forKey: "message")

    /// Language of the app, notifications and alarms. Changing it reschedules everything so alert texts follow.
    var language: Language = AppLanguage.current {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.key)
            SharedStorage.defaults?.set(language.rawValue, forKey: AppLanguage.key)
            WidgetCenter.shared.reloadAllTimelines()
            Task { await resync() }
        }
    }

    // MARK: Names

    /// The main user's name, entered on first launch or in Settings. Sent with the snapshot so the bot uses it.
    // No sync here because this changes on every keystroke; the name goes out with the next sync.
    var userName: String = UserDefaults.standard.string(forKey: "userName") ?? "" {
        didSet {
            if userName.count > Self.nameLimit { userName = String(userName.prefix(Self.nameLimit)) }
            UserDefaults.standard.set(userName, forKey: "userName")
        }
    }

    /// Names are capped so greetings and sentences stay readable.
    static let nameLimit = 40

    /// The partner's name, optional.
    var partnerName: String = UserDefaults.standard.string(forKey: "partnerName") ?? "" {
        didSet {
            if partnerName.count > Self.nameLimit { partnerName = String(partnerName.prefix(Self.nameLimit)) }
            UserDefaults.standard.set(partnerName, forKey: "partnerName")
        }
    }

    /// Greeting with the user's name, or a neutral one without it.
    var greeting: String {
        let name = userName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? L("Chào bạn", "Hi there") : L("Chào \(name)", "Hi \(name)")
    }

    /// How texts refer to the partner: the entered name, or "your partner" without one.
    var partner: String {
        let name = partnerName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? L("người ấy", "your partner") : name
    }

    /// Light, dark, or following the phone.
    var theme: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    // MARK: Reminder preferences

    /// Follow phone: reminders are plain notifications that respect the phone's mode, but the deadline is still a ringing alarm.
    var vibrateOnly: Bool {
        didSet {
            UserDefaults.standard.set(vibrateOnly, forKey: "vibrateOnly")
            Task { await resync() }
        }
    }

    /// How often a dose that is not taken rings again, and the snooze button's label: 9 minutes by default, 5 to 15.
    /// Shorter rings would use up the alarm budget.
    static let snoozeRange = 5...15
    var snoozeMinutes: Int = min(max(UserDefaults.standard.object(forKey: "snoozeMinutes") as? Int ?? 9, snoozeRange.lowerBound), snoozeRange.upperBound) {
        didSet {
            // Assign only when out of range: with @Observable, assigning inside didSet runs didSet again, and an
            // unconditional clamp here recursed forever (0.2.0 crashed on the first tap of the snooze stepper).
            guard Self.snoozeRange.contains(snoozeMinutes) else {
                snoozeMinutes = min(max(snoozeMinutes, Self.snoozeRange.lowerBound), Self.snoozeRange.upperBound)
                return
            }
            guard snoozeMinutes != oldValue else { return }
            UserDefaults.standard.set(snoozeMinutes, forKey: "snoozeMinutes")
            // Holding the stepper changes this many times a second; reschedule once it settles.
            snoozeResync?.cancel()
            snoozeResync = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                await resync()
            }
        }
    }
    @ObservationIgnored private var snoozeResync: Task<Void, Never>?

    // MARK: Shared tracking

    private(set) var connection: SyncConnection? = ConnectionKeychain.load().flatMap(SyncConnection.init(code:))
    var shareEnabled: Bool = UserDefaults.standard.object(forKey: "shareEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(shareEnabled, forKey: "shareEnabled")
            Task { await sync() }
        }
    }
    private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "lastSync") as? Date
    /// The latest sync error, shown only in Settings: being offline is normal and should not clutter Today.
    private(set) var syncIssue: String?

    private let store: PlanStore
    private let scheduler = ReminderScheduler()
    private let syncClient = SyncClient()
    private let network = NWPathMonitor()

    init() {
        let directory = URL.applicationSupportDirectory
        let privateURL = directory.appending(path: "state.json")
        // Move the data into the App Group once, so the widget can read it. Without a group it stays where it was.
        if let shared = SharedStorage.sharedStateURL {
            if !FileManager.default.fileExists(atPath: shared.path), FileManager.default.fileExists(atPath: privateURL.path) {
                try? FileManager.default.copyItem(at: privateURL, to: shared)
            }
            store = PlanStore(url: FileManager.default.fileExists(atPath: shared.path) || !FileManager.default.fileExists(atPath: privateURL.path) ? shared : privateURL)
        } else {
            store = PlanStore(url: privateURL)
        }
        SharedStorage.defaults?.set(AppLanguage.current.rawValue, forKey: AppLanguage.key)
        vibrateOnly = UserDefaults.standard.bool(forKey: "vibrateOnly")
        do {
            medications = try store.load()
        } catch {
            // Keep the corrupt file for recovery and continue empty so the app still opens.
            let backup = directory.appending(path: "state-corrupt-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: store.url, to: backup)
            medications = []
            dataIssue = L("Không đọc được dữ liệu cũ, đã cất vào \(backup.lastPathComponent). Thêm lại thuốc trong tab Thuốc.", "Could not read old data, saved it as \(backup.lastPathComponent). Add your medications again in the Meds tab.")
        }
        // Data from before medications had names: give it one in the chosen language.
        if medications.contains(where: { $0.name.isEmpty }) {
            for i in medications.indices where medications[i].name.isEmpty { medications[i].name = L("Thuốc hằng ngày", "Daily pill") }
            persist()
        }
        // When the network comes back (after landing), send the latest snapshot.
        network.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await AppModel.shared.sync() }
        }
        network.start(queue: .global(qos: .utility))
    }

    func medication(_ id: UUID) -> Medication? { medications.first { $0.id == id } }

    @ObservationIgnored private var summaryCache: (minute: Int, summaries: [UUID: PlannerSummary], derived: [String: Any])?

    /// Every medication's summary, walked once per data change or minute and shared by Today and History, so a redraw
    /// (a tap, a filter, a dialog) does not walk every history again.
    func summaries(now: Date = .now) -> [UUID: PlannerSummary] {
        // Read before the cache check so a view still observes the medications on a cache hit.
        let medications = medications
        let minute = Int(now.timeIntervalSinceReferenceDate / 60)
        if let summaryCache, summaryCache.minute == minute { return summaryCache.summaries }
        let summaries = Dictionary(uniqueKeysWithValues: medications.map { ($0.id, $0.planner.summary(now: now)) })
        summaryCache = (minute, summaries, [:])
        return summaries
    }

    /// Something a screen works out from `summaries` (calendar statuses, a sorted history), kept as long as they are.
    /// `key` names it uniquely, including any filter it depends on.
    func derived<T>(_ key: String, now: Date = .now, _ make: () -> T) -> T {
        _ = summaries(now: now)
        if let value = summaryCache?.derived[key] as? T { return value }
        let value = make()
        summaryCache?.derived[key] = value
        return value
    }

    /// The next swatch, so new medications do not all look the same.
    var nextColor: Int {
        (0..<Swatch.colors.count).min { a, b in
            medications.filter { $0.color == a }.count < medications.filter { $0.color == b }.count
        } ?? 0
    }

    // MARK: Connection

    /// Paste the connection code from the /link command. Returns `false` if the code is malformed.
    func connect(code: String) async -> Bool {
        guard let parsed = SyncConnection(code: code) else { return false }
        ConnectionKeychain.save(code.trimmingCharacters(in: .whitespacesAndNewlines))
        connection = parsed
        await sync()
        return true
    }

    func disconnect() {
        ConnectionKeychain.save(nil)
        connection = nil
        syncIssue = nil
    }

    func sync() async {
        guard shareEnabled, let connection else { return }
        do {
            let name = userName.trimmingCharacters(in: .whitespaces)
            let snapshot = Snapshot(name: name.isEmpty ? nil : String(name.prefix(60)), medications: medications, now: .now)
            let reply = try await syncClient.send(snapshot, to: connection)
            message = reply.message
            UserDefaults.standard.set(reply.message, forKey: "message")
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: "lastSync")
            syncIssue = nil
        } catch {
            syncIssue = L("Chưa đồng bộ được: \(error.localizedDescription) App sẽ gửi lại khi có mạng.", "Not synced yet: \(error.localizedDescription) The app retries when online.")
        }
    }

    // MARK: Actions

    /// "Taken" for these medications. An empty list (an alarm from before medications existed) means every medication
    /// that is due now.
    func markTaken(_ ids: [UUID], now: Date = .now) async {
        let targets = ids.isEmpty ? medications.filter { $0.planner.currentDose(now: now).dueAt <= now }.map(\.id) : ids
        for id in targets {
            guard let i = medications.firstIndex(where: { $0.id == id }) else { continue }
            // Tapping on the alarm and again in the app counts once.
            if let last = medications[i].planner.lastTaken(now: now)?.takenAt,
               now.timeIntervalSince(last) < medications[i].settings.undoWindow { continue }
            medications[i].planner.markTaken(at: now)
        }
        persist()
        await resync(cancelActiveFor: Set(targets))
    }

    /// Slide to stop or the side button on a ringing alarm: silences this ring, the next one is already scheduled.
    func silence(_ ids: [UUID]) {
        scheduler.silence(ids)
    }

    /// "Taken?" asked after the Taken button on an alarm; RootView shows it.
    struct TakenQuestion: Identifiable {
        let id = UUID()
        /// Empty for the test alarm.
        let ids: [UUID]
        let names: String
    }
    var takenQuestion: TakenQuestion?

    /// "Back to the usual time?" from a Today card. RootView shows it, like `takenQuestion`.
    struct RealignQuestion: Identifiable {
        let id = UUID()
        let medicationID: UUID
        let preview: ResetPreview
    }
    var realignQuestion: RealignQuestion?

    /// A taken time being edited from History. RootView shows the sheet, so a tab change does not tear it down.
    struct TimeEdit: Identifiable {
        let id = UUID()
        let medicationID: UUID
        let record: DoseRecord
    }
    var timeEdit: TimeEdit?

    /// The Taken button on an alarm: silence the ring now, log only once the person confirms in the app.
    func askTaken(_ medications: String) {
        guard medications != ReminderScheduler.testIDs else {
            ReminderScheduler.stopTestAlarm()
            takenQuestion = TakenQuestion(ids: [], names: L("thuốc thử", "the test pill"))
            return
        }
        let ids = medications.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        // An empty list (an alarm from before medications) means every medication due now, as in `markTaken`.
        let meds = ids.isEmpty ? medications.isEmpty ? self.medications.filter { $0.planner.currentDose(now: .now).dueAt <= .now } : [] : ids.compactMap(medication)
        guard !meds.isEmpty else { return }
        scheduler.silence(meds.map(\.id))
        takenQuestion = TakenQuestion(ids: meds.map(\.id), names: AlertPlanner.names(meds.map(\.name), language: language))
    }

    /// The test alarm in Settings; the error text when it could not be scheduled.
    func testAlarm() async -> String? {
        await scheduler.scheduleTest(snooze: TimeInterval(snoozeMinutes * 60))
    }

    func undo(_ id: UUID, now: Date = .now) async {
        guard let i = medications.firstIndex(where: { $0.id == id }), medications[i].planner.undoLastTaken(now: now) else { return }
        persist()
        await resync()
    }

    /// "Skip this dose": not a miss, uses no pill. Stops the medication's ringing or snoozed alarm.
    func skip(_ id: UUID) {
        update(id, stopsAlarms: true) { $0.planner.skip(at: .now) }
    }

    // MARK: Backup

    /// When a backup was last saved from this phone.
    private(set) var lastBackup: Date? = UserDefaults.standard.object(forKey: "lastBackup") as? Date

    /// Everything a restore needs, except the connection code (a secret, /link gives it again).
    func makeBackup(now: Date = .now) -> Backup {
        Backup(createdAt: now, medications: medications, preferences: [
            "userName": userName, "partnerName": partnerName, "language": language.rawValue, "theme": theme.rawValue,
            "vibrateOnly": String(vibrateOnly), "snoozeMinutes": String(snoozeMinutes),
        ])
    }

    func backupSaved(at date: Date = .now) {
        lastBackup = date
        UserDefaults.standard.set(date, forKey: "lastBackup")
    }

    /// Replaces every medication and the preferences with the backup's, then reschedules.
    func restore(_ backup: Backup) {
        let replaced = Set(medications.map(\.id))
        medications = Array(backup.medications.prefix(Medication.limit))
        let p = backup.preferences
        if let value = p["userName"] { userName = value }
        if let value = p["partnerName"] { partnerName = value }
        if let value = p["theme"].flatMap(AppTheme.init(rawValue:)) { theme = value }
        if let value = p["vibrateOnly"].flatMap(Bool.init) { vibrateOnly = value }
        if let value = p["snoozeMinutes"].flatMap(Int.init) { snoozeMinutes = value }
        persist()
        // The language last: it rebuilds every screen.
        if let value = p["language"].flatMap(Language.init(rawValue:)), value != language { language = value }
        Task { await resync(cancelActiveFor: replaced.union(medications.map(\.id))) }
    }

    /// "Mark made up" for a missed dose.
    func markMadeUp(_ id: UUID, missedAt scheduledAt: Date) {
        update(id) { $0.planner.markMadeUp(missedAt: scheduledAt, at: .now) }
    }

    /// Every change to one medication's settings, pills, pauses or taken times goes through here: save, then reschedule.
    /// `stopsAlarms`: also stop this medication's ringing or snoozed alarm, for example when pausing it.
    func update(_ id: UUID, stopsAlarms: Bool = false, _ change: (inout Medication) -> Void) {
        guard let i = medications.firstIndex(where: { $0.id == id }) else { return }
        change(&medications[i])
        persist()
        Task { await resync(cancelActiveFor: stopsAlarms ? [id] : []) }
    }

    func add(_ medication: Medication) {
        guard medications.count < Medication.limit else { return }
        medications.append(medication)
        persist()
        Task { await resync() }
    }

    func delete(_ id: UUID) {
        medications.removeAll { $0.id == id }
        persist()
        Task { await resync(cancelActiveFor: [id]) }
    }

    private func persist() {
        do {
            try store.save(medications)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            dataIssue = L("Không lưu được dữ liệu: \(error.localizedDescription)", "Could not save your data: \(error.localizedDescription)")
        }
    }

    // MARK: Rescheduling

    // MARK: Background refresh

    nonisolated static let refreshTask = "io.github.finnwasabi.nersdaily.refresh"

    /// When iOS last woke the app in the background to top up the reminders.
    private(set) var lastBackgroundRefresh: Date? = UserDefaults.standard.object(forKey: "lastBackgroundRefresh") as? Date

    /// Asks iOS for a background run in a few hours. Without one the reminders are only refilled when the app is opened
    /// or "Taken" is tapped, and the alarms run out after the planned days.
    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = .now.addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    func backgroundRefresh() async {
        Self.scheduleRefresh()
        lastBackgroundRefresh = .now
        UserDefaults.standard.set(lastBackgroundRefresh, forKey: "lastBackgroundRefresh")
        await resync()
    }

    /// The latest scheduling pass, shown under Diagnostics in Settings.
    private(set) var scheduleReport: ScheduleReport?

    struct ScheduleReport {
        var result: ReminderScheduler.Report
        var at: Date
        var duration: Duration
    }

    private var syncing = false
    private var syncAgain = false
    private var cancelPending: Set<UUID> = []
    /// What the last pass handed to the scheduler without a failure. The same plan again means nothing to change.
    @ObservationIgnored private var lastApplied: (alerts: [PlannedAlert], snoozeMinutes: Int, language: Language, alarmsAvailable: Bool)?

    /// Reschedules all alarms and notifications, changing only what differs. Overlapping calls coalesce into one more pass
    /// after the running one. `cancelActiveFor`: also stop alarms of these medications that are ringing or snoozed (after a dose is taken).
    func resync(cancelActiveFor ids: Set<UUID> = []) async {
        cancelPending.formUnion(ids)
        guard !syncing else {
            syncAgain = true
            return
        }
        syncing = true
        // One action often starts several passes at once (restore, the editor); let them queue up and run as this one.
        await Task.yield()
        repeat {
            syncAgain = false
            let cancel = cancelPending
            cancelPending = []
            let now = Date.now
            let started = ContinuousClock.now
            let alarmsAvailable = AlarmManager.shared.authorizationState == .authorized
            let alerts = AlertPlanner.alerts(
                for: medications.map { MedicationReminders($0, now: now, language: language, cadence: TimeInterval(snoozeMinutes * 60)) },
                vibrateOnly: vibrateOnly,
                alarmsAvailable: alarmsAvailable,
                language: language
            )
            // Opening the app with nothing due in between plans the same alerts: skip reading back every alarm and notification.
            if cancel.isEmpty, let lastApplied, lastApplied.alerts == alerts, lastApplied.snoozeMinutes == snoozeMinutes, lastApplied.language == language,
               lastApplied.alarmsAvailable == alarmsAvailable,
               var report = scheduleReport {
                report.result.changed = 0
                report.at = now
                report.duration = ContinuousClock.now - started
                scheduleReport = report
                continue
            }
            let result = await scheduler.apply(alerts, cancelActiveFor: cancel, snooze: TimeInterval(snoozeMinutes * 60), language: language)
            scheduleReport = ScheduleReport(result: result, at: now, duration: ContinuousClock.now - started)
            lastApplied = result.failures == 0 ? (alerts, snoozeMinutes, language, alarmsAvailable) : nil
            let failures = result.failures
            // Screenshot launches (`-screen`) run in the Simulator, which always denies alarms.
            if medications.isEmpty || UserDefaults.standard.string(forKey: "screen") != nil {
                scheduleIssue = nil
            } else if !alarmsAvailable {
                scheduleIssue = L("Chưa có quyền báo thức nên máy im lặng hay bật Focus sẽ không kêu. Bật trong Cài đặt > Pillot.", "Alarms are not allowed, so nothing rings on silent or in Focus. Turn them on in Settings > Pillot.")
            } else if failures > 0 {
                scheduleIssue = L("Có \(failures) lần nhắc không hẹn được: \(result.firstError ?? "?"). Mở lại app để thử lại.", "\(failures) reminders could not be scheduled: \(result.firstError ?? "?"). Reopen the app to retry.")
            } else {
                scheduleIssue = nil
            }
        } while syncAgain
        syncing = false
        await sync()
    }
}

enum AppTheme: String {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
