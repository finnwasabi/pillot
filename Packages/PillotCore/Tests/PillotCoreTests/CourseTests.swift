import Foundation
import Testing
@testable import PillotCore

@Suite struct CourseTests {
    /// A month of daily doses, then twice a day: the frozen month stays taken, with no misses appearing in it.
    @Test func changingTheScheduleKeepsThePast() {
        var planner = Planner(settings: ReminderSettings(mainHour: 21))
        for day in 1...20 { planner.markTaken(at: vn(2026, 10, day, 21, 5)) }
        let change = vn(2026, 10, 21, 10)
        let before = planner.dayStatuses(now: change)
        var reread = planner
        reread.changeSchedule(hour: 9, minute: 0, dosesPerDay: 2, now: change)
        reread.settings.maxInterval = 12 * hour
        #expect(reread.missedCount(now: change) > 0, "without freezing the past is re-read under the new schedule")

        planner.freezeHistory(now: change)
        planner.changeSchedule(hour: 9, minute: 0, dosesPerDay: 2, now: change)
        planner.settings.maxInterval = 12 * hour
        #expect(planner.missedCount(now: change) == 0)
        #expect(planner.dayStatuses(now: change) == before)
        #expect(planner.timeline(now: change).count == 20)
        // The new schedule runs from the last take: its first dose time, 09:00, is already due.
        #expect(planner.currentDose(now: change).dueAt == vn(2026, 10, 21, 9))
    }

    @Test func deletingAFrozenTakeDropsItsDay() {
        var planner = Planner(settings: ReminderSettings(mainHour: 21))
        let first = planner.markTaken(at: vn(2026, 10, 1, 21))
        planner.markTaken(at: vn(2026, 10, 2, 21))
        planner.freezeHistory(now: vn(2026, 10, 3, 10))
        planner.removeRecord(id: first.id)
        let days = planner.dayStatuses(now: vn(2026, 10, 3, 10))
        #expect(days[vn(2026, 10, 1, 0)] == nil)
        #expect(days[vn(2026, 10, 2, 0)] == .taken)
    }

    @Test func changingCadenceDoesNotCreateEarlierMisses() {
        var planner = Planner(settings: ReminderSettings(mainHour: 21))
        planner.markTaken(at: vn(2026, 10, 1, 21))
        let changedAt = vn(2026, 10, 5, 10)
        let before = planner.timeline(now: changedAt)

        planner.freezeHistory(now: changedAt)
        planner.changeSchedule(hour: 9, minute: 0, dosesPerDay: 2, now: changedAt)

        #expect(planner.timeline(now: changedAt).map(\.id) == before.map(\.id))
        #expect(planner.currentDose(now: changedAt).dueAt == vn(2026, 10, 5, 9))
        #expect(planner.missedCount(now: vn(2026, 10, 5, 16)) == 4)
    }

    @Test func firstDoseStaysPendingThroughItsLateWindow() {
        var planner = Planner(settings: ReminderSettings(scheduleSince: vn(2026, 10, 1, 13)))
        let firstDose = vn(2026, 10, 1, 21)

        #expect(planner.events(now: vn(2026, 10, 1, 13)).first?.date == firstDose)
        #expect(planner.currentDose(now: vn(2026, 10, 1, 21, 1)).dueAt == firstDose)
        #expect(planner.currentDose(now: vn(2026, 10, 2, 8)).dueAt == firstDose)
        #expect(planner.timeline(now: vn(2026, 10, 2, 10)).first?.status == .missed)

        let take = planner.markTaken(at: vn(2026, 10, 1, 21, 30))
        #expect(take.scheduledAt == firstDose)
        #expect(planner.timeline(now: vn(2026, 10, 1, 22)).first?.status == .late)
    }

