import Foundation
import Dexcom
import Logging
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
    // Stable per-activity identity (ActivityKit's `Activity.id`). Used for matching across
    // push-token rotations and for per-activity expiry. Always present: clients are
    // force-updated to send it, and all pre-activityID entries have aged out of Redis.
    let activityID: String

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

/// Redis key helpers for the poll-session namespace.
///
/// A session lives in one hash per username, but its parts are stored in **separate fields**
/// so independent writers never clobber each other:
///   - `cred`            — credentials (written by `start-live-activity`)
///   - `state`           — Dexcom polling state (written only by the scheduler after creation)
///   - `tok:<activityID>`— one field per device's Live Activity token
///
/// The whole-session-blob layout that preceded this stored every device's token in a single
/// JSON value that all three writers (two devices + the scheduler) rewrote wholesale, so two
/// near-simultaneous registrations raced and one device's token was silently dropped. With
/// per-field storage, registering a device is a single `HSET tok:<id>`, ending one is an
/// `HDEL tok:<id>`, and the scheduler never rewrites token fields — so a device that
/// registers mid-poll can't be overwritten.
enum LiveActivityPollKeys {
    static let scheduleKey = RedisKey("live-activities:poll-schedule")

    /// Backstop TTL for a session's hash. A session can't legitimately live longer than its
    /// tokens' max activity duration (currently 7h, ended by 7.5h), so 8h comfortably exceeds
    /// any active session while ensuring a leaked/orphaned hash — one the scheduler has
    /// stopped polling — self-expires instead of lingering forever and inflating Redis usage.
    /// Refreshed on every write, so an actively-polled session never expires out from under us.
    static let dataTTLSeconds = 8 * 60 * 60

    static let credField = "cred"
    static let stateField = "state"
    static let legacyField = "data"
    static let tokenFieldPrefix = "tok:"
    static let dataKeyPrefix = "live-activities:poll:"

    static func dataKey(for username: String) -> RedisKey {
        RedisKey("\(dataKeyPrefix)\(username)")
    }

    static func tokenField(_ activityID: String) -> String { tokenFieldPrefix + activityID }

    /// Route-owned credentials.
    struct Cred: Codable {
        var password: String
        var accountLocation: AccountLocation
    }

    /// Scheduler-owned polling state. The scheduler is the sole writer after a session is
    /// created, so this needs no concurrency guard of its own.
    struct State: Codable {
        var accountID: UUID?
        var sessionID: UUID?
        var sessionStartDate: Date?
        var lastReadingDate: Date?
        var lastReading: GlucoseReading?
        var readings: [GlucoseReading]?
        var pollInterval: TimeInterval
        var retryCount: Int
        var lastStaleUpdateMinutes: Int?
        var recoveryInterval: TimeInterval?

        init(from session: LiveActivityPollSession) {
            accountID = session.accountID
            sessionID = session.sessionID
            sessionStartDate = session.sessionStartDate
            lastReadingDate = session.lastReadingDate
            lastReading = session.lastReading
            readings = session.readings
            pollInterval = session.pollInterval
            retryCount = session.retryCount
            lastStaleUpdateMinutes = session.lastStaleUpdateMinutes
            recoveryInterval = session.recoveryInterval
        }
    }

    enum LoadedSession {
        case present(LiveActivityPollSession)
        case missing
        case undecodable
    }

    private static func refreshTTL(for key: RedisKey, on client: any RedisClient) async throws {
        _ = try await client.send(command: "EXPIRE", with: [
            RESPValue(from: key.rawValue),
            RESPValue(from: String(dataTTLSeconds)),
        ]).get()
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else { throw SessionEncodingError() }
        return string
    }

    /// Writes the credentials field and refreshes the TTL.
    static func saveCred(for username: String, password: String, accountLocation: AccountLocation, on client: any RedisClient) async throws {
        let key = dataKey(for: username)
        let cred = Cred(password: password, accountLocation: accountLocation)
        _ = try await client.hset(credField, to: try encodeJSON(cred), in: key).get()
        try await refreshTTL(for: key, on: client)
    }

