import Foundation
import Testing
@testable import PillotCore

@Suite struct PlannerTests {
    let settings = ReminderSettings()

    @Test func firstDoseWithoutHistoryIsNextMainTime() {
        let planner = Planner(settings: settings)
        #expect(planner.nextReminder(now: vn(2026, 10, 27, 20)) == vn(2026, 10, 27, 21))
        #expect(planner.nextReminder(now: vn(2026, 10, 27, 21)) == vn(2026, 10, 28, 21))
        #expect(planner.missedCount(now: vn(2026, 11, 30, 12)) == 0)
    }

    @Test func takenOnTime() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 27, 21))
        let dose = planner.currentDose(now: vn(2026, 10, 27, 21, 1))
        #expect(dose.dueAt == vn(2026, 10, 28, 21))
        #expect(dose.deadlineAt == vn(2026, 10, 28, 21))
        let events = planner.events(now: vn(2026, 10, 27, 21, 1), horizonDays: 1)
        #expect(events.map(\.date) == [vn(2026, 10, 28, 21)])
        #expect(events.first?.kind == .deadline && events.first?.requiresSound == true)
    }

    @Test func takenFewMinutesLateKeepsMainTimeAndDeadline() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 27, 21, 2))
        let events = planner.events(now: vn(2026, 10, 27, 21, 3), horizonDays: 1)
        #expect(events.map(\.date) == [vn(2026, 10, 28, 21), vn(2026, 10, 28, 21, 2)])
        #expect(events.map(\.kind) == [.main, .deadline])
        #expect(events.map(\.requiresSound) == [false, true])
    }

    @Test func takenSixHoursEarlyPullsNextDoseEarly() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 27, 15))
        let now = vn(2026, 10, 27, 15, 1)
        let dose = planner.currentDose(now: now)
        #expect(dose.dueAt == vn(2026, 10, 28, 15))
        #expect(dose.deadlineAt == vn(2026, 10, 28, 15))

        let preview = planner.resetPreview(now: now)
        #expect(preview == ResetPreview(dueAt: vn(2026, 10, 28, 21), deadlineAt: vn(2026, 10, 28, 21), exceedsMaxInterval: true))
        planner.resetToMainTime(now: now)
        #expect(planner.nextReminder(now: now) == vn(2026, 10, 28, 21))
        #expect(planner.currentDose(now: now).exceedsMaxInterval)
        let sound = planner.events(now: now, horizonDays: 2).filter(\.requiresSound)
        #expect(sound.first?.date == vn(2026, 10, 28, 21))
    }

    @Test func resetWithoutPullDoesNotWarn() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 27, 21, 5))
        let preview = planner.resetPreview(now: vn(2026, 10, 27, 21, 6))
        #expect(preview?.exceedsMaxInterval == false)
        #expect(preview?.dueAt == vn(2026, 10, 28, 21))
        #expect(preview?.deadlineAt == vn(2026, 10, 28, 21, 5))
    }

    @Test func takenThreeHoursLateKeepsMainTimeAndFullChain() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 28, 0))
        let now = vn(2026, 10, 28, 0, 1)
        let dose = planner.currentDose(now: now)
        #expect(dose.dueAt == vn(2026, 10, 28, 21))
        #expect(dose.deadlineAt == vn(2026, 10, 29, 0))

        let events = planner.events(now: now, horizonDays: 1).filter { $0.deadlineAt == dose.deadlineAt }
        let expected: [(Date, ReminderKind)] = [
            (vn(2026, 10, 28, 21), .main),
            (vn(2026, 10, 28, 21, 5), .repeat), (vn(2026, 10, 28, 21, 10), .repeat), (vn(2026, 10, 28, 21, 15), .repeat),
            (vn(2026, 10, 28, 22), .final), (vn(2026, 10, 28, 22, 15), .final), (vn(2026, 10, 28, 22, 30), .final),
            (vn(2026, 10, 28, 22, 45), .final), (vn(2026, 10, 28, 23), .final), (vn(2026, 10, 28, 23, 15), .final),
            (vn(2026, 10, 28, 23, 30), .final), (vn(2026, 10, 28, 23, 45), .final),
            (vn(2026, 10, 29, 0), .deadline),
        ]
        #expect(events.map(\.date) == expected.map(\.0))
        #expect(events.map(\.kind) == expected.map(\.1))
    }

    @Test func hourlyRemindersWithLongerMaxInterval() {
        var planner = Planner(settings: ReminderSettings(maxInterval: 30 * hour))
        planner.markTaken(at: vn(2026, 10, 27, 21))
        let events = planner.events(now: vn(2026, 10, 27, 21, 1), horizonDays: 2)
            .filter { $0.deadlineAt == vn(2026, 10, 29, 3) && $0.kind != .overdue }
        #expect(events.filter { $0.kind == .hourly }.map(\.date) == [vn(2026, 10, 28, 22, 15), vn(2026, 10, 28, 23, 15), vn(2026, 10, 29, 0, 15)])
        #expect(events.filter { $0.kind == .final }.count == 8)
        #expect(events.count == 16)
    }

    @Test func skippingOneDayCountsOneMiss() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 26, 21, 3))
        #expect(planner.missedCount(now: vn(2026, 10, 27, 21, 3)) == 0)
        // Past the deadline but within the 12 h late window: not missed yet, the pending dose is still the overdue one.
        #expect(planner.missedCount(now: vn(2026, 10, 27, 22)) == 0)
        #expect(planner.currentDose(now: vn(2026, 10, 27, 22)).deadlineAt == vn(2026, 10, 27, 21, 3))
        #expect(planner.missedCount(now: vn(2026, 10, 28, 9, 4)) == 1)
        let dose = planner.currentDose(now: vn(2026, 10, 28, 10))
        #expect(dose.dueAt == vn(2026, 10, 28, 21))
        #expect(dose.deadlineAt == vn(2026, 10, 28, 21, 3))
        #expect(planner.timeline(now: vn(2026, 10, 28, 10)).map(\.status) == [.taken, .missed])

        planner.markTaken(at: vn(2026, 10, 28, 21, 3))
        #expect(planner.missedCount(now: vn(2026, 10, 29, 22)) == 1)
        #expect(planner.missedCount(now: vn(2026, 10, 30, 10)) == 2)
    }

    @Test func takenAfterDeadlineCountsLateNotMissed() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 27, 21))
        planner.markTaken(at: vn(2026, 10, 28, 22, 30))
        let now = vn(2026, 10, 28, 22, 31)
        #expect(planner.missedCount(now: now) == 0)
        #expect(planner.lateCount(now: now) == 1)
        #expect(planner.timeline(now: now).map(\.status) == [.taken, .late])
        let dose = planner.currentDose(now: now)
        #expect(dose.dueAt == vn(2026, 10, 29, 21))
        #expect(dose.deadlineAt == vn(2026, 10, 29, 22, 30))
    }

    @Test func fewMinutesPastDeadlineIsStillOnTime() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 27, 21, 0))
        planner.markTaken(at: vn(2026, 10, 28, 21, 10))
        planner.markTaken(at: vn(2026, 10, 29, 21, 26))
        let now = vn(2026, 10, 29, 22)
        #expect(planner.timeline(now: now).map(\.status) == [.taken, .taken, .late])
        #expect(planner.lateCount(now: now) == 1)
    }

    @Test func overdueKeepsRingingWithSoundUntilLateWindowEnds() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 27, 21))
        let deadline = vn(2026, 10, 28, 21)
        let overdue = planner.events(now: vn(2026, 10, 27, 21, 1), horizonDays: 2)
            .filter { $0.deadlineAt == deadline && $0.date > deadline }
        // 3 times every 5 min, then every 15 min until 3 h (11 times), then hourly until 12 h after the deadline (9 times).
        #expect(overdue.count == 23)
        #expect(overdue.allSatisfy { $0.kind == .overdue && $0.requiresSound })
        #expect(overdue.prefix(4).map(\.date) == [vn(2026, 10, 28, 21, 5), vn(2026, 10, 28, 21, 10), vn(2026, 10, 28, 21, 15), vn(2026, 10, 28, 21, 30)])
        #expect(overdue.last?.date == vn(2026, 10, 29, 9))
        #expect(planner.currentDose(now: vn(2026, 10, 29, 8)).deadlineAt == deadline)
    }

    @Test func undoWithinWindowOnly() {
        var planner = Planner(settings: ReminderSettings(pills: PillCounter(count: 10, at: vn(2026, 10, 1, 8))))
        planner.markTaken(at: vn(2026, 10, 27, 21, 1))
        #expect(planner.settings.pills?.remaining == 9)
        let undone = planner.undoLastTaken(now: vn(2026, 10, 27, 21, 5))
        #expect(undone)
        #expect(planner.history.isEmpty)
        #expect(planner.settings.pills?.remaining == 10)
        #expect(planner.nextReminder(now: vn(2026, 10, 27, 21, 5)) == vn(2026, 10, 28, 21))

        planner.markTaken(at: vn(2026, 10, 27, 21, 1))
        let lateUndo = planner.undoLastTaken(now: vn(2026, 10, 27, 21, 12))
        #expect(!lateUndo)
        #expect(planner.history.count == 1)
        #expect(planner.settings.pills?.remaining == 9)
    }

    @Test func editTakenTimeRecomputes() {
        var planner = Planner(settings: settings)
        let record = planner.markTaken(at: vn(2026, 10, 27, 21))
        planner.editTakenTime(id: record.id, to: vn(2026, 10, 27, 18))
        #expect(planner.nextReminder(now: vn(2026, 10, 27, 22)) == vn(2026, 10, 28, 18))
    }

    @Test func eventsSortedUniqueAndWithinHorizon() {
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 27, 23, 40))
        let now = vn(2026, 10, 27, 23, 41)
        let events = planner.events(now: now)
        let dates = events.map(\.date)
        #expect(dates == dates.sorted())
        #expect(Set(dates).count == dates.count)
        #expect(dates.allSatisfy { $0 > now && $0 <= now.addingTimeInterval(14 * 24 * hour) })
        #expect(events.filter { $0.kind == .deadline }.count == 14)
    }
}

