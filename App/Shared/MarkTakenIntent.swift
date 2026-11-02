import AppIntents
import Foundation

/// "Taken" on the widget. A `LiveActivityIntent` runs in the app's process even when the widget's button
/// starts it, so it can save and reschedule the alarms. The widget target compiles it only to reference it (`WIDGET`).
struct MarkTakenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Taken"
    static let isDiscoverable = false

    /// Medication ids separated by commas. Empty for alarms from before medications existed.
    @Parameter(title: "Medications")
    var medications: String

    init() { medications = "" }

    init(ids: [UUID]) { medications = ids.map(\.uuidString).joined(separator: ",") }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await AppModel.shared.markTaken(medications.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        #endif
        return .result()
    }
}
