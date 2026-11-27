import AlarmKit
import BackgroundTasks
import Foundation
import Network
import PillotCore
import Observation
import SwiftUI
import UserNotifications
import WidgetKit

/// App state: loads and saves data and reschedules reminders after every change.
/// Shared by the screens, the alarm App Intent and the notification action.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var medications: [Medication] = [] {
        didSet { summaryCache = nil }
    }
    /// Load, save or scheduling errors. Shown on the Today screen, never swallowed.
    var issue: String? { dataIssue ?? scheduleIssue }
    private(set) var dataIssue: String?
    private var scheduleIssue: String?
    private enum StorageState { case pending, loaded, recoveryCopySaved }
    @ObservationIgnored private var storageState = StorageState.pending
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

    /// A quiet notification this many minutes before each dose time, for when the phone is at hand. 0 turns it off.
    static let headsUpRange = 0...30
    var headsUpMinutes: Int = min(max(UserDefaults.standard.object(forKey: "headsUpMinutes") as? Int ?? 10, headsUpRange.lowerBound), headsUpRange.upperBound) {
        didSet {
            // Same guard as `snoozeMinutes`: assign inside didSet only when out of range.
            guard Self.headsUpRange.contains(headsUpMinutes) else {
                headsUpMinutes = min(max(headsUpMinutes, Self.headsUpRange.lowerBound), Self.headsUpRange.upperBound)
                return
            }
            guard headsUpMinutes != oldValue else { return }
            UserDefaults.standard.set(headsUpMinutes, forKey: "headsUpMinutes")
            snoozeResync?.cancel()
            snoozeResync = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                await resync()
            }
        }
    }

    // MARK: Shared tracking

    private(set) var connection: SyncConnection? = ConnectionKeychain.load().flatMap(SyncConnection.init(code:))
    var shareEnabled: Bool = UserDefaults.standard.object(forKey: "shareEnabled") as? Bool ?? true {
        didSet {
            guard shareEnabled != oldValue else { return }
            UserDefaults.standard.set(shareEnabled, forKey: "shareEnabled")
            if shareEnabled { Task { await sync() } } else { cancelUpload() }
        }
    }
    private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "lastSync") as? Date
    /// The latest sync error, shown only in Settings: being offline is normal and should not clutter Today.
    private(set) var syncIssue: String?

    private let store: PlanStore
    private let scheduler = ReminderScheduler()
    private let syncClient = SyncClient()
    private let network = NWPathMonitor()
    @ObservationIgnored private var uploadRequested = false
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var uploadRequest: Task<SyncClient.Reply, Error>?
    @ObservationIgnored private var lastSnapshotSecond: Date?

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
        _ = loadStateIfNeeded()
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

    enum ConnectionFailure: LocalizedError {
        case invalidCode
        case keychain(Error)

        var errorDescription: String? {
            switch self {
            case .invalidCode:
                L("Mã không đúng dạng. Mã bắt đầu bằng https:// và có dấu #.", "Invalid code. It starts with https:// and contains #.")
            case .keychain(let error):
                L("Không lưu được kết nối: \(error.localizedDescription)", "Could not save the connection: \(error.localizedDescription)")
            }
        }
    }

    /// Saves the code from /link and starts syncing without making the screen wait for the network.
    func connect(code: String) throws {
        guard let parsed = SyncConnection(code: code) else { throw ConnectionFailure.invalidCode }
        do {
            try ConnectionKeychain.save(code.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw ConnectionFailure.keychain(error)
        }
        if connection != parsed { resetSyncStatus() }
        connection = parsed
        Task { await sync() }
    }

    func disconnect() {
        do {
            try ConnectionKeychain.save(nil)
        } catch {
            syncIssue = L("Không gỡ được kết nối: \(error.localizedDescription)", "Could not disconnect: \(error.localizedDescription)")
            return
        }
        connection = nil
        resetSyncStatus()
    }

    private func resetSyncStatus() {
        cancelUpload()
        message = nil
        lastSync = nil
        syncIssue = nil
        UserDefaults.standard.removeObject(forKey: "message")
        UserDefaults.standard.removeObject(forKey: "lastSync")
    }

    private func cancelUpload() {
        uploadRequested = false
        uploadRequest?.cancel()
    }

    func sync() async {
        guard shareEnabled, connection != nil, loadStateIfNeeded() else { return }
        uploadRequested = true
        if uploadTask == nil { uploadTask = Task { await uploadSnapshots() } }
        await uploadTask?.value
    }

    private func uploadSnapshots() async {
        defer { uploadTask = nil }
        while uploadRequested, shareEnabled, let connection {
            let now = Date.now
            // The server keeps one snapshot per wire second. Wait before building a newer snapshot in the same second.
            if let nextSecond = lastSnapshotSecond?.addingTimeInterval(1) {
                let wait = nextSecond.timeIntervalSince(now)
                if wait > 0, wait <= 1 {
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
            }
            uploadRequested = false
            let name = userName.trimmingCharacters(in: .whitespaces)
            let snapshot = Snapshot(name: name.isEmpty ? nil : String(name.prefix(60)), medications: medications, now: now)
            lastSnapshotSecond = snapshot.updatedAt
            let request = Task { try await syncClient.send(snapshot, to: connection) }
            uploadRequest = request
            let result = await request.result
            uploadRequest = nil
            guard !request.isCancelled else { continue }
            switch result {
            case .success(let reply):
                message = reply.message
                UserDefaults.standard.set(reply.message, forKey: "message")
                if reply.stale {
                    syncIssue = L("Server đã có dữ liệu mới hơn. Kiểm tra ngày giờ trên máy.", "The server has newer data. Check the date and time on this device.")
                } else {
                    lastSync = .now
                    UserDefaults.standard.set(lastSync, forKey: "lastSync")
                    syncIssue = nil
                }
            case .failure(let error):
                syncIssue = L("Chưa đồng bộ được: \(error.localizedDescription) App sẽ gửi lại khi có mạng.", "Not synced yet: \(error.localizedDescription) The app retries when online.")
            }
        }
    }

    // MARK: Actions

    /// "Taken" for the medications the user selected in the app.
    @discardableResult
    func markTaken(_ ids: [UUID], now: Date = .now) async -> [Medication] {
        guard !ids.isEmpty, loadStateIfNeeded() else { return [] }
        var updated = medications
        var taken: [Medication] = []
        for id in ids {
            guard let i = updated.firstIndex(where: { $0.id == id }) else { continue }
            // Tapping on the alarm and again in the app counts once.
            if let last = updated[i].planner.lastTaken(now: now)?.takenAt,
               now.timeIntervalSince(last) < updated[i].settings.undoWindow { continue }
            updated[i].planner.markTaken(at: now)
            taken.append(updated[i])
        }
        guard !taken.isEmpty, saveMedications(updated) else { return [] }
        await resync(cancelActiveFor: Set(taken.map(\.id)))
        return taken
    }

    /// The bulk action and Shortcut both use the same set of due, active doses.
    func dueDoses(now: Date, using summaries: [UUID: PlannerSummary]? = nil) -> [UUID: Date] {
        var due: [UUID: Date] = [:]
        for medication in medications where !medication.settings.asNeeded {
            guard !medication.settings.courseEnded(now: now), medication.settings.pausedUntil(now: now) == nil else { continue }
            let date = summaries?[medication.id]?.dose.dueAt ?? medication.planner.currentDose(now: now).dueAt
            if date <= now { due[medication.id] = date }
        }
        return due
    }

    /// External actions are tied to the dose shown when the alert or widget was created.
    private func matchingDoseIDs(_ dueDates: [UUID: Date], now: Date) -> [UUID] {
        guard !dueDates.isEmpty, loadStateIfNeeded() else { return [] }
        return medications.compactMap { medication in
            guard let dueAt = dueDates[medication.id], dueAt != .distantFuture, !medication.settings.asNeeded,
                  !medication.settings.courseEnded(now: now), medication.settings.pausedUntil(now: now) == nil,
                  dueAt <= now || medication.planner.cycleBreakUntil(now: now) == nil,
                  medication.planner.currentDose(now: now).dueAt == dueAt else { return nil }
            return medication.id
        }
    }

    @discardableResult
    func markTaken(dosesDueAt: [UUID: Date], now: Date = .now) async -> [Medication] {
        await markTaken(matchingDoseIDs(dosesDueAt, now: now), now: now)
    }

    /// Slide to stop or the side button on a ringing alarm: silences this ring, the next one is already scheduled.
    func silence(_ ids: [UUID]) {
        scheduler.silence(ids)
    }

    /// Set when a reminder notification is tapped; RootView switches to Today and clears it.
    var openToday = false

    /// "Taken?" asked after the Taken button on an alarm; RootView shows it.
    struct TakenQuestion: Identifiable {
        let id = UUID()
        /// Empty for the test alarm.
        let dosesDueAt: [UUID: Date]
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

    /// The Taken button on an alarm still needs confirmation in the app.
    func askTaken(dosesDueAt: [UUID: Date]) {
        let ids = Set(matchingDoseIDs(dosesDueAt, now: .now))
        guard !ids.isEmpty else { return }
        let names = medications.filter { ids.contains($0.id) }.map(\.name)
        takenQuestion = TakenQuestion(dosesDueAt: dosesDueAt.filter { ids.contains($0.key) },
                                      names: AlertPlanner.names(names, language: language))
    }

    func askTestTaken() {
        takenQuestion = TakenQuestion(dosesDueAt: [:], names: L("thuốc thử", "the test pill"))
    }

    /// The test alarm in Settings; the error text when it could not be scheduled.
    func testAlarm() async -> String? {
        await scheduler.scheduleTest(snooze: TimeInterval(snoozeMinutes * 60))
    }

    func undo(_ id: UUID, now: Date = .now) async {
        guard loadStateIfNeeded(), let i = medications.firstIndex(where: { $0.id == id }) else { return }
        var updated = medications
        guard updated[i].planner.undoLastTaken(now: now), saveMedications(updated) else { return }
        await resync()
    }

    /// "Skip this dose": not a miss, uses no pill. Stops the medication's ringing or snoozed alarm.
    func skip(_ id: UUID, dueAt: Date, now: Date = .now) {
        guard !matchingDoseIDs([id: dueAt], now: now).isEmpty else { return }
        update(id, stopsAlarms: true) { $0.planner.skip(at: now) }
    }

    // MARK: Backup

    /// When a backup was last saved from this phone.
    private(set) var lastBackup: Date? = UserDefaults.standard.object(forKey: "lastBackup") as? Date

    /// Everything a restore needs, except the connection code (a secret, /link gives it again).
    func makeBackup(now: Date = .now) -> Backup {
        Backup(createdAt: now, medications: medications, preferences: [
            "userName": userName, "partnerName": partnerName, "language": language.rawValue, "theme": theme.rawValue,
            "vibrateOnly": String(vibrateOnly), "snoozeMinutes": String(snoozeMinutes), "headsUpMinutes": String(headsUpMinutes),
        ])
    }

    func backupSaved(at date: Date = .now) {
        lastBackup = date
        UserDefaults.standard.set(date, forKey: "lastBackup")
    }

    /// Replaces every medication and the preferences with the backup's, then reschedules.
    func restore(_ backup: Backup) -> Bool {
        guard loadStateIfNeeded() || storageState == .recoveryCopySaved else { return false }
        let replaced = Set(medications.map(\.id))
        let p = backup.preferences
        let restored = migratedMedications(backup.medications, now: .now)
        guard saveMedications(restored) else { return false }
        if let value = p["userName"] { userName = value }
        if let value = p["partnerName"] { partnerName = value }
        if let value = p["theme"].flatMap(AppTheme.init(rawValue:)) { theme = value }
        if let value = p["vibrateOnly"].flatMap(Bool.init) { vibrateOnly = value }
        if let value = p["snoozeMinutes"].flatMap(Int.init) { snoozeMinutes = value }
        if let value = p["headsUpMinutes"].flatMap(Int.init) { headsUpMinutes = value }
        // The language last: it rebuilds every screen.
        if let value = p["language"].flatMap(Language.init(rawValue:)), value != language { language = value }
        Task { await resync(cancelActiveFor: replaced.union(medications.map(\.id))) }
        return true
    }

    /// "Mark made up" for a missed dose.
    func markMadeUp(_ id: UUID, missedAt scheduledAt: Date) {
        update(id) { $0.planner.markMadeUp(missedAt: scheduledAt, at: .now) }
    }

    /// Every change to one medication's settings, pills, pauses or taken times goes through here: save, then reschedule.
    /// `stopsAlarms`: also stop this medication's ringing or snoozed alarm, for example when pausing it.
    @discardableResult
    func update(_ id: UUID, stopsAlarms: Bool = false, _ change: (inout Medication) -> Void) -> Bool {
        guard loadStateIfNeeded(), let i = medications.firstIndex(where: { $0.id == id }) else { return false }
        var updated = medications
        change(&updated[i])
        if updated[i] == medications[i] { return true }
        guard saveMedications(updated) else { return false }
        Task { await resync(cancelActiveFor: stopsAlarms ? [id] : []) }
        return true
    }

    @discardableResult
    func add(_ medication: Medication) -> Bool {
        guard loadStateIfNeeded() || storageState == .recoveryCopySaved, medications.count < Medication.limit else { return false }
        let updated = medications + migratedMedications([medication], now: .now)
        guard saveMedications(updated) else { return false }
        Task { await resync() }
        return true
    }

    func delete(_ id: UUID) -> Bool {
        guard loadStateIfNeeded(), saveMedications(medications.filter { $0.id != id }) else { return false }
        Task { await resync(cancelActiveFor: [id]) }
        return true
    }

    private func loadStateIfNeeded() -> Bool {
        guard storageState == .pending else { return storageState == .loaded }
        do {
            let saved = try store.load()
            let migrated = migratedMedications(saved, now: .now)
            if migrated != saved { return saveMedications(migrated) }
            medications = saved
            storageState = .loaded
            dataIssue = nil
            return true
        } catch {
            // A temporarily unreadable file must never be treated as empty or replaced.
            let corrupt = error is DecodingError || (error as? CocoaError)?.code == .fileReadCorruptFile
            if corrupt {
                let directory = URL.applicationSupportDirectory
                let backup = directory.appending(path: "state-corrupt-\(UUID().uuidString).json")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: store.url, to: backup)
                    storageState = .recoveryCopySaved
                    dataIssue = L("Không đọc được dữ liệu cũ, đã sao lưu vào \(backup.lastPathComponent).",
                                  "Could not read old data. A copy was saved as \(backup.lastPathComponent).")
                    return false
                } catch {
                    dataIssue = L("Không sao lưu được dữ liệu cũ: \(error.localizedDescription)",
                                  "Could not preserve old data: \(error.localizedDescription)")
                    return false
                }
            }
            dataIssue = L("Chưa đọc được dữ liệu thuốc. Mở lại app khi đã mở khoá máy.",
                          "Could not read your medication data. Reopen the app after unlocking your phone.")
            return false
        }
    }

    private func migratedMedications(_ medications: [Medication], now: Date) -> [Medication] {
        medications.map { existing in
            var medication = existing
            if medication.name.isEmpty { medication.name = L("Thuốc hằng ngày", "Daily pill") }
            // Older medications without takes have no start date. Start tracking from this visit.
            if medication.settings.scheduleSince == nil, medication.history.isEmpty, !medication.settings.asNeeded {
                medication.settings.scheduleSince = now
            }
            return medication
        }
    }

    /// Commit to disk before publishing changes or changing the schedule.
    private func saveMedications(_ updated: [Medication]) -> Bool {
        do {
            try store.save(updated)
            medications = updated
            storageState = .loaded
            dataIssue = nil
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            dataIssue = L("Không lưu được dữ liệu: \(error.localizedDescription)", "Could not save your data: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Rescheduling

    // MARK: Background refresh

    nonisolated static let refreshTask = "io.github.finnwasabi.nersdaily.refresh"

    /// Notification permission, for Diagnostics. Asked once at onboarding before 0.5.6, and never again after a dismissed prompt.
    private(set) var notificationStatus: UNAuthorizationStatus?

    /// On every launch: asks for notifications when never asked, so a skipped prompt gets a second chance. Not while
    /// onboarding is due (it asks for alarms and notifications itself) or in screenshot launches.
    func checkNotifications(onboarding: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, onboarding || AlarmManager.shared.authorizationState != .notDetermined,
           UserDefaults.standard.string(forKey: "screen") == nil {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        notificationStatus = status
    }

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
    @ObservationIgnored private var lastApplied: (alerts: [PlannedAlert], snoozeMinutes: Int, language: Language, alarmsAvailable: Bool, notificationStatus: UNAuthorizationStatus?)?

    /// Reschedules all alarms and notifications, changing only what differs. Overlapping calls coalesce into one more pass
    /// after the running one. `cancelActiveFor`: also stop alarms of these medications that are ringing or snoozed (after a dose is taken).
    func resync(cancelActiveFor ids: Set<UUID> = []) async {
        guard loadStateIfNeeded() else { return }
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
            let snoozeMinutes = self.snoozeMinutes
            let language = self.language
            let alarmsAvailable = AlarmManager.shared.authorizationState == .authorized
            let notificationStatus = self.notificationStatus
            let alerts = AlertPlanner.alerts(
                for: medications.map { MedicationReminders($0, now: now, language: language, cadence: TimeInterval(snoozeMinutes * 60)) },
                vibrateOnly: vibrateOnly,
                alarmsAvailable: alarmsAvailable,
                language: language,
                headsUp: TimeInterval(headsUpMinutes * 60),
                now: now
            )
            // Opening the app with nothing due in between plans the same alerts: skip reading back every alarm and notification.
            if cancel.isEmpty, let lastApplied, lastApplied.alerts == alerts, lastApplied.snoozeMinutes == snoozeMinutes, lastApplied.language == language,
               lastApplied.alarmsAvailable == alarmsAvailable, lastApplied.notificationStatus == notificationStatus,
               var report = scheduleReport {
                report.result.changed = 0
                report.at = now
                report.duration = ContinuousClock.now - started
                scheduleReport = report
                continue
            }
            let result = await scheduler.apply(alerts, cancelActiveFor: cancel, snooze: TimeInterval(snoozeMinutes * 60), language: language)
            scheduleReport = ScheduleReport(result: result, at: now, duration: ContinuousClock.now - started)
            lastApplied = result.failures == 0 ? (alerts, snoozeMinutes, language, alarmsAvailable, notificationStatus) : nil
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