    /// Writes the polling-state field and refreshes the TTL.
    static func saveState(for username: String, from session: LiveActivityPollSession, on client: any RedisClient) async throws {
        let key = dataKey(for: username)
        _ = try await client.hset(stateField, to: try encodeJSON(State(from: session)), in: key).get()
        try await refreshTTL(for: key, on: client)
    }

    /// Writes (or replaces) one device's token field and refreshes the TTL. Replacing is an
    /// isolated single-field write, so it never disturbs another device's token.
    static func saveToken(for username: String, _ token: LiveActivityTokenEntry, on client: any RedisClient) async throws {
        let key = dataKey(for: username)
        _ = try await client.hset(tokenField(token.activityID), to: try encodeJSON(token), in: key).get()
        try await refreshTTL(for: key, on: client)
    }

    /// Removes one device's token field.
    static func removeToken(for username: String, activityID: String, on client: any RedisClient) async throws {
        _ = try await client.hdel(tokenField(activityID), from: dataKey(for: username)).get()
    }

    /// Loads and reassembles a full session from its fields. Falls back to the legacy
    /// single-blob `data` field for sessions written before per-field storage, migrating
    /// them into the new layout on read so they're not dropped on deploy.
    static func loadSession(for username: String, on client: any RedisClient, logger: Logger? = nil) async throws -> LoadedSession {
        let key = dataKey(for: username)
        let raw = try await client.send(command: "HGETALL", with: [RESPValue(from: key.rawValue)]).get()
        guard let array = raw.array, !array.isEmpty else { return .missing }

        var fields: [String: String] = [:]
        var index = 0
        while index + 1 < array.count {
            if let name = array[index].string, let value = array[index + 1].string {
                fields[name] = value
            }
            index += 2
        }

        // Legacy migration: an old whole-session blob with no per-field data yet. Done as a
        // single multi-field write (+ one EXPIRE, one HDEL) so it's cheap and idempotent —
        // important because loadSession is also called from the constantly-polled
        // glucose-readings GET, and concurrent callers just repeat the same writes.
        if fields[stateField] == nil, let legacy = fields[legacyField] {
            guard let session = try? JSONDecoder().decode(LiveActivityPollSession.self, from: Data(legacy.utf8)) else {
                logger?.warning("🔀 \(username.redactedEmailLogID) Legacy session blob failed to decode, treating as undecodable")
                return .undecodable
            }
            logger?.info("🔀 \(session.logID) Migrating legacy session blob → per-field (\(session.tokens.count) token(s))")
            var newFields: [String: String] = [
                credField: try encodeJSON(Cred(password: session.password, accountLocation: session.accountLocation)),
                stateField: try encodeJSON(State(from: session)),
            ]
            for token in session.tokens {
                newFields[tokenField(token.activityID)] = try encodeJSON(token)
            }
            try await client.hmset(newFields, in: key).get()
            try await refreshTTL(for: key, on: client)
            _ = try await client.hdel(legacyField, from: key).get()
            // The HDEL above only returns after the write lands, so reaching here means the
            // per-field fields are written and the legacy blob is gone — migration succeeded.
            logger?.info("✅ \(session.logID) Migrated legacy session (\(session.tokens.count) token(s))")
            return .present(session)
        }

        guard let credString = fields[credField], let stateString = fields[stateField] else {
            return .missing
        }
        do {
            let cred = try JSONDecoder().decode(Cred.self, from: Data(credString.utf8))
            let state = try JSONDecoder().decode(State.self, from: Data(stateString.utf8))
            let tokens = try fields
                .filter { $0.key.hasPrefix(tokenFieldPrefix) }
                .map { try JSONDecoder().decode(LiveActivityTokenEntry.self, from: Data($0.value.utf8)) }
            let session = LiveActivityPollSession(
                username: username,
                password: cred.password,
                accountID: state.accountID,
                sessionID: state.sessionID,
                accountLocation: cred.accountLocation,
                tokens: tokens,
                sessionStartDate: state.sessionStartDate,
                lastReadingDate: state.lastReadingDate,
                lastReading: state.lastReading,
                readings: state.readings,
                pollInterval: state.pollInterval,
                retryCount: state.retryCount,
                lastStaleUpdateMinutes: state.lastStaleUpdateMinutes,
                recoveryInterval: state.recoveryInterval
            )
            return .present(session)
        } catch {
            return .undecodable
        }
    }

