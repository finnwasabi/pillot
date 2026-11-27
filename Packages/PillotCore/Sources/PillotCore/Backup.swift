import Foundation

/// A backup file the user saves wherever they like (Files, iCloud Drive, a chat) and restores from later.
/// It holds every medication with its history, plus the app's preferences as plain strings.
/// The connection code is left out on purpose: it is a secret and the bot's /link gives it again.
public struct Backup: Equatable, Sendable {
    public static let format = "pillot-backup"
    /// Formats this app has written before, still read on restore.
    static let readableFormats: Set<String> = [format, "medly-backup"]
    public static let currentVersion = 1

    public var createdAt: Date
    public var medications: [Medication]
    /// App preferences by key (names, language, theme, sound mode, snooze). Unknown keys are ignored on restore.
    public var preferences: [String: String]

    public init(createdAt: Date, medications: [Medication], preferences: [String: String] = [:]) {
        self.createdAt = createdAt
        self.medications = medications
        self.preferences = preferences
    }

    private struct File: Codable {
        var format: String
        var version: Int
        var createdAt: String
        var medications: [Medication]
        var preferences: [String: String]?
    }

    private struct Header: Decodable {
        var format: String?
        var version: Int
    }

    public enum Failure: Error, Equatable {
        /// Not a backup and not app data.
        case unreadable
        /// Made by a newer app version.
        case tooNew(Int)
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(format: Self.format, version: Self.currentVersion, createdAt: UTCTimestamp.string(from: createdAt),
                                       medications: medications, preferences: preferences))
    }

    /// Reads a backup file, or the app's own data file (`state.json`, version 1 or 2) as a fallback.
    public static func read(_ data: Data) throws -> Backup {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw Failure.unreadable }
        if let format = header.format {
            guard readableFormats.contains(format), header.version > 0 else { throw Failure.unreadable }
            guard header.version <= currentVersion else { throw Failure.tooNew(header.version) }
            guard let file = try? decoder.decode(File.self, from: data), PlanStore.isValidMedicationList(file.medications) else {
                throw Failure.unreadable
            }
            return Backup(createdAt: UTCTimestamp.date(from: file.createdAt) ?? .distantPast, medications: file.medications,
                          preferences: file.preferences ?? [:])
        }
        guard let medications = try? PlanStore.decode(data) else { throw Failure.unreadable }
        return Backup(createdAt: .distantPast, medications: medications)
    }

    /// A file name such as "Pillot-backup-2026-10-30.json", by the Vietnam date.
    public static func fileName(at date: Date) -> String {
        let p = VietnamClock.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "Pillot-backup-%04d-%02d-%02d.json", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
}
