import Foundation
import Dexcom

/// Stored in Redis as JSON for live activity state persistence.
/// All optional fields support backwards-compatible additions.
struct LiveActivityData: Codable, Sendable {
    // Identity (immutable per session)
    let id: String
    let pushToken: LiveActivityPushToken
    let environment: PushEnvironment
    let accountLocation: AccountLocation
    let duration: TimeInterval

    // Credentials (may be updated if session refreshes)
    var username: String?
    var password: String?
    var accountID: UUID?
    var sessionID: UUID?

    // Preferences (immutable per session)
    let preferences: LiveActivityPreferences?

    // Session timing
    let startDate: Date

    // Polling state (mutable)
    var lastReadingDate: Date?
    var lastReading: GlucoseReading?
    var pollInterval: TimeInterval
    var retryCount: Int

    /// Creates an activity ID from username or push token
    static func makeID(username: String?, pushToken: LiveActivityPushToken) -> String {
        username ?? pushToken.rawValue
    }
}

extension LiveActivityData {
    var logID: String {
        if let username {
            let parts = username.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return String(username.prefix(4)) }

            let local = parts[0]
            let domain = parts[1]

            guard let firstChar = local.first else { return String(username.prefix(4)) }

            let redactionCount = max(local.count - 1, 0)
            let redaction = String(repeating: "•", count: redactionCount)

            return "\(firstChar)\(redaction)@\(domain)"
        } else if let accountID {
            return String(accountID.uuidString.prefix(8))
        } else {
            return "n/a"
        }
    }
}
