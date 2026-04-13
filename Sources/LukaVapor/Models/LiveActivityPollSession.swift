import Foundation
import Dexcom
@preconcurrency import Redis

/// One entry per device/push token in a poll session.
struct LiveActivityTokenEntry: Codable, Sendable {
    let pushToken: LiveActivityPushToken
    let environment: PushEnvironment
    let preferences: LiveActivityPreferences?
    let startDate: Date
    let duration: TimeInterval
}

/// One per username — holds shared Dexcom polling state and all device tokens.
struct LiveActivityPollSession: Codable, Sendable {
    let username: String
    var password: String
    var accountID: UUID?
    var sessionID: UUID?
    let accountLocation: AccountLocation

    var tokens: [LiveActivityTokenEntry]

    // Shared polling state
    var lastReadingDate: Date?
    var lastReading: GlucoseReading?
    var readings: [GlucoseReading]?
    var pollInterval: TimeInterval
    var retryCount: Int
    var lastStaleUpdateMinutes: Int?
}

extension LiveActivityPollSession {
    var logID: String {
        let parts = username.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return String(username.prefix(4)) }

        let local = parts[0]
        let domain = parts[1]

        guard let firstChar = local.first else { return String(username.prefix(4)) }

        let redactionCount = max(local.count - 1, 0)
        let redaction = String(repeating: "•", count: redactionCount)

        return "\(firstChar)\(redaction)@\(domain)"
    }
}

/// Redis key helpers for the new poll-session namespace.
enum LiveActivityPollKeys {
    static let scheduleKey = RedisKey("live-activities:poll-schedule")

    static func dataKey(for username: String) -> RedisKey {
        RedisKey("live-activities:poll:\(username)")
    }
}