    /// A count of currently-tracked sessions and the running Live Activities across them.
    struct ActivityCounts: Codable, Sendable {
        /// One per Dexcom username being polled.
        let sessions: Int
        /// One per device `tok:` field — i.e. each live Activity receiving pushes.
        let activities: Int
    }

    /// Counts sessions (schedule members) and total running activities (token fields) in a
    /// single Lua pass, so a status check is one round-trip regardless of user count.
    static func countActivities(on client: any RedisClient) async throws -> ActivityCounts {
        let script = """
        local members = redis.call('ZRANGE', KEYS[1], 0, -1)
        local prefix = ARGV[1]
        local plen = string.len(prefix)
        local activities = 0
        for _, user in ipairs(members) do
            for _, name in ipairs(redis.call('HKEYS', ARGV[2] .. user)) do
                if string.sub(name, 1, plen) == prefix then
                    activities = activities + 1
                end
            end
        end
        return {#members, activities}
        """
        let result = try await client.send(command: "EVAL", with: [
            RESPValue(from: script),
            RESPValue(from: "1"),
            RESPValue(from: scheduleKey.rawValue),
            RESPValue(from: tokenFieldPrefix),
            RESPValue(from: dataKeyPrefix),
        ]).get()
        let array = result.array ?? []
        let sessions = array.count > 0 ? (array[0].int ?? 0) : 0
        let activities = array.count > 1 ? (array[1].int ?? 0) : 0
        return ActivityCounts(sessions: sessions, activities: activities)
    }

    /// Atomically removes the schedule entry and the entire hash for a username.
    /// A two-call zrem+del leaves a window where a concurrent `start-live-activity`
    /// can read the still-existing data, then write it back after the delete fires —
    /// leaving an orphan hash with no schedule entry that the scheduler never polls.
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

    /// Atomically (optionally removes one device's token field first, then) tears the session
    /// down **only if no token fields remain**. Doing the HDEL and the emptiness check in one
    /// script closes the window where, between a separate HDEL and check, a device registering
    /// concurrently would either be wrongly removed or leave an orphan. The token prefix is
    /// passed in so the Lua never drifts from `tokenFieldPrefix`. Returns true if the session
    /// was removed, false if a token remained and it was left intact.
    @discardableResult
    static func pruneSession(for username: String, removingActivityID activityID: String? = nil, on client: any RedisClient) async throws -> Bool {
        let script = """
        if ARGV[3] ~= '' then redis.call('HDEL', KEYS[2], ARGV[3]) end
        local prefix = ARGV[2]
        local plen = string.len(prefix)
        for _, name in ipairs(redis.call('HKEYS', KEYS[2])) do
            if string.sub(name, 1, plen) == prefix then return 0 end
        end
        redis.call('ZREM', KEYS[1], ARGV[1])
        redis.call('DEL', KEYS[2])
        return 1
        """
        let result = try await client.send(command: "EVAL", with: [
            RESPValue(from: script),
            RESPValue(from: "2"),
            RESPValue(from: scheduleKey.rawValue),
            RESPValue(from: dataKey(for: username).rawValue),
            RESPValue(from: username),
            RESPValue(from: tokenFieldPrefix),
            RESPValue(from: activityID.map(tokenField) ?? ""),
        ]).get()
        return result.int == 1
    }
}