@Suite struct MidnightTests {
    @Test func mainTime2330() {
        var planner = Planner(settings: ReminderSettings(mainHour: 23, mainMinute: 30))
        #expect(planner.nextReminder(now: vn(2026, 10, 27, 23, 45)) == vn(2026, 10, 28, 23, 30))

        planner.markTaken(at: vn(2026, 10, 27, 23, 35))
        #expect(planner.currentDose(now: vn(2026, 10, 28, 1)) == planner.currentDose(now: vn(2026, 10, 27, 23, 36)))
        let dose = planner.currentDose(now: vn(2026, 10, 28, 1))
        #expect(dose.dueAt == vn(2026, 10, 28, 23, 30))
        #expect(dose.deadlineAt == vn(2026, 10, 28, 23, 35))

        // Taken late past midnight: still counts for the previous main time, and the next dose stays at 23:30.
        planner.markTaken(at: vn(2026, 10, 29, 0, 30))
        let late = planner.currentDose(now: vn(2026, 10, 29, 0, 31))
        #expect(late.dueAt == vn(2026, 10, 29, 23, 30))
        #expect(late.deadlineAt == vn(2026, 10, 30, 0, 30))
        #expect(planner.missedCount(now: vn(2026, 10, 29, 0, 31)) == 0)
        #expect(planner.lateCount(now: vn(2026, 10, 29, 0, 31)) == 1)
    }

