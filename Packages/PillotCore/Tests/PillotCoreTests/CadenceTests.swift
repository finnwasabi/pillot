import Foundation
import Testing
@testable import PillotCore

/// The pending dose rings every `cadence` (the snooze length) until it is taken, as the iPhone Clock does after Snooze.
@Suite struct CadenceTests {
    /// Dose due 21:00 on the 28th with the deadline at 23:00, after a take at 21:00 the day before.
    func planner() -> Planner {
        var planner = Planner(settings: ReminderSettings(maxInterval: 26 * hour))
        planner.markTaken(at: vn(2026, 10, 27, 21))
        return planner
    }

    let now = vn(2026, 10, 28, 20)
    let due = vn(2026, 10, 28, 21)
    let deadline = vn(2026, 10, 28, 23)

    @Test(arguments: [5, 9, 15]) func ringsEveryCadenceUntilTheBurstEnds(minutes: Int) {
        let step = TimeInterval(minutes) * minute
        let dates = planner().events(now: now, horizonDays: 1, cadence: step).map(\.date)
        let ringing = dates.filter { $0 >= due && $0 <= deadline.addingTimeInterval(3 * hour) }
        #expect(ringing.first == due)
        for (a, b) in zip(ringing, ringing.dropFirst()) {
            #expect(b.timeIntervalSince(a) <= step, "gap \(a) to \(b)")
        }
        #expect(ringing.last! >= deadline.addingTimeInterval(3 * hour - step))
    }

    @Test func afterTheBurstItIsHourlyUntilTheDoseIsMissed() {
        let events = planner().events(now: now, horizonDays: 1, cadence: 9 * minute)
        let dose = planner().currentDose(now: now)
        let late = events.map(\.date).filter { $0 >= deadline.addingTimeInterval(3 * hour) && $0 <= dose.lateUntil }
        for (a, b) in zip(late, late.dropFirst()) {
            #expect(b.timeIntervalSince(a) <= hour)
        }
        #expect(events.last { $0.date <= dose.lateUntil }!.date > dose.lateUntil.addingTimeInterval(-hour))
        #expect(events.filter { $0.kind == .overdue }.allSatisfy { $0.requiresSound })
    }

    @Test func noCadenceKeepsTheSettingsSpacing() {
        #expect(planner().events(now: now, horizonDays: 1) == planner().events(now: now, horizonDays: 1, cadence: nil))
        let repeats = planner().events(now: now, horizonDays: 1).filter { $0.kind == .repeat }.map(\.date)
        #expect(repeats == [5, 10, 15].map { due.addingTimeInterval(TimeInterval($0) * minute) })
    }

    @Test func cadenceDoesNotMoveTheDeadline() {
        let events = planner().events(now: now, horizonDays: 1, cadence: 9 * minute)
        #expect(events.first { $0.kind == .deadline }?.date == deadline)
        #expect(events.allSatisfy { $0.deadlineAt == deadline })
    }

    /// Nine-minute rings must not push the later days out of the 300-alarm budget.
    @Test func fourMedicationsStillReachFiveDays() {
        let meds = [1, 2, 3, 6].enumerated().map { i, n in
            Medication(name: "M\(i)", settings: ReminderSettings(mainHour: 7 + i, dosesPerDay: n, maxInterval: 24 * hour / TimeInterval(n)))
        }
        let start = vn(2026, 10, 1, 5)
        let alerts = AlertPlanner.alerts(for: meds.map { MedicationReminders($0, now: start, language: .en, cadence: 9 * minute) }, vibrateOnly: false)
        #expect(alerts.count <= AlertPlanner.alarmLimit)
        #expect(alerts.last!.date.timeIntervalSince(start) >= 5 * 24 * hour)
    }
}
