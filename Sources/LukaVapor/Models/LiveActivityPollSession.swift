import Foundation
import Dexcom
@preconcurrency import Redis

/// One entry per Live Activity in a poll session.
struct LiveActivityTokenEntry: Codable, Sendable {
    // The current push token for this activity. Push tokens rotate over an activity's
    // lifetime, so this is updated in place (keyed by `activityID`) rather than treated
    // as the activity's identity.
    let pushToken: LiveActivityPushToken
    let environment: PushEnvironment
    let preferences: LiveActivityPreferences?
    // When the activity started. Preserved across push-token rotations (matched by
    // `activityID`) so the activity expires relative to its real start, not the last
    // token refresh.
    let startDate: Date
    let duration: TimeInterval
    // Optional — older entries in Redis (and clients that don't send X-Luka-Build) won't have it.
    let clientBuild: Int?
    // Stable per-activity identity (ActivityKit's `Activity.id`). Optional for backwards
    // compatibility with entries already in Redis and older clients that don't send it;
    // when absent, the entry falls back to push-token matching and session-based expiry.
    let activityID: String?

    // Push-to-start: when present, the activity is auto-restarted on this same device when
    // it reaches its max duration (dismiss old, start new). Stored alongside the push token
    // because the scheduler only has the persisted session at expiry time — there is no
    // request context then. Bounded by the session's backstop TTL like everything else.
    // All optional: only set when the client opts into the experiment.
    let pushToStartToken: String?
    let attributesType: String?
    let attributes: JSONValue?
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

    // Set when a rate limit (HTTP 429) is hit. Acts as a minimum poll spacing while
    // easing back into normal polling, decaying toward minInterval on each healthy
    // poll. Optional for backwards compatibility with sessions already in Redis.
    var recoveryInterval: TimeInterval?
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

struct SessionEncodingError: Error {}

/// Redis key helpers for the new poll-session namespace.
enum LiveActivityPollKeys {
    static let scheduleKey = RedisKey("live-activities:poll-schedule")

    /// Backstop TTL for a session's data hash. A session can't legitimately live longer
    /// than its tokens' max activity duration (currently 7h, ended by 7.5h), so 8h
    /// comfortably exceeds any active session while ensuring a leaked/orphaned hash —
    /// one the scheduler has stopped polling — self-expires instead of lingering forever
    /// and inflating Redis usage. Refreshed on every save, so an actively-polled session
    /// never expires out from under us.
    static let dataTTLSeconds = 8 * 60 * 60

    static func dataKey(for username: String) -> RedisKey {
        RedisKey("live-activities:poll:\(username)")
    }

    /// Writes the session's data hash and (re)applies the backstop TTL. All writers go
    /// through here so no path can create a hash without an expiry.
    static func saveSession(_ session: LiveActivityPollSession, on client: any RedisClient) async throws {
        let key = dataKey(for: session.username)
        let jsonData = try JSONEncoder().encode(session)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw SessionEncodingError()
        }
        _ = try await client.hset("data", to: jsonString, in: key).get()
        _ = try await client.send(command: "EXPIRE", with: [
            RESPValue(from: key.rawValue),
            RESPValue(from: String(dataTTLSeconds)),
        ]).get()
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