    @Test func mainTime0015() {
        var planner = Planner(settings: ReminderSettings(mainHour: 0, mainMinute: 15))
        #expect(planner.nextReminder(now: vn(2026, 10, 27, 22)) == vn(2026, 10, 28, 0, 15))

        // Taken 25 min early, before midnight: belongs to the 00:15 main time of the next day.
        planner.markTaken(at: vn(2026, 10, 27, 23, 50))
        let early = planner.currentDose(now: vn(2026, 10, 27, 23, 51))
        #expect(early.slotAt == vn(2026, 10, 29, 0, 15))
        #expect(early.dueAt == vn(2026, 10, 28, 23, 50))

        var onTime = Planner(settings: ReminderSettings(mainHour: 0, mainMinute: 15))
        onTime.markTaken(at: vn(2026, 10, 28, 0, 20))
        #expect(onTime.nextReminder(now: vn(2026, 10, 28, 0, 21)) == vn(2026, 10, 29, 0, 15))
        #expect(onTime.currentDose(now: vn(2026, 10, 28, 0, 21)).deadlineAt == vn(2026, 10, 29, 0, 20))
    }
}

@Suite struct PauseTests {
    @Test func pauseThenResume() {
        var planner = Planner(settings: ReminderSettings())
        planner.markTaken(at: vn(2026, 10, 27, 21))
        planner.pause(days: 3, now: vn(2026, 10, 27, 22))
        #expect(planner.settings.pausedUntil(now: vn(2026, 10, 28, 9)) == vn(2026, 10, 30, 22))

        let events = planner.events(now: vn(2026, 10, 27, 22), horizonDays: 5)
        #expect(events.allSatisfy { $0.date >= vn(2026, 10, 30, 22) })
        #expect(events.first?.date == vn(2026, 10, 31, 21))
        #expect(planner.nextReminder(now: vn(2026, 10, 29, 12)) == vn(2026, 10, 31, 21))
        #expect(planner.missedCount(now: vn(2026, 10, 31, 12)) == 0)
        #expect(planner.timeline(now: vn(2026, 10, 31, 12)).map(\.status) == [.taken, .paused])

        // After the pause, an untaken dose counts as missed again.
        #expect(planner.missedCount(now: vn(2026, 10, 31, 22)) == 0)
        #expect(planner.missedCount(now: vn(2026, 11, 1, 10)) == 1)
    }

