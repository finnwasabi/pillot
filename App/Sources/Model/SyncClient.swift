import Foundation
import PillotCore
import Security

/// A connection code shaped `https://host/path#token`, sent by the bot's /link command.
struct SyncConnection: Equatable {
    var endpoint: URL
    var token: String

    init?(code: String) {
        guard let url = URL(string: code.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let token = url.fragment, !token.isEmpty,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        parts.fragment = nil
        guard let base = parts.url else { return nil }
        endpoint = base.appending(path: "v1/snapshot")
        self.token = token
    }
}

/// Sends the latest snapshot to the server. Offline is fine: the next sync sends the newest one (the server drops older ones).
nonisolated struct SyncClient: Sendable {
    struct Reply: Decodable {
        var stale: Bool
        var message: String?
    }

    enum Failure: Error, LocalizedError {
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .status(401): L("Mã kết nối sai, xin mã mới bằng lệnh /link.", "Wrong connection code, get a new one with /link.")
            case .status(let code): L("Server trả lỗi \(code).", "Server error \(code).")
            }
        }
    }

    func send(_ snapshot: Snapshot, to connection: SyncConnection) async throws -> Reply {
        var request = URLRequest(url: connection.endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try snapshot.jsonData()
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.status(status) }
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}

/// The connection code contains a token, so it lives in the Keychain, readable on this device only.
nonisolated enum ConnectionKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.github.finnwasabi.nersdaily.sync"]
    }

    static func load() -> String? {
        var result: AnyObject?
        var lookup = query
        lookup[kSecReturnData as String] = true
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ code: String?) throws {
        guard let code else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let data = [kSecValueData as String: Data(code.utf8)]
        let status = SecItemUpdate(query as CFDictionary, data as CFDictionary)
        guard status == errSecItemNotFound else { return try check(status) }
        var item = query.merging(data) { _, value in value }
        // Readable after first unlock, so background App Intents can still sync while the phone is locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(SecItemAdd(item as CFDictionary, nil))
    }

    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
