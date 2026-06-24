#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor
import Queues
@preconcurrency import Redis
import Dexcom
import APNS
import APNSCore
import VaporAPNS

// Captures session IDs when DexcomClient logs in
private final class SessionCapture: DexcomClientDelegate, @unchecked Sendable {
    var accountID: UUID?
    var sessionID: UUID?

    func didUpdateAccountID(_ accountID: UUID) {
        self.accountID = accountID
    }

    func didUpdateSessionID(_ sessionID: UUID) {
        self.sessionID = sessionID
    }
}

/// A scheduled job that runs every second to process due live activity poll sessions.
/// Each session represents one Dexcom username with one or more device tokens.
/// Dexcom is polled once per session, then APNS updates are fanned out to all tokens.
struct LiveActivityScheduler: AsyncScheduledJob {
    static let appBundleID = "com.kylebashour.Glimpse"
    // Floor on poll spacing. When a reading is overdue/not yet ready we recheck no more
    // often than this — a full minute rather than hammering every 30s.
    static let minInterval: TimeInterval = 60
    static let maxInterval: TimeInterval = 60
    static let readingInterval: TimeInterval = 60 * 5 // 5 minutes
    static let offlineInterval: TimeInterval = 60 * 15 // 15 minutes — when a reading is considered offline
    static let minStaleDateBuffer: TimeInterval = 60 * 2 // floor on staleDate so it's never in the past or near-now
    // Max lifetime of a Live Activity before the server ends it. Supported by all builds.
    static let maximumDuration: TimeInterval = 60 * 60 * 7 // 7h
    static let backoff: TimeInterval = 2.0
    static let errorBackoff: TimeInterval = 3
    static let decodingErrorRetryLimit = 10
    static let genericErrorRetryLimit = 6
    // After a rate limit (429), poll no more often than this at first, then ease back
    // toward minInterval (recoveryInterval shrinks to recoveryDecay of itself on each
    // healthy poll) rather than immediately resuming the aggressive overdue cadence.
    static let recoveryStartInterval: TimeInterval = 300 // 5 min
    static let recoveryDecay: Double = 0.6
    // On a 429, never reschedule sooner than this. A reading about to land would just get
    // rate-limited again, so skip it and aim for a later one — at least ~4 minutes out.
    static let rateLimitMinDelay: TimeInterval = 60 * 4 // 4 min

