import Foundation
import Testing
@testable import PillotCore

@Suite struct AlertPlannerTests {
    /// Taken at 23:00, so the next dose has main time 21:00 and deadline 23:00, leaving room for the pre-deadline chain.
    let events: [ReminderEvent] = {
        var planner = Planner()
        planner.markTaken(at: vn(2026, 10, 1, 23))
        return planner.events(now: vn(2026, 10, 1, 23, 1))
    }()

    /// More events than either budget holds, every third one a ringing deadline. One medication's real plan fits under
    /// the budgets since 0.3.6, so the limits are tested on this.
    let many: [ReminderEvent] = (0..<500).map { i in
        let date = vn(2026, 10, 2, 0).addingTimeInterval(TimeInterval(i) * 600)
        let deadline = i % 3 == 0
        return ReminderEvent(date: date, kind: deadline ? .deadline : .main, requiresSound: deadline, dueAt: date, deadlineAt: date)
    }

    @Test func soundModeUsesAlarmsForEverything() {
        let alerts = AlertPlanner.alerts(for: events, vibrateOnly: false, refillMessage: nil)
        #expect(alerts.count == events.count)
        #expect(alerts.allSatisfy { $0.usesAlarm })
        let capped = AlertPlanner.alerts(for: many, vibrateOnly: false, refillMessage: nil)
        #expect(capped.count == AlertPlanner.alarmLimit)
        #expect(capped.map(\.date) == Array(many.map(\.date).prefix(AlertPlanner.alarmLimit)))
        #expect(alerts.first?.title == "Tới giờ uống thuốc")
        #expect(alerts.first?.date == vn(2026, 10, 2, 21))
    }

    @Test func vibrateOnlyKeepsEveryDeadlineAsAlarm() {
        let alerts = AlertPlanner.alerts(for: many, vibrateOnly: true, refillMessage: nil)
        let deadlines = many.filter(\.requiresSound).map(\.date)
        #expect(!deadlines.isEmpty)
        #expect(alerts.filter(\.usesAlarm).map(\.date) == Array(deadlines.prefix(AlertPlanner.alarmLimit)))
        #expect(alerts.filter { !$0.usesAlarm }.count == AlertPlanner.notificationLimit)
    }

    @Test func withoutAlarmPermissionEverythingIsNotification() {
        let alerts = AlertPlanner.alerts(for: events, vibrateOnly: false, alarmsAvailable: false, refillMessage: nil)
        #expect(alerts.allSatisfy { !$0.usesAlarm })
        #expect(alerts.first?.date == vn(2026, 10, 2, 21))
        #expect(AlertPlanner.alerts(for: many, vibrateOnly: false, alarmsAvailable: false, refillMessage: nil).count == AlertPlanner.notificationLimit)
    }

    @Test func refillLineIsAppended() {
        let alerts = AlertPlanner.alerts(for: events, vibrateOnly: false, refillMessage: "còn 5 viên, nhớ mua thêm")
        #expect(alerts.first?.title == "Tới giờ uống thuốc. Còn 5 viên, nhớ mua thêm")
        #expect(alerts.first?.body == "Hạn chót 23:00 giờ VN.")
    }

    @Test func groupedAlertIdentifiesEachDoseAndRefreshesWhenOneMoves() throws {
        let at = vn(2026, 10, 2, 21)
        let a = MedicationReminders(id: UUID(), name: "A", events: [
            ReminderEvent(date: at, kind: .deadline, requiresSound: true, dueAt: at, deadlineAt: at),
        ], refillMessage: nil, missedCount: 0)
        let earlier = at.addingTimeInterval(-hour)
        var b = MedicationReminders(id: UUID(), name: "B", events: [
            ReminderEvent(date: at, kind: .deadline, requiresSound: true, dueAt: earlier, deadlineAt: at),
        ], refillMessage: nil, missedCount: 0)
        let before = try #require(AlertPlanner.alerts(for: [a, b], vibrateOnly: false).first)
        #expect(before.dosesDueAt == [a.id: at, b.id: earlier])

        b.events[0].dueAt = earlier.addingTimeInterval(5 * minute)
        let after = try #require(AlertPlanner.alerts(for: [a, b], vibrateOnly: false).first)
        #expect(before.key(snoozeMinutes: 9, language: .vi) != after.key(snoozeMinutes: 9, language: .vi))
    }
}

@Suite struct EnglishTextTests {
    @Test func everyAlertKindHasBothLanguages() {
        let kinds: [ReminderKind] = [.main, .repeat, .hourly, .final, .deadline, .overdue]
        for kind in kinds {
            let vi = AlertPlanner.title(for: kind, language: .vi)
            let en = AlertPlanner.title(for: kind, language: .en)
            #expect(!vi.isEmpty && !en.isEmpty && vi != en)
        }
    }

    @Test func englishAlertsAndMessages() {
        var planner = Planner()
        planner.markTaken(at: vn(2026, 10, 1, 23))
        let alerts = AlertPlanner.alerts(
            for: planner.events(now: vn(2026, 10, 1, 23, 1)), vibrateOnly: false,
            refillMessage: PillCounter(count: 1, at: vn(2026, 10, 1, 8)).refillMessage(RefillReminder(), language: .en),
            missedMessage: AlertPlanner.missedMessage(count: 2, language: .en), language: .en)
        #expect(alerts.first?.title == "Time to take your pill. 2 missed doses not made up. 1 pill left, time to buy more")
        #expect(alerts.first?.body == "Deadline 23:00 VN time.")
        #expect(TimeFormatting.vietnamTime(vn(2026, 10, 1, 21), language: .en) == "21:00 VN time")
    }
}
