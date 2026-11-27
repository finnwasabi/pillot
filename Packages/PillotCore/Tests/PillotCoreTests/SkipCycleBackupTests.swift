import Foundation
import Testing
@testable import PillotCore

@Suite struct SkipTests {
    @Test func skippingIsNotAMissAndStartsFreshAtTheNextDose() {
        var planner = Planner()
        planner.addPills(10, now: vn(2026, 10, 1, 8))
        planner.markTaken(at: vn(2026, 10, 1, 21))
        planner.skip(at: vn(2026, 10, 2, 21, 30))
        let now = vn(2026, 10, 3, 12)
        #expect(planner.missedCount(now: now) == 0)
        #expect(planner.skippedCount(now: now) == 1)
        #expect(planner.settings.pills?.remaining == 9)
        let dose = planner.currentDose(now: now)
        #expect(dose.dueAt == vn(2026, 10, 3, 21))
        #expect(dose.deadlineAt == vn(2026, 10, 3, 21))
        #expect(planner.timeline(now: now).last?.status == .skipped)
        #expect(planner.dayStatuses(now: now)[VietnamClock.calendar.startOfDay(for: vn(2026, 10, 2, 12))] == .skipped)
    }

    @Test func skippingAheadSkipsTheUpcomingDose() {
        var planner = Planner()
        planner.markTaken(at: vn(2026, 10, 1, 21))
        planner.skip(at: vn(2026, 10, 2, 18))
        #expect(planner.currentDose(now: vn(2026, 10, 2, 18, 1)).dueAt == vn(2026, 10, 3, 21))
        // Nothing rings for the skipped evening.
        #expect(!planner.events(now: vn(2026, 10, 2, 18, 1)).contains { $0.date < vn(2026, 10, 3, 21) })
    }

    @Test func aSkipBeforeAnyTakeWorks() {
        var planner = Planner()
        planner.skip(at: vn(2026, 10, 1, 20))
        #expect(planner.currentDose(now: vn(2026, 10, 1, 20, 1)).dueAt == vn(2026, 10, 2, 21))
        planner.markTaken(at: vn(2026, 10, 2, 21, 5))
        #expect(planner.lateCount(now: vn(2026, 10, 2, 22)) == 0)
        #expect(planner.currentDose(now: vn(2026, 10, 2, 22)).dueAt == vn(2026, 10, 3, 21))
    }

    @Test func undoingASkipBringsTheDoseBack() {
        var planner = Planner()
        planner.markTaken(at: vn(2026, 10, 1, 21))
        let skip = planner.skip(at: vn(2026, 10, 2, 21, 1))
        #expect(planner.undoableSkip(now: vn(2026, 10, 2, 21, 5))?.id == skip.id)
        #expect(planner.undoableSkip(now: vn(2026, 10, 2, 21, 20)) == nil)
        planner.removeRecord(id: skip.id)
        #expect(planner.currentDose(now: vn(2026, 10, 2, 21, 5)).dueAt == vn(2026, 10, 2, 21))
    }

    @Test func skipWithSeveralDosesADay() {
        var planner = Planner(settings: ReminderSettings(mainHour: 8, dosesPerDay: 4, maxInterval: 6 * hour))
        planner.markTaken(at: vn(2026, 10, 1, 8))
        // The 14:00 dose is skipped late, at 15:00: the next one is 20:00, not an overdue 14:00.
        planner.skip(at: vn(2026, 10, 1, 15))
        #expect(planner.currentDose(now: vn(2026, 10, 1, 15, 1)).dueAt == vn(2026, 10, 1, 20))
    }
}

@Suite struct CycleTests {
    /// 21 days on from 1/10, then 7 off (22/10 to 28/10), on again from 29/10.
    private func planner() -> Planner {
        Planner(settings: ReminderSettings(cycle: DoseCycle(activeDays: 21, breakDays: 7, startDay: vn(2026, 10, 1, 12))))
    }

    @Test func daysOffFollowTheCycle() {
        let cycle = DoseCycle(activeDays: 21, breakDays: 7, startDay: vn(2026, 10, 1, 12))
        #expect(!cycle.isBreak(vn(2026, 10, 21, 23)))
        #expect(cycle.isBreak(vn(2026, 10, 22, 0)))
        #expect(cycle.isBreak(vn(2026, 10, 28, 23, 59)))
        #expect(!cycle.isBreak(vn(2026, 10, 29, 0)))
        #expect(cycle.isBreak(vn(2026, 11, 19, 12)))
        #expect(!cycle.isBreak(vn(2026, 9, 30, 12)))
        #expect(cycle.breakEnd(after: vn(2026, 10, 25, 9)) == vn(2026, 10, 29, 0))
    }

    @Test func resumesAtMidnightWhenItIsTheFirstDoseAfterTheBreak() {
        let cycle = DoseCycle(activeDays: 1, breakDays: 30, startDay: vn(2026, 10, 1, 0))
        let planner = Planner(settings: ReminderSettings(mainHour: 0, dosesPerDay: 6, cycle: cycle))
        #expect(planner.nextReminder(now: vn(2026, 10, 2, 12)) == vn(2026, 11, 1, 0))
    }

