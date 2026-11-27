import Foundation
import Testing
@testable import PillotCore

@Suite struct PlanStoreTests {
    /// A fresh temporary directory per test; the subdirectory does not exist yet, which also tests creating it.
    let store = PlanStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("PlanStoreTests-\(UUID().uuidString)")
        .appendingPathComponent("state.json"))

    private func reload() throws -> Planner { try #require(store.load().first).planner }
    private func save(_ planner: Planner) throws { try store.save([Medication(name: "Test", settings: planner.settings, history: planner.history)]) }

    @Test func missingFileGivesNoMedications() throws {
        #expect(try store.load().isEmpty)
    }

    @Test func versionOneBecomesOneUnnamedMedication() throws {
        var planner = Planner(settings: ReminderSettings(mainHour: 20, mainMinute: 30))
        planner.addPills(28, now: vn(2026, 10, 1, 8))
        planner.markTaken(at: vn(2026, 10, 1, 20, 31))
        struct V1: Encodable { var version = 1; var settings: ReminderSettings; var history: [DoseRecord] }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(V1(settings: planner.settings, history: planner.history)).write(to: store.url)

        let medications = try store.load()
        #expect(medications.count == 1)
        #expect(medications[0].name == "")
        #expect(medications[0].settings == planner.settings)
        #expect(medications[0].history == planner.history)
        #expect(medications[0].settings.dosesPerDay == 1)
    }

    @Test func severalMedicationsRoundTrip() throws {
        var a = Medication(name: "Vitamin D", color: 2, icon: "sun.max.fill", settings: ReminderSettings(mainHour: 8, dosesPerDay: 2))
        a.planner.markTaken(at: vn(2026, 10, 1, 8))
        let b = Medication(name: "Iron", settings: ReminderSettings(mainHour: 21))
        try store.save([a, b])
        #expect(try store.load() == [a, b])
    }

    @Test func duplicateMedicationIDsCannotBeLoaded() throws {
        let medication = Medication(name: "Iron")
        try store.save([medication, medication])
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func unknownVersionThrows() throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 9, "medications": []}"#.utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func saveThenLoadKeepsEverything() throws {
        var planner = Planner(settings: ReminderSettings(mainHour: 20, mainMinute: 30))
        planner.addPills(28, now: vn(2026, 10, 1, 8))
        planner.markTaken(at: vn(2026, 10, 1, 20, 31))
        planner.markTaken(at: vn(2026, 10, 2, 20, 45))
        planner.pause(days: 3, now: vn(2026, 10, 3, 9))
        try save(planner)

        let loaded = try reload()
        #expect(loaded.settings == planner.settings)
        #expect(loaded.history == planner.history)
        #expect(loaded.settings.pills?.remaining == 26)
    }

    @Test func editedTimeSurvivesReload() throws {
        var planner = Planner()
        let record = planner.markTaken(at: vn(2026, 10, 1, 21))
        try save(planner)

        var loaded = try reload()
        loaded.editTakenTime(id: record.id, to: vn(2026, 10, 1, 21, 40))
        try save(loaded)

        #expect(try reload().history.first?.takenAt == vn(2026, 10, 1, 21, 40))
    }

    @Test func undoneRecordStaysDeleted() throws {
        var planner = Planner()
        planner.addPills(10, now: vn(2026, 10, 1, 8))
        planner.markTaken(at: vn(2026, 10, 1, 21))
        try save(planner)

        var loaded = try reload()
        let undone = loaded.undoLastTaken(now: vn(2026, 10, 1, 21, 5))
        #expect(undone)
        try save(loaded)

        let again = try reload()
        #expect(again.history.isEmpty)
        #expect(again.settings.pills?.remaining == 10)
    }

    @Test func corruptFileThrowsInsteadOfWiping() throws {
        try save(Planner())
        try Data("không phải JSON".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try reload() }
    }
}
