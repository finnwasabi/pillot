import AppIntents
import Foundation

/// "Taken" on the widget. A `LiveActivityIntent` runs in the app's process even when the widget's button
/// starts it, so it can save and reschedule the alarms. The widget target compiles it only to reference it (`WIDGET`).
struct MarkTakenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Taken"
    static let isDiscoverable = false

    /// One medication, stored under the same parameter name as existing widget buttons.
    @Parameter(title: "Medications")
    var medications: String

    @Parameter(title: "Dose time")
    var dueAt: Date?

    init() { medications = "" }

    init(id: UUID, dueAt: Date) {
        medications = id.uuidString
        self.dueAt = dueAt
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET
        if let id = UUID(uuidString: medications), let dueAt {
            await AppModel.shared.markTaken(dosesDueAt: [id: dueAt])
        }
        #endif
        return .result()
    }
}