    @Test func twoPillsADose() {
        var settings = ReminderSettings(mainHour: 21, pills: PillCounter(count: 10, at: vn(2026, 10, 1, 0)))
        settings.pillsPerDose = 2
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 1, 21))
        #expect(planner.settings.pills?.remaining == 8)
        let undone = planner.undoLastTaken(now: vn(2026, 10, 1, 21, 2))
        #expect(undone)
        #expect(planner.settings.pills?.remaining == 10)
    }

    @Test func nothingRingsOrIsMissedAfterTheCourse() {
        var settings = ReminderSettings(mainHour: 21)
        settings.endDay = vn(2026, 10, 7, 0)
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 1, 21))
        let events = planner.events(now: vn(2026, 10, 5, 22))
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.date < vn(2026, 10, 8, 0) })
        planner.markTaken(at: vn(2026, 10, 7, 21))
        let later = vn(2026, 10, 20, 12)
        #expect(planner.settings.courseEnded(now: later))
        #expect(planner.events(now: later).isEmpty)
        #expect(planner.restingUntil(now: later) == .distantFuture)
        let missedAfter = planner.timeline(now: later).filter { $0.status == .missed && $0.scheduledAt >= vn(2026, 10, 8, 0) }
        #expect(missedAfter.isEmpty)
        #expect(planner.timeline(now: later).allSatisfy { $0.status != .paused })
    }

    @Test func courseKeepsTheFinalDoseUntilTheEndOfItsLastDay() {
        let lastDose = vn(2026, 10, 7, 21)
        let courseEnd = vn(2026, 10, 8, 0)
        var planner = Planner(settings: ReminderSettings(mainHour: 21, endDay: lastDose))
        planner.markTaken(at: vn(2026, 10, 6, 21))

        let events = planner.events(now: vn(2026, 10, 7, 20))
        #expect(events.contains { $0.date == lastDose && $0.requiresSound })
        #expect(events.contains { $0.date > lastDose })
        #expect(events.allSatisfy { $0.date < courseEnd })
        #expect(planner.currentDose(now: vn(2026, 10, 7, 22)).dueAt == lastDose)
        #expect(planner.missedCount(now: vn(2026, 10, 7, 22)) == 0)
        #expect(planner.timeline(now: courseEnd).filter { $0.status == .missed }.map(\.scheduledAt) == [lastDose])
        #expect(planner.events(now: courseEnd).isEmpty)
    }

    @Test func aLoggedFinalDoseFinishesTheCourseInTheSnapshot() {
        let final = vn(2026, 10, 7, 21)
        var medication = Medication(name: "Test", settings: ReminderSettings(mainHour: 21, endDay: final))
        medication.planner.markTaken(at: vn(2026, 10, 6, 21))
        #expect(!medication.snapshot(now: final).courseEnded)
        medication.planner.markTaken(at: final)
        let snapshot = medication.snapshot(now: vn(2026, 10, 7, 22))
        #expect(snapshot.courseEnded)
        #expect(snapshot.pausedUntil == nil)
    }

    @Test func switchingToAsNeededPreservesScheduledHistory() {
        var planner = Planner(settings: ReminderSettings(mainHour: 21))
        planner.markTaken(at: vn(2026, 10, 1, 21))
        planner.markTaken(at: vn(2026, 10, 2, 21, 30))
        planner.skip(at: vn(2026, 10, 4, 21))
        let changedAt = vn(2026, 10, 5, 15)
        let before = planner.timeline(now: changedAt)
        let previousDays = planner.dayStatuses(now: changedAt)

        planner.freezeHistory(now: changedAt)
        planner.settings.asNeeded = true
        let take = planner.markTaken(at: vn(2026, 10, 6, 3))
        let after = planner.summary(now: vn(2026, 10, 7, 10))

        #expect(after.timeline.map(\.id) == before.map(\.id) + [take.id])
        #expect(after.missedCount == 1)
        #expect(after.lateCount == 1)
        #expect(after.skippedCount == 1)
        var expectedDays = previousDays
        expectedDays[vn(2026, 10, 6, 0)] = .taken
        #expect(after.dayStatuses() == expectedDays)
        #expect(after.events().isEmpty)
    }

    @Test func asNeededHasNoScheduleAndNoMisses() {
        var settings = ReminderSettings()
        settings.asNeeded = true
        settings.minGap = 6 * hour
        var planner = Planner(settings: settings)
        planner.markTaken(at: vn(2026, 10, 1, 8))
        planner.markTaken(at: vn(2026, 10, 1, 15))
        let now = vn(2026, 10, 9, 12)
        #expect(planner.events(now: now).isEmpty)
        #expect(planner.missedCount(now: now) == 0)
        #expect(planner.takenToday(now: vn(2026, 10, 1, 16)) == 2)
        #expect(planner.nextAllowed(now: vn(2026, 10, 1, 16)) == vn(2026, 10, 1, 21))
        #expect(planner.timeline(now: now).count == 2)
    }

    @Test func asNeededIgnoresInactiveCoursePauseAndCycle() {
        let now = vn(2026, 10, 5, 3)
        let pauseEnd = vn(2026, 10, 6, 0)
        let pause = PausePeriod(start: vn(2026, 10, 4, 0), end: pauseEnd)
        let cycle = DoseCycle(activeDays: 1, breakDays: 7, startDay: vn(2026, 10, 1, 0))
        var medication = Medication(name: "Test", settings: ReminderSettings(
            pauses: [pause], cycle: cycle, endDay: vn(2026, 10, 2, 0), asNeeded: true))

        let take = medication.planner.markTaken(at: now)
        #expect(medication.planner.day(of: take) == vn(2026, 10, 5, 0))
        #expect(medication.settings.pausedUntil(now: now) == nil)
        #expect(medication.planner.cycleBreakUntil(now: now) == nil)
        #expect(medication.snapshot(now: now).pausedUntil == nil)
        #expect(!medication.snapshot(now: now).courseEnded)

        medication.settings.asNeeded = false
        #expect(medication.settings.courseEnded(now: now))
        #expect(medication.settings.pausedUntil(now: now) == pauseEnd)
        #expect(medication.planner.cycleBreakUntil(now: now) == vn(2026, 10, 9, 0))
    }
}
