import Foundation
import Testing
@testable import PillotCore

/// The quiet notification some minutes before each dose time.
@Suite struct HeadsUpTests {
    let now = vn(2026, 10, 28, 20)

    func alerts(_ medication: Medication, headsUp: TimeInterval) -> [PlannedAlert] {
        AlertPlanner.alerts(for: [MedicationReminders(medication, now: now, language: .vi)], vibrateOnly: false, headsUp: headsUp)
    }

    /// With the default gap the dose time is also the deadline, so the first ring is a deadline event, and it still gets one.
    @Test func everyDoseTimeGetsOneQuietNotificationBefore() {
        var planner = Planner(settings: ReminderSettings())
        planner.markTaken(at: vn(2026, 10, 27, 21))
        let med = Medication(name: "Iron", settings: planner.settings, history: planner.history)
        let quiet = alerts(med, headsUp: 10 * minute).filter(\.quiet)
        #expect(quiet.first?.date == vn(2026, 10, 28, 20, 50))
        #expect(quiet.allSatisfy { !$0.usesAlarm && $0.title == "Còn 10 phút nữa" && $0.body.hasPrefix("Iron, uống lúc 21:00") })
        // One per day for a daily dose, never one per repeat ring.
        #expect(Set(quiet.map { VietnamClock.startOfDay($0.date) }).count == quiet.count)
        #expect(quiet.allSatisfy { $0.date.timeIntervalSince(vn(2026, 10, 28, 20, 50)).truncatingRemainder(dividingBy: VietnamClock.day) == 0 })
    }

    @Test func zeroTurnsItOff() {
        let med = Medication(name: "Iron", settings: ReminderSettings())
        #expect(alerts(med, headsUp: 0).allSatisfy { !$0.quiet })
        #expect(alerts(med, headsUp: 0) == AlertPlanner.alerts(for: [MedicationReminders(med, now: now, language: .vi)], vibrateOnly: false))
    }

    /// Heads-ups share the 64 pending notifications with everything else.
    @Test func staysWithinTheNotificationLimit() {
        let meds = (0..<4).map { Medication(name: "M\($0)", settings: ReminderSettings(mainHour: 6 + $0, dosesPerDay: 6, maxInterval: 4 * hour)) }
        let all = AlertPlanner.alerts(for: meds.map { MedicationReminders($0, now: now, language: .en) }, vibrateOnly: false, headsUp: 10 * minute)
        #expect(all.filter { !$0.usesAlarm }.count <= AlertPlanner.notificationLimit)
        #expect(all.map(\.date) == all.map(\.date).sorted())
    }
}
