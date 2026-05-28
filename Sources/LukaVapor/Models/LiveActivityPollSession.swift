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
    // Optional — older entries in Redis (and clients that don't send X-Luka-Build) won't have it.
    let clientBuild: Int?
}

/// One per username — holds shared Dexcom polling state and all device tokens.
struct LiveActivityPollSession: Codable, Sendable {
    let username: String
    var password: String
    var accountID: UUID?
    var sessionID: UUID?
    let accountLocation: AccountLocation

    var tokens: [LiveActivityTokenEntry]

    // Optional for backwards compatibility with sessions already in Redis.
    var sessionStartDate: Date?

    // Shared polling state
    var lastReadingDate: Date?
    var lastReading: GlucoseReading?
    var readings: [GlucoseReading]?
    var pollInterval: TimeInterval
    var retryCount: Int
    var lastStaleUpdateMinutes: Int?
}

extension LiveActivityPollSession {
    var logID: String { username.redactedEmailLogID }
}

extension String {
    /// Redacts an email for logging: "kyle@example.com" → "k•••@example.com"
    var redactedEmailLogID: String {
        let parts = split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return String(prefix(4)) }

        let local = parts[0]
        let domain = parts[1]

        guard let firstChar = local.first else { return String(prefix(4)) }

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

    /// Atomically removes the schedule entry and the data hash for a username.
    /// A two-call zrem+del leaves a window where a concurrent `start-live-activity`
    /// can read the still-existing data, then write it back after the delete fires —
    /// leaving an orphan data hash with no schedule entry that the scheduler never polls.
    static func removeSession(_ username: String, on client: any RedisClient) async throws {
        let script = """
        redis.call('ZREM', KEYS[1], ARGV[1])
        redis.call('DEL', KEYS[2])
        return 1
        """
        _ = try await client.send(command: "EVAL", with: [
            RESPValue(from: script),
            RESPValue(from: "2"),
            RESPValue(from: scheduleKey.rawValue),
            RESPValue(from: dataKey(for: username).rawValue),
            RESPValue(from: username),
        ]).get()
    }
}