    @Test func resumeEarlyStartsFromMainTime() {
        var planner = Planner(settings: ReminderSettings())
        planner.markTaken(at: vn(2026, 10, 27, 15))
        planner.pause(days: 3, now: vn(2026, 10, 27, 16))
        planner.resume(now: vn(2026, 10, 29, 12))
        #expect(planner.settings.pausedUntil(now: vn(2026, 10, 29, 12)) == nil)
        #expect(planner.nextReminder(now: vn(2026, 10, 29, 12)) == vn(2026, 10, 29, 21))
        #expect(planner.missedCount(now: vn(2026, 10, 29, 12)) == 0)
        #expect(planner.snapshot(now: vn(2026, 10, 29, 12)).pausedUntil == nil)
    }

    @Test func takingDuringPauseStillCounts() {
        var planner = Planner(settings: ReminderSettings())
        planner.pause(days: 2, now: vn(2026, 10, 27, 8))
        planner.markTaken(at: vn(2026, 10, 27, 21))
        #expect(planner.daysTaken(now: vn(2026, 10, 28, 8)) == 1)
        #expect(planner.nextReminder(now: vn(2026, 10, 28, 8)) == vn(2026, 10, 29, 21))
        #expect(planner.events(now: vn(2026, 10, 28, 8), horizonDays: 2).first?.date == vn(2026, 10, 29, 21))
    }
}

@Suite struct MainTimeChangeTests {
    @Test func movingEarlierTakesEffectTomorrow() {
        var planner = Planner()
        planner.markTaken(at: vn(2026, 10, 27, 21))
        let now = vn(2026, 10, 27, 22)
        let preview = planner.previewMainTimeChange(hour: 8, minute: 0, now: now)
        #expect(preview.dueAt == vn(2026, 10, 28, 8))
        #expect(!preview.exceedsMaxInterval)
        planner.changeMainTime(hour: 8, minute: 0, now: now)
        #expect(planner.currentDose(now: now).dueAt == vn(2026, 10, 28, 8))
        #expect(planner.currentDose(now: now).deadlineAt == vn(2026, 10, 28, 21))
        // From then on it stays at 08:00.
        planner.markTaken(at: vn(2026, 10, 28, 8))
        #expect(planner.nextReminder(now: vn(2026, 10, 28, 9)) == vn(2026, 10, 29, 8))
    }

    @Test func movingLaterWarnsAboutTheMaximumGap() {
        var planner = Planner()
        planner.markTaken(at: vn(2026, 10, 27, 21))
        let now = vn(2026, 10, 27, 22)
        let preview = planner.previewMainTimeChange(hour: 23, minute: 0, now: now)
        #expect(preview.dueAt == vn(2026, 10, 28, 23))
        #expect(preview.exceedsMaxInterval)
        // Without realigning, the 24 h rule kept it at 21:00.
        var stuck = planner
        stuck.settings.mainHour = 23
        #expect(stuck.nextReminder(now: now) == vn(2026, 10, 28, 21))
    }

    @Test func changingWithoutHistoryOrWhileOverdueUsesTheNewTime() {
        var fresh = Planner()
        fresh.changeMainTime(hour: 7, minute: 30, now: vn(2026, 10, 27, 6))
        #expect(fresh.nextReminder(now: vn(2026, 10, 27, 6)) == vn(2026, 10, 27, 7, 30))

        var overdue = Planner()
        overdue.markTaken(at: vn(2026, 10, 25, 21))
        overdue.changeMainTime(hour: 9, minute: 0, now: vn(2026, 10, 28, 12))
        #expect(overdue.currentDose(now: vn(2026, 10, 28, 12)).slotAt >= vn(2026, 10, 28, 12).addingTimeInterval(-24 * hour))
        #expect(overdue.history.allSatisfy { !$0.nextAtMainTime })
    }

    @Test func backToMainTimeAfterAnEarlyDose() {
        var planner = Planner()
        planner.markTaken(at: vn(2026, 10, 27, 15))
        let now = vn(2026, 10, 27, 15, 1)
        #expect(planner.currentDose(now: now).dueAt == vn(2026, 10, 28, 15))
        let preview = planner.resetToMainTime(now: now)
        #expect(preview?.dueAt == vn(2026, 10, 28, 21))
        #expect(preview?.exceedsMaxInterval == true)
        #expect(planner.nextReminder(now: now) == vn(2026, 10, 28, 21))
    }
}