    func run(context: QueueContext) async throws {
        let app = context.application
        let now = Date()
        let nowTimestamp = now.timeIntervalSince1970

        let dueSessions = try await getDueSessions(app: app, beforeTimestamp: nowTimestamp)

        guard !dueSessions.isEmpty else { return }

        context.logger.info("📥 Dequeued sessions (\(dueSessions.count))")

        for username in dueSessions {
            await processSession(username: username, app: app, now: now)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: - Redis Operations

    /// Queries for sessions due for processing and immediately bumps their scores
    /// to prevent re-pickup by subsequent scheduler runs.
    private func getDueSessions(app: Application, beforeTimestamp: Double) async throws -> [String] {
        let results = try await app.redis.zrangebyscore(
            from: LiveActivityPollKeys.scheduleKey,
            withScoresBetween: (.inclusive(-.infinity), .inclusive(beforeTimestamp))
        ).get()

        let usernames = results.compactMap { String(fromRESP: $0) }

        // Bump scores to prevent re-pickup while processing.
        let processingTimestamp = beforeTimestamp + Self.maxInterval
        for username in usernames {
            _ = try? await app.redis.zadd(
                (element: username, score: processingTimestamp),
                to: LiveActivityPollKeys.scheduleKey
            ).get()
        }

        return usernames
    }

    private func removeSession(app: Application, username: String) async {
        try? await LiveActivityPollKeys.removeSession(username, on: app.redis)
    }

    // MARK: - Session Processing

    private func processSession(username: String, app: Application, now: Date) async {
        do {
            // Both a missing hash and an undecodable one are dead schedule entries: remove
            // them so the every-second scheduler stops re-polling them forever (the cause of
            // unbounded Redis growth decoupled from user count). A transient Redis error
            // throws instead and is caught below WITHOUT removal, so a blip can't delete
            // live sessions.
            var session: LiveActivityPollSession
            switch try await LiveActivityPollKeys.loadSession(for: username, on: app.redis) {
            case .present(let loaded):
                session = loaded
            case .missing:
                app.logger.info("🗑️ Session \(username.prefix(8))... data not found, removing from schedule")
                await removeSession(app: app, username: username)
                return
            case .undecodable:
                app.logger.warning("🧟 Session \(username.prefix(8))... data undecodable, removing from schedule")
                app.axiom?.emit("session_removed", attributes: [
                    "user": username.redactedEmailLogID,
                    "reason": "undecodable",
                ])
                await removeSession(app: app, username: username)
                return
            }

            // Poll Dexcom up front so the push-to-start seed below — and the client-facing
            // cached /glucose-readings endpoint, which both read session.readings — reflect
            // the freshest reading rather than the previous tick's cache. Previously the poll
            // ran only after expiry handling (and not at all when the session was torn down),
            // so an hour-7 restart seeded a stale value. The result is reused by
            // pollAndUpdate, so the common path makes no extra Dexcom call; only a session
            // that fully expires this tick incurs one poll it would otherwise have skipped.
            let sessionCapture = SessionCapture()
            let client = DexcomClient(
                username: session.username,
                password: session.password,
                existingAccountID: session.accountID,
                existingSessionID: session.sessionID,
                accountLocation: session.accountLocation
            )
            await client.setDelegate(sessionCapture)

            let pollResult: Result<[GlucoseReading], any Error>
            do {
                app.logger.info("🔄 \(session.logID) Checking for new readings")
                let readings = try await client.getGlucoseReadings(
                    duration: .init(value: 24, unit: .hours)
                ).sorted { $0.date < $1.date }
                pollResult = .success(readings)
            } catch {
                pollResult = .failure(error)
            }

            // Seed restarts from the fresh poll; fall back to the cache if it failed or was
            // empty so a poll blip never seeds an emptier activity than before.
            let polledReadings = try? pollResult.get()
            let hasFreshReadings = !(polledReadings?.isEmpty ?? true)
            let seedReadings = hasFreshReadings
                ? polledReadings!
                : (session.readings ?? session.lastReading.map { [$0] } ?? [])
            let seedLatestReading = hasFreshReadings ? polledReadings!.last : session.lastReading

            // 1. Per-token expiry: remove tokens past their max duration, send end to each.
            var expiredTokens: [LiveActivityTokenEntry] = []
            session.tokens.removeAll { token in
                let duration = Self.maximumDuration

                // Expire relative to when the activity actually started. startDate is
                // preserved across push-token rotations (matched by activityID), so it
                // reflects the true activity start.
                if now.timeIntervalSince(token.startDate) >= duration {
                    expiredTokens.append(token)
                    return true
                }
                return false
            }

            for token in expiredTokens {
                // If the client opted into auto-restart and gave us a push-to-start token,
                // dismiss the old activity and start a fresh one on the same device for
                // continuous coverage past the time limit. The app observes the new activity,
                // captures its update token, and re-registers — starting a new session.
                let willRestart = token.canRestartViaPushToStart
                app.logger.info("🕟 \(session.logID) Token \(token.pushToken.rawValue.prefix(8))... reached max duration\(willRestart ? ", restarting via push-to-start" : "")")
                await Self.sendEndEvent(
                    app: app,
                    pushToken: token.pushToken,
                    environment: token.environment,
                    sessionStartDate: session.sessionStartDate,
                    tokenStartDate: token.startDate,
                    tokenCount: session.tokens.count,
                    dismiss: willRestart
                )
                await restartViaPushToStart(
                    app: app,
                    token: token,
                    session: session,
                    seedLatestReading: seedLatestReading,
                    seedReadings: seedReadings,
                    now: now
                )
                app.axiom?.emit("push_ended", attributes: [
                    "user": session.logID,
                    "environment": token.environment.rawValue,
                    "token_prefix": String(token.pushToken.rawValue.prefix(8)),
                    "reason": willRestart ? "max_duration_restarted" : "max_duration",
                ])
                // Drop this device's token field. Targeted HDEL leaves every other device's
                // token — including one that registered during this tick's poll — untouched.
                try? await LiveActivityPollKeys.removeToken(for: username, activityID: token.activityID, on: app.redis)
            }

            if session.tokens.isEmpty {
                app.logger.info("🛑 \(session.logID) All tokens expired, removing session")
                // Only tears down if no token field remains — a device that registered during
                // the poll keeps the session alive for the next tick.
                _ = try? await LiveActivityPollKeys.pruneSession(for: username, on: app.redis)
                return
            }

            // 2. Process the poll performed above
            await pollAndUpdate(
                app: app,
                session: &session,
                now: now,
                pollResult: pollResult,
                sessionCapture: sessionCapture
            )

        } catch {
            app.logger.error("Error processing session \(username.prefix(8))...: \(error)")
        }
    }

    private func pollAndUpdate(
        app: Application,
        session: inout LiveActivityPollSession,
        now: Date,
        pollResult: Result<[GlucoseReading], any Error>,
        sessionCapture: SessionCapture
    ) async {
        do {
            let readings = try pollResult.get()

            guard let latestReading = readings.last else {
                app.logger.warning("🛑 \(session.logID) No readings available")
                app.axiom?.emit("poll_empty", attributes: [
                    "user": session.logID,
                    "retry_count": String(session.retryCount),
                    "minutes_since_last_reading": session.lastReadingDate.map { String(Int(now.timeIntervalSince($0) / 60)) } ?? "unknown",
                ])
                await sendStaleUpdatesIfNeeded(app: app, session: &session, now: now, reason: "No new readings")
                let nextPollInterval = min(session.pollInterval * Self.backoff, Self.overduePollCap(for: session))
                await reschedule(
                    app: app,
                    session: &session,
                    pollInterval: nextPollInterval,
                    lastReading: session.lastReading,
                    readings: session.readings,
                    delay: max(session.pollInterval, Self.pollFloor(for: session)),
                    sessionCapture: sessionCapture,
                    resetRetries: true
                )
                return
            }

            // Check if we have a new reading
            if let lastDate = session.lastReadingDate, latestReading.date <= lastDate {
                let timeSinceLastReading = now.timeIntervalSince(lastDate)

                await sendStaleUpdatesIfNeeded(app: app, session: &session, now: now, reason: "No new readings")

                if timeSinceLastReading >= Self.readingInterval {
                    // Reading is overdue. Back off toward the reading cadence (~5 min) rather
                    // than polling every 60s — a new value can't land sooner, so faster polls
                    // only spend the account's Dexcom read budget and draw 429s. First recheck
                    // stays quick (delay uses the current, smaller pollInterval) to catch a
                    // slightly-late reading; sustained gaps settle at overduePollCap.
                    let nextPollInterval = min(session.pollInterval * Self.backoff, Self.overduePollCap(for: session))
                    await reschedule(
                        app: app,
                        session: &session,
                        pollInterval: nextPollInterval,
                        lastReading: session.lastReading,
                        readings: session.readings,
                        delay: max(session.pollInterval, Self.pollFloor(for: session)),
                        sessionCapture: sessionCapture,
                        resetRetries: false
                    )
                } else {
                    // Still within normal reading window, wait for next expected reading
                    await scheduleForNextReading(
                        app: app,
                        session: &session,
                        now: now,
                        readingDate: lastDate,
                        reading: session.lastReading,
                        readings: session.readings,
                        sessionCapture: sessionCapture
                    )
                }
                return
            }

            app.logger.info("✅ \(session.logID) New reading available - sending push to \(session.tokens.count) token(s)")

            // Fan out APNS to all tokens
            await fanOutUpdate(
                app: app,
                session: &session,
                now: now,
                readings: readings,
                latestReading: latestReading,
                sessionCapture: sessionCapture
            )

        } catch let error as DexcomClientError {
            app.logger.error("\(session.logID) Ending all tokens due to DexcomClientError: \(error)")
            app.axiom?.emit("poll_error", attributes: [
                "user": session.logID,
                "error_type": "client",
                "error": String(describing: error),
                "retry_count": String(session.retryCount),
                "will_end": "true",
            ])
            await endAllTokens(app: app, session: session, reason: .dexcomError)
        } catch let error as DexcomDecodingError {
            app.axiom?.emit("poll_error", attributes: [
                "user": session.logID,
                "error_type": "decoding",
                "status_code": error.statusCode?.description ?? "unknown",
                // Which Dexcom endpoint returned the error. Distinguishes a readings-endpoint
                // rate limit from the auth/login endpoints, which tells us whether the client's
                // re-auth-on-error path is amplifying 429s. Values: ReadPublisherLatestGlucoseValues
                // (readings), AuthenticatePublisherAccount (auth), LoginPublisherAccountById (login).
                "endpoint": error.url?.lastPathComponent ?? "unknown",
                "error": error.errorDescription,
                "retry_count": String(session.retryCount),
                "will_end": (session.pollInterval >= Self.maxInterval && session.retryCount > Self.decodingErrorRetryLimit) ? "true" : "false",
            ])
            await handleDecodingError(app: app, session: &session, error: error, sessionCapture: sessionCapture)
            let staleReason = error.statusCode == 429 ? "Rate limited" : "Dexcom error"
            await sendStaleUpdatesIfNeeded(app: app, session: &session, now: now, reason: staleReason)
        } catch {
            app.axiom?.emit("poll_error", attributes: [
                "user": session.logID,
                "error_type": "generic",
                "error": String(describing: error),
                "retry_count": String(session.retryCount),
                "will_end": (session.pollInterval >= Self.maxInterval && session.retryCount >= Self.genericErrorRetryLimit) ? "true" : "false",
            ])
            await handleGenericError(app: app, session: &session, error: error, sessionCapture: sessionCapture)
            await sendStaleUpdatesIfNeeded(app: app, session: &session, now: now, reason: "Polling error")
        }
    }

    // MARK: - Stale Updates

    /// Sends stale milestone updates (at 5, 10, and 15 minutes) when no new reading is available.
    private func sendStaleUpdatesIfNeeded(
        app: Application,
        session: inout LiveActivityPollSession,
        now: Date,
        reason: String?
    ) async {
        guard let lastReadingDate = session.lastReadingDate, let lastReading = session.lastReading else { return }

        let timeSinceLastReading = now.timeIntervalSince(lastReadingDate)
        guard timeSinceLastReading >= Self.readingInterval else { return }

        // Share the threshold ladder with the push-to-start seed path so the two can't drift.
        guard let level = Self.staleLevel(forTimeSinceLastReading: timeSinceLastReading) else { return }
        let milestoneMinutes: Int = switch level {
        case .fresh: 0 // unreachable: staleLevel returns nil below the warning threshold
        case .warning: 5
        case .stale: 10
        case .offline: 15
        }

        guard session.lastStaleUpdateMinutes != milestoneMinutes else { return }

        app.logger.info("📡 \(session.logID) Sending stale update at \(milestoneMinutes) minutes")
        session.lastStaleUpdateMinutes = milestoneMinutes

        let readings = session.readings ?? [lastReading]
        for token in session.tokens {
            let tokenReadings = trim(readings: readings, toDuration: token.duration, now: now)
            await sendStaleUpdate(
                app: app,
                pushToken: token.pushToken,
                environment: token.environment,
                readings: tokenReadings,
                latestReading: lastReading,
                sessionStartDate: session.sessionStartDate,
                tokenStartDate: token.startDate,
                tokenCount: session.tokens.count,
                staleLevel: level,
                reason: reason,
                pushToStartAvailable: token.pushToStartToken != nil,
                logID: session.logID
            )
        }
    }

    // MARK: - Error Handling

    private func handleDecodingError(
        app: Application,
        session: inout LiveActivityPollSession,
        error: DexcomDecodingError,
        sessionCapture: SessionCapture
    ) async {
        let bodyString = String(data: error.body, encoding: .utf8) ?? "<non-utf8 data, \(error.body.count) bytes>"
        let statusCode = error.statusCode?.description ?? "unknown"
        app.logger.error("🚫 \(session.logID) DexcomDecodingError status: \(statusCode) body: \(bodyString)")

        if session.pollInterval >= Self.maxInterval && session.retryCount > Self.decodingErrorRetryLimit {
            app.logger.error("🤬 \(session.logID) Done retrying due to errors, ending all tokens")
            await endAllTokens(app: app, session: session, reason: .tooManyRetries)
        } else {
            let nextPollInterval = min(session.pollInterval * Self.errorBackoff, Self.maxInterval)
            let delay: TimeInterval = if error.statusCode == 429 {
                // Queue the next poll for a reading boundary at least rateLimitMinDelay out,
                // skipping any reading about to land — retrying right before it just
                // re-triggers the 429.
                Self.delayUntilNextReading(
                    after: session.lastReadingDate,
                    now: Date(),
                    minimumDelay: Self.rateLimitMinDelay
                )
            } else {
                session.pollInterval
            }

            if error.statusCode == 429 {
                // Once the rate limit clears, ease back into polling instead of resuming the
                // aggressive overdue cadence, which tends to immediately re-trigger the 429.
                session.recoveryInterval = Self.recoveryStartInterval
            }

            session.retryCount += 1

            await reschedule(
                app: app,
                session: &session,
                pollInterval: nextPollInterval,
                lastReading: session.lastReading,
                readings: session.readings,
                delay: delay,
                sessionCapture: sessionCapture,
                resetRetries: false
            )
        }
    }

    private func handleGenericError(
        app: Application,
        session: inout LiveActivityPollSession,
        error: any Error,
        sessionCapture: SessionCapture
    ) async {
        app.logger.error("🚫 \(session.logID) Error polling for session: \(error)")

        if session.pollInterval >= Self.maxInterval && session.retryCount >= Self.genericErrorRetryLimit {
            app.logger.error("🤬 \(session.logID) Done retrying due to errors, ending all tokens")
            await endAllTokens(app: app, session: session, reason: .tooManyRetries)
        } else {
            let nextPollInterval = min(session.pollInterval * Self.errorBackoff, Self.maxInterval)

            session.retryCount += 1

            await reschedule(
                app: app,
                session: &session,
                pollInterval: nextPollInterval,
                lastReading: session.lastReading,
                readings: session.readings,
                delay: session.pollInterval,
                sessionCapture: sessionCapture,
                resetRetries: false
            )
        }
    }

    /// Trim a readings array to the window a given token cares about, so APNS
    /// payloads don't balloon now that we cache 24h on the server.
    private func trim(readings: [GlucoseReading], toDuration duration: TimeInterval, now: Date) -> [GlucoseReading] {
        let cutoff = now.addingTimeInterval(-duration)
        return readings.filter { $0.date >= cutoff }
    }

    /// Delay until a reading boundary at least `minimumDelay` out, used to back off from an
    /// HTTP 429. Readings arrive every `readingInterval`, and a rate limit window usually
    /// outlasts a short wait — so rather than retrying within the current cycle (which just
    /// re-triggers the 429), aim for the first reading boundary at least `minimumDelay` away.
    /// Any reading about to land sooner than that is skipped, since polling right before it
    /// while rate-limited would only re-trigger the limit.
    static func delayUntilNextReading(
        after lastReadingDate: Date?,
        now: Date,
        minimumDelay: TimeInterval = 0
    ) -> TimeInterval {
        let buffer: TimeInterval = 20 // covers typical Share API propagation
        guard let lastReadingDate else {
            return Swift.max(readingInterval + buffer, minimumDelay)
        }
        let elapsed = now.timeIntervalSince(lastReadingDate)
        let cyclesElapsed = (elapsed / readingInterval).rounded(.down)
        // Start at the first reading boundary still in the future, then keep skipping
        // boundaries until the wait clears `minimumDelay`.
        var nextReadingDate = lastReadingDate.addingTimeInterval((cyclesElapsed + 1) * readingInterval)
        var delay = nextReadingDate.timeIntervalSince(now) + buffer
        while delay < minimumDelay {
            nextReadingDate.addTimeInterval(readingInterval)
            delay = nextReadingDate.timeIntervalSince(now) + buffer
        }
        return delay
    }

    /// Eases the post-rate-limit recovery floor back toward normal polling. Returns the
    /// next floor, or nil once it has shrunk back to (at or below) minInterval.
    static func decayedRecovery(_ current: TimeInterval?) -> TimeInterval? {
        guard let current else { return nil }
        let next = current * recoveryDecay
        return next > minInterval ? next : nil
    }

    /// Minimum spacing between polls, raised to the recovery floor while easing back
    /// from a rate limit so we don't immediately resume the aggressive overdue cadence.
    private static func pollFloor(for session: LiveActivityPollSession) -> TimeInterval {
        Swift.max(minInterval, session.recoveryInterval ?? 0)
    }

    /// Upper bound on poll spacing while waiting out a no-reading gap. A new value can't
    /// arrive faster than the sensor's reading cadence, so once a reading is overdue we let
    /// the backoff grow toward `readingInterval` (≈5 min) rather than pinning at `maxInterval`
    /// (60s). Polling every 60s during a gap just burns the account's per-account Dexcom read
    /// budget on requests that can't return anything new — the dominant source of 429s for
    /// gap-heavy users. Still respects an active post-429 recovery floor.
    private static func overduePollCap(for session: LiveActivityPollSession) -> TimeInterval {
        Swift.max(readingInterval, session.recoveryInterval ?? 0)
    }

    // MARK: - Scheduling

    private func scheduleForNextReading(
        app: Application,
        session: inout LiveActivityPollSession,
        now: Date,
        readingDate: Date,
        reading: GlucoseReading?,
        readings: [GlucoseReading]?,
        sessionCapture: SessionCapture
    ) async {
        let timeSinceReading = now.timeIntervalSince(readingDate)
        let timeUntilNextReading = Self.readingInterval - timeSinceReading
        let delay = timeUntilNextReading + 20 // give 20s to try to ensure reading is ready (covers typical Share API propagation)
        await reschedule(
            app: app,
            session: &session,
            pollInterval: Self.pollFloor(for: session),
            lastReading: reading,
            readings: readings,
            delay: delay,
            sessionCapture: sessionCapture,
            resetRetries: true
        )
    }

    private func reschedule(
        app: Application,
        session: inout LiveActivityPollSession,
        pollInterval: TimeInterval,
        lastReading: GlucoseReading?,
        readings: [GlucoseReading]?,
        delay: TimeInterval,
        sessionCapture: SessionCapture,
        resetRetries: Bool
    ) async {
        session.pollInterval = pollInterval
        session.lastReading = lastReading
        session.lastReadingDate = lastReading?.date
        session.readings = readings
        session.accountID = sessionCapture.accountID ?? session.accountID
        session.sessionID = sessionCapture.sessionID ?? session.sessionID
        if resetRetries {
            session.retryCount = 0
            // A healthy (non-error) poll — relax the post-rate-limit recovery floor a step.
            session.recoveryInterval = Self.decayedRecovery(session.recoveryInterval)
        }

        let nextTimestamp = Date().addingTimeInterval(delay).timeIntervalSince1970

        do {
            // Persist only the scheduler-owned polling state. The token fields are left
            // exactly as they are in Redis, so a device that registered during the poll is
            // never overwritten — it's already stored as its own field and will be picked up
            // on the next load.
            try await LiveActivityPollKeys.saveState(for: session.username, from: session, on: app.redis)

            _ = try await app.redis.zadd(
                (element: session.username, score: nextTimestamp),
                to: LiveActivityPollKeys.scheduleKey
            ).get()

            let scheduledTime = Date(timeIntervalSince1970: nextTimestamp)
                .formatted(.dateTime.hour().minute().second())
            let formattedDelay = Duration.seconds(delay).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            app.logger.info("😴 \(session.logID) Scheduled for \(scheduledTime) (in \(formattedDelay))")
        } catch {
            app.logger.error("Failed to reschedule \(session.logID): \(error)")
            app.axiom?.emit("reschedule_failed", attributes: [
                "user": session.logID,
                "error": String(describing: error),
                "retry_count": String(session.retryCount),
            ])
        }
    }

    // MARK: - Activity Lifecycle

    private enum EndReason: String {
        case maxDuration
        case dexcomError
        case apnsInvalidToken
        case tooManyRetries
    }

    /// Ends all tokens in a session and cleans up.
    private func endAllTokens(app: Application, session: LiveActivityPollSession, reason: EndReason) async {
        for token in session.tokens {
            await Self.sendEndEvent(
                app: app,
                pushToken: token.pushToken,
                environment: token.environment,
                sessionStartDate: session.sessionStartDate,
                tokenStartDate: token.startDate,
                tokenCount: session.tokens.count
            )
            app.axiom?.emit("push_ended", attributes: [
                "user": session.logID,
                "environment": token.environment.rawValue,
                "token_prefix": String(token.pushToken.rawValue.prefix(8)),
                "reason": reason.rawValue,
            ])
            // Drop each ended token's field individually...
            try? await LiveActivityPollKeys.removeToken(for: session.username, activityID: token.activityID, on: app.redis)
        }

        // ...then tear down the session only if no token registered during this tick.
        _ = try? await LiveActivityPollKeys.pruneSession(for: session.username, on: app.redis)

        app.logger.info("🛑 \(session.logID) Session ended (\(session.tokens.count) tokens): \(reason.rawValue)")
    }

    /// Relaunch a fresh Live Activity on this device via push-to-start, seeded with the
    /// latest reading. Used both when an activity hits its max duration and when its update
    /// token expires mid-session. A no-op (returns false) if the client didn't opt into
    /// push-to-start. Does NOT send an end event — callers that need to dismiss a still-live
    /// activity first (the max-duration path) send their own end event; an expired token has
    /// no activity left to end.
    @discardableResult
    private func restartViaPushToStart(
        app: Application,
        token: LiveActivityTokenEntry,
        session: LiveActivityPollSession,
        seedLatestReading: GlucoseReading?,
        seedReadings: [GlucoseReading],
        now: Date
    ) async -> Bool {
        guard let pushToStartToken = token.pushToStartToken,
              let attributesType = token.attributesType,
              let attributes = token.attributes else {
            return false
        }
        await Self.sendStartEvent(
            app: app,
            pushToStartToken: pushToStartToken,
            environment: token.environment,
            attributesType: attributesType,
            attributes: attributes,
            latestReading: seedLatestReading,
            readings: trim(readings: seedReadings, toDuration: token.duration, now: now),
            sessionStartDate: session.sessionStartDate,
            tokenCount: session.tokens.count,
            now: now,
            logID: session.logID
        )
        return true
    }

    // MARK: - APNS

    /// Fan out a reading update to all tokens. Removes tokens that get fatal APNS errors.
    private func fanOutUpdate(
        app: Application,
        session: inout LiveActivityPollSession,
        now: Date,
        readings: [GlucoseReading],
        latestReading: GlucoseReading,
        sessionCapture: SessionCapture
    ) async {
        var tokensToRemove: Set<LiveActivityPushToken> = []
        // Tokens whose activity vanished (APNS reported it expired/unregistered) and that
        // opted into push-to-start — relaunch a fresh activity for each so monitoring keeps
        // going instead of going dark until the user reopens the app.
        var tokensToRestart: [LiveActivityTokenEntry] = []

        for token in session.tokens {
            let alertContent = alert(for: latestReading, lastReading: session.lastReading, preferences: token.preferences)
            let tokenPrefix = String(token.pushToken.rawValue.prefix(8))
            let tokenReadings = trim(readings: readings, toDuration: token.duration, now: now)
            do {
                try await sendActivityPush(
                    app: app,
                    pushToken: token.pushToken,
                    environment: token.environment,
                    readings: tokenReadings,
                    latestReading: latestReading,
                    sessionStartDate: session.sessionStartDate,
                    tokenStartDate: token.startDate,
                    tokenCount: session.tokens.count,
                    pushToStartAvailable: token.pushToStartToken != nil,
                    alert: alertContent
                )
                app.logger.info("🚚 \(session.logID) Sent push to \(tokenPrefix)...")
                app.axiom?.emit("push_sent", attributes: [
                    "user": session.logID,
                    "environment": token.environment.rawValue,
                    "token_prefix": tokenPrefix,
                    "kind": "update",
                    "has_alert": alertContent != nil ? "true" : "false",
                ])
            } catch let error as APNSCore.APNSError {
                app.logger.error("\(session.logID) APNS error for \(tokenPrefix)...: \(error)")
                let apnsReason = error.reason?.reason ?? "unknown"
                var willRemove = false
                var willRestart = false
                if let reason = error.reason,
                   reason == .badDeviceToken || reason == .unregistered || reason == .expiredToken {
                    app.logger.error("\(session.logID) Removing token \(tokenPrefix)... due to \(reason.reason)")
                    tokensToRemove.insert(token.pushToken)
                    willRemove = true
                    // .expiredToken / .unregistered mean the activity is genuinely gone from
                    // the device, so relaunch it if the client opted into push-to-start.
                    // .badDeviceToken is a malformed/wrong-environment token, not a vanished
                    // activity — restarting that would risk a duplicate, so leave it dropped.
                    if (reason == .expiredToken || reason == .unregistered), token.canRestartViaPushToStart {
                        tokensToRestart.append(token)
                        willRestart = true
                    }
                }
                app.axiom?.emit("push_failed", attributes: [
                    "user": session.logID,
                    "environment": token.environment.rawValue,
                    "token_prefix": tokenPrefix,
                    "kind": "update",
                    "error_type": "apns",
                    "apns_reason": apnsReason,
                    "token_removed": willRemove ? "true" : "false",
                    "token_restarted": willRestart ? "true" : "false",
                ])
            } catch {
                app.logger.error("\(session.logID) Unexpected error sending push to \(tokenPrefix)...: \(error)")
                app.axiom?.emit("push_failed", attributes: [
                    "user": session.logID,
                    "environment": token.environment.rawValue,
                    "token_prefix": tokenPrefix,
                    "kind": "update",
                    "error_type": "other",
                    "error": String(describing: type(of: error)),
                ])
            }
        }

        // Remove invalid tokens — drop each one's field individually so valid devices (and
        // any that registered during this poll) are untouched.
        if !tokensToRemove.isEmpty {
            for token in session.tokens where tokensToRemove.contains(token.pushToken) {
                try? await LiveActivityPollKeys.removeToken(for: session.username, activityID: token.activityID, on: app.redis)
            }
            session.tokens.removeAll { tokensToRemove.contains($0.pushToken) }
        }

        // Relaunch any expired activities that opted into push-to-start. Done before the
        // empty-session teardown below so a session whose only token just expired still gets
        // its restart — the new activity re-registers as a fresh session within seconds.
        for token in tokensToRestart {
            app.logger.info("🔁 \(session.logID) Token \(token.pushToken.rawValue.prefix(8))... expired, restarting via push-to-start")
            await restartViaPushToStart(
                app: app,
                token: token,
                session: session,
                seedLatestReading: latestReading,
                seedReadings: readings,
                now: now
            )
            app.axiom?.emit("push_ended", attributes: [
                "user": session.logID,
                "environment": token.environment.rawValue,
                "token_prefix": String(token.pushToken.rawValue.prefix(8)),
                "reason": "expired_token_restarted",
            ])
        }

        if session.tokens.isEmpty {
            app.logger.info("🛑 \(session.logID) All tokens invalid, removing session")
            _ = try? await LiveActivityPollKeys.pruneSession(for: session.username, on: app.redis)
            return
        }

        // A fresh reading landed — clear the stale-milestone dedup so the next
        // run of staleness (if it happens) starts from the 5m milestone again.
        session.lastStaleUpdateMinutes = nil

        // Schedule next poll
        await scheduleForNextReading(
            app: app,
            session: &session,
            now: now,
            readingDate: latestReading.date,
            reading: latestReading,
            readings: readings,
            sessionCapture: sessionCapture
        )
    }

    private func sendActivityPush(
        app: Application,
        pushToken: LiveActivityPushToken,
        environment: PushEnvironment,
        readings: [GlucoseReading],
        latestReading: GlucoseReading,
        sessionStartDate: Date?,
        tokenStartDate: Date,
        tokenCount: Int,
        staleLevel: LiveActivityState.StaleLevel? = nil,
        reason: String? = nil,
        pushToStartAvailable: Bool = false,
        alert: APNSAlertNotificationContent? = nil
    ) async throws {
        let apnsClient = switch environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        let state = LiveActivityState(
            c: latestReading,
            h: readings.map { .init(t: $0.date, v: Int16($0.value)) },
            se: nil,
            s: staleLevel,
            sd: sessionStartDate,
            td: tokenStartDate,
            tc: tokenCount,
            pd: Date.now,
            r: reason,
            ps: pushToStartAvailable
        )

        // staleDate = the absolute "offline-at" instant for this reading. If no further
        // push arrives, the OS marks the activity stale at the same 15m mark our
        // backend-driven offline level would. Floor it to a small buffer in the future so
        // a delayed reading (or a stale-milestone push at 10/15m) never sends a staleDate
        // in the past — which would also cause APNS to drop the push via expiration.
        let computedStaleDate = latestReading.date.addingTimeInterval(Self.offlineInterval)
        let minStaleDate = Date().addingTimeInterval(Self.minStaleDateBuffer)
        let staleDate = Int(max(computedStaleDate, minStaleDate).timeIntervalSince1970)
        try await apnsClient.sendLiveActivityNotification(
            .init(
                expiration: .timeIntervalSince1970InSeconds(staleDate),
                priority: .immediately,
                appID: Self.appBundleID,
                contentState: state,
                event: .update,
                alert: alert,
                timestamp: Int(Date.now.timeIntervalSince1970),
                dismissalDate: .none,
                staleDate: staleDate,
                apnsID: nil
            ),
            deviceToken: pushToken.rawValue
        )
    }

    private func sendStaleUpdate(
        app: Application,
        pushToken: LiveActivityPushToken,
        environment: PushEnvironment,
        readings: [GlucoseReading],
        latestReading: GlucoseReading,
        sessionStartDate: Date?,
        tokenStartDate: Date,
        tokenCount: Int,
        staleLevel: LiveActivityState.StaleLevel,
        reason: String?,
        pushToStartAvailable: Bool,
        logID: String
    ) async {
        let tokenPrefix = String(pushToken.rawValue.prefix(8))
        do {
            try await sendActivityPush(
                app: app,
                pushToken: pushToken,
                environment: environment,
                readings: readings,
                latestReading: latestReading,
                sessionStartDate: sessionStartDate,
                tokenStartDate: tokenStartDate,
                tokenCount: tokenCount,
                staleLevel: staleLevel,
                reason: reason,
                pushToStartAvailable: pushToStartAvailable
            )
            app.logger.info("🚚 \(logID) Sent stale update push to \(tokenPrefix)...")
            app.axiom?.emit("push_sent", attributes: [
                "user": logID,
                "environment": environment.rawValue,
                "token_prefix": tokenPrefix,
                "kind": "stale",
            ])
        } catch {
            app.logger.error("\(logID) Error sending stale update to \(tokenPrefix)...: \(error)")
            let apnsReason = (error as? APNSCore.APNSError)?.reason?.reason
            app.axiom?.emit("push_failed", attributes: [
                "user": logID,
                "environment": environment.rawValue,
                "token_prefix": tokenPrefix,
                "kind": "stale",
                "error_type": apnsReason != nil ? "apns" : "other",
                "apns_reason": apnsReason ?? "",
                "error": String(describing: type(of: error)),
            ])
        }
    }

    static func sendEndEvent(
        app: Application,
        pushToken: LiveActivityPushToken,
        environment: PushEnvironment,
        sessionStartDate: Date? = nil,
        tokenStartDate: Date? = nil,
        tokenCount: Int? = nil,
        // Dismiss the activity immediately rather than letting it linger on the lock screen.
        // Used when we're about to replace it with a push-to-start restart.
        dismiss: Bool = false
    ) async {
        let apnsClient = switch environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        let state = LiveActivityState(
            c: nil,
            h: [],
            se: true,
            sd: sessionStartDate,
            td: tokenStartDate,
            tc: tokenCount,
            pd: Date.now
        )

        _ = try? await apnsClient.sendLiveActivityNotification(
            .init(
                expiration: .none,
                priority: .immediately,
                appID: appBundleID,
                contentState: state,
                event: .end,
                timestamp: Int(Date.now.timeIntervalSince1970),
                dismissalDate: dismiss ? .immediately : .none,
                staleDate: nil,
                apnsID: nil
            ),
            deviceToken: pushToken.rawValue
        )
    }

    /// Maps the time since the last reading to a stale level, matching the milestone
    /// thresholds used for stale updates. Returns nil when the reading is still fresh
    /// (< 5 minutes), which clients render as live.
    static func staleLevel(forTimeSinceLastReading interval: TimeInterval) -> LiveActivityState.StaleLevel? {
        let minutes = Int(interval / 60)
        if minutes >= 15 { return .offline }
        if minutes >= 10 { return .stale }
        if minutes >= 5 { return .warning }
        return nil
    }

    /// Starts a fresh Live Activity on the same device via push-to-start. The app observes
    /// `activityUpdates`, captures the new activity's update token, and re-registers with
    /// the server — which creates a new session with a fresh time limit.
    static func sendStartEvent(
        app: Application,
        pushToStartToken: String,
        environment: PushEnvironment,
        attributesType: String,
        attributes: JSONValue?,
        latestReading: GlucoseReading?,
        readings: [GlucoseReading],
        sessionStartDate: Date?,
        tokenCount: Int,
        now: Date,
        logID: String
    ) async {
        let apnsClient = switch environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        // Seed the new activity with the last cached reading so it renders real data
        // immediately instead of flashing "offline" until the restarted session's first
        // poll push lands a few seconds later. Compute staleness honestly from the
        // reading's age so a stale cache isn't presented as live.
        let state: LiveActivityState
        let staleDate: Int
        if let latestReading {
            state = LiveActivityState(
                c: latestReading,
                h: readings.map { .init(t: $0.date, v: Int16($0.value)) },
                se: false,
                s: staleLevel(forTimeSinceLastReading: now.timeIntervalSince(latestReading.date)),
                sd: sessionStartDate,
                td: now,
                tc: tokenCount,
                pd: now,
                ps: true
            )
            // Mirror sendActivityPush: the offline-at instant for this reading, floored to
            // a small buffer so it's never in the past or near-now.
            let computedStaleDate = latestReading.date.addingTimeInterval(offlineInterval)
            let minStaleDate = now.addingTimeInterval(minStaleDateBuffer)
            staleDate = Int(max(computedStaleDate, minStaleDate).timeIntervalSince1970)
        } else {
            // No cached reading (rare); fall back to minimal content. The new session
            // pushes real readings within seconds.
            state = LiveActivityState(c: nil, h: [], se: false, pd: now)
            staleDate = Int(now.addingTimeInterval(offlineInterval).timeIntervalSince1970)
        }

        let notification = APNSStartLiveActivityNotification(
            // Give APNs a real expiration (not .immediately) so it stores and retries the
            // start push if the device is briefly unreachable — otherwise a single missed
            // delivery means no restart at all, which is the common failure at hour 7.
            expiration: .timeIntervalSince1970InSeconds(staleDate),
            priority: .immediately,
            appID: appBundleID,
            contentState: state,
            timestamp: Int(now.timeIntervalSince1970),
            staleDate: staleDate,
            apnsID: nil,
            attributes: attributes ?? .object([:]),
            attributesType: attributesType,
            alert: .init(
                title: .raw("Luka"),
                body: .raw("Glucose monitoring resumed")
            )
        )

        do {
            try await apnsClient.sendStartLiveActivityNotification(
                notification,
                pushToStartToken: pushToStartToken
            )
            app.logger.info("🔁 \(logID) Sent push-to-start to \(pushToStartToken.prefix(8))...")
            app.axiom?.emit("push_started", attributes: [
                "user": logID,
                "environment": environment.rawValue,
                "token_prefix": String(pushToStartToken.prefix(8)),
                "kind": "push_to_start",
            ])
        } catch let error as APNSCore.APNSError {
            app.logger.error("\(logID) push-to-start failed: \(error)")
            app.axiom?.emit("push_failed", attributes: [
                "user": logID,
                "environment": environment.rawValue,
                "token_prefix": String(pushToStartToken.prefix(8)),
                "kind": "push_to_start",
                "error_type": "apns",
                "apns_reason": error.reason?.reason ?? "unknown",
            ])
        } catch {
            app.logger.error("\(logID) Unexpected error sending push-to-start: \(error)")
            app.axiom?.emit("push_failed", attributes: [
                "user": logID,
                "environment": environment.rawValue,
                "token_prefix": String(pushToStartToken.prefix(8)),
                "kind": "push_to_start",
                "error_type": "other",
                "error": String(describing: type(of: error)),
            ])
        }
    }

    private func alert(
        for reading: GlucoseReading,
        lastReading: GlucoseReading?,
        preferences: LiveActivityPreferences?
    ) -> APNSAlertNotificationContent? {
        guard let lastReading, let preferences, preferences.alertsEnabled ?? true else {
            return nil
        }

        let (targetRange, unit) = (preferences.targetRange, preferences.unit)
        let isRapidTrend = reading.trend == .doubleDown || reading.trend == .doubleUp
        let didEnterOrLeaveTargetRange = targetRange.contains(reading.value) != targetRange.contains(lastReading.value)

        guard isRapidTrend || didEnterOrLeaveTargetRange else {
            return nil
        }

        let formattedValue = reading.value.formatted(.glucose(unit))
        let formattedLastValue = lastReading.value.formatted(.glucose(unit))

        let (title, body) = if reading.value > targetRange.upperBound {
            ("High Glucose", "Now \(formattedValue) and \(reading.trend.adjective ?? "rising"), was \(formattedLastValue).")
        } else if reading.value < targetRange.lowerBound {
            ("Low Glucose", "Now \(formattedValue) and \(reading.trend.adjective ?? "falling"), was \(formattedLastValue).")
        } else {
            ("Back in Range", "Now \(formattedValue) and \(reading.trend.adjective ?? "steady"), was \(formattedLastValue).")
        }

        return APNSAlertNotificationContent(
            title: .raw(title),
            subtitle: nil,
            body: .raw(body),
            launchImage: nil,
            sound: nil
        )
    }
}