    @Test func noRemindersAndNoMissesOnDaysOff() {
        var planner = planner()
        for day in 1...21 { planner.markTaken(at: vn(2026, 10, day, 21)) }
        let dose = planner.currentDose(now: vn(2026, 10, 21, 21, 5))
        #expect(dose.dueAt == vn(2026, 10, 29, 21))
        #expect(dose.deadlineAt == vn(2026, 10, 29, 21))
        let events = planner.events(now: vn(2026, 10, 21, 21, 5))
        #expect(events.first?.date == vn(2026, 10, 29, 21))
        #expect(planner.missedCount(now: vn(2026, 10, 29, 12)) == 0)
        #expect(planner.cycleBreakUntil(now: vn(2026, 10, 25, 12)) == vn(2026, 10, 29, 0))
        #expect(planner.dayStatuses(now: vn(2026, 10, 29, 12))[VietnamClock.calendar.startOfDay(for: vn(2026, 10, 24, 12))] == .paused)
    }

    @Test func aMissOnTheLastDayOnStillCountsAndThenWaits() {
        var planner = planner()
        for day in 1...20 { planner.markTaken(at: vn(2026, 10, day, 21)) }
        #expect(planner.missedCount(now: vn(2026, 10, 22, 10)) == 1)
        #expect(planner.currentDose(now: vn(2026, 10, 22, 10)).dueAt == vn(2026, 10, 29, 21))
    }

    @Test func snapshotReportsTheBreakAsResting() {
        var medication = Medication(name: "A", settings: planner().settings)
        medication.planner.markTaken(at: vn(2026, 10, 21, 21))
        #expect(medication.snapshot(now: vn(2026, 10, 23, 12)).pausedUntil == vn(2026, 10, 29, 0))
    }
}

@Suite struct BackupTests {
    @Test func roundTripKeepsEverything() throws {
        var a = Medication(name: "Vitamin D", color: 2, settings: ReminderSettings(mainHour: 8, dosesPerDay: 2, maxInterval: 12 * hour))
        a.planner.markTaken(at: vn(2026, 10, 1, 8))
        a.planner.skip(at: vn(2026, 10, 1, 19))
        a.settings.pills = PillCounter(count: 30, at: vn(2026, 10, 1, 8), packSize: 30)
        let backup = Backup(createdAt: vn(2026, 10, 30, 9), medications: [a], preferences: ["userName": "Mai", "snoozeMinutes": "9"])
        let read = try Backup.read(backup.data())
        #expect(read == backup)
        #expect(Backup.fileName(at: vn(2026, 10, 30, 1)) == "Pillot-backup-2026-10-30.json")
    }

    @Test func theAppDataFileRestoresToo() throws {
        let medication = Medication(name: "Iron")
        let read = try Backup.read(PlanStore.encode([medication]))
        #expect(read.medications == [medication])
        #expect(read.preferences.isEmpty)
    }

    @Test func backupsFromBeforeTheRenameRestore() throws {
        let old = #"{"format":"medly-backup","version":1,"createdAt":"2026-10-30T02:00:00Z","medications":[]}"#
        #expect(try Backup.read(Data(old.utf8)).createdAt == vn(2026, 10, 30, 9))
    }

    @Test func backupWithDuplicateMedicationIDsIsUnreadable() throws {
        let medication = Medication(name: "Iron")
        let file = try Backup(createdAt: vn(2026, 10, 30, 9), medications: [medication, medication]).data()
        #expect(throws: Backup.Failure.unreadable) { try Backup.read(file) }
    }

    @Test func backupsOverTheMedicationLimitAreRefused() throws {
        let medications = (0...Medication.limit).map { Medication(name: "Medication \($0)") }
        let file = try Backup(createdAt: vn(2026, 10, 30, 9), medications: medications).data()
        #expect(throws: Backup.Failure.unreadable) { try Backup.read(file) }
        let state = try PlanStore.encode(medications)
        #expect(throws: Backup.Failure.unreadable) { try Backup.read(state) }
    }

    @Test func backupWithInvalidCycleLengthsIsUnreadable() throws {
        let file = #"{"format":"pillot-backup","version":1,"createdAt":"2026-10-30T02:00:00Z","medications":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","settings":{"cycle":{"activeDays":0,"breakDays":0,"startDay":0}}}]}"#
        #expect(throws: Backup.Failure.unreadable) { try Backup.read(Data(file.utf8)) }
    }

    @Test func junkAndNewerBackupsAreRefused() throws {
        #expect(throws: Backup.Failure.unreadable) { try Backup.read(Data("hello".utf8)) }
        let newer = #"{"format":"pillot-backup","version":9,"createdAt":"2026-10-30T02:00:00Z","medications":[]}"#
        #expect(throws: Backup.Failure.tooNew(9)) { try Backup.read(Data(newer.utf8)) }
        let newerShape = #"{"format":"pillot-backup","version":9,"payload":{}}"#
        #expect(throws: Backup.Failure.tooNew(9)) { try Backup.read(Data(newerShape.utf8)) }
        let unknownFormat = #"{"format":"foreign-backup","version":2,"medications":[]}"#
        #expect(throws: Backup.Failure.unreadable) { try Backup.read(Data(unknownFormat.utf8)) }
    }
}
