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
    static let minInterval: TimeInterval = 4
    static let maxInterval: TimeInterval = 60
    static let readingInterval: TimeInterval = 60 * 5 // 5 minutes
    static let offlineInterval: TimeInterval = 60 * 15 // 15 minutes — when a reading is considered offline
    static let minStaleDateBuffer: TimeInterval = 60 * 2 // floor on staleDate so it's never in the past or near-now
    // Tokens from clients on builds > unlimitedBuildThreshold get no expiry; older builds cap at maximumDuration.
    static let maximumDuration: TimeInterval = 60 * 60 * 4 // 4h
    static let unlimitedBuildThreshold = 297
    static let backoff: TimeInterval = 1.8
    static let errorBackoff: TimeInterval = 3
    static let decodingErrorRetryLimit = 10
    static let genericErrorRetryLimit = 6

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

    private func loadSession(app: Application, username: String) async throws -> LiveActivityPollSession? {
        let key = LiveActivityPollKeys.dataKey(for: username)
        guard let jsonString = try await app.redis.hget("data", from: key, as: String.self).get() else {
            return nil
        }
        return try JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8))
    }

    private func saveSession(app: Application, session: LiveActivityPollSession) async throws {
        let key = LiveActivityPollKeys.dataKey(for: session.username)
        let jsonData = try JSONEncoder().encode(session)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode session data as JSON string")
        }
        _ = try await app.redis.hset("data", to: jsonString, in: key).get()
    }

    private func removeSession(app: Application, username: String) async {
        _ = try? await app.redis.zrem(username, from: LiveActivityPollKeys.scheduleKey).get()
        _ = try? await app.redis.delete(LiveActivityPollKeys.dataKey(for: username)).get()
    }

    // MARK: - Session Processing

    private func processSession(username: String, app: Application, now: Date) async {
        do {
            guard var session = try await loadSession(app: app, username: username) else {
                app.logger.info("🗑️ Session \(username.prefix(8))... data not found, removing from schedule")
                await removeSession(app: app, username: username)
                return
            }

            // 1. Per-token expiry: remove tokens past maximumDuration, send end to each.
            // Tokens from clients on builds > unlimitedBuildThreshold are exempt and never expire here.
            var expiredTokens: [LiveActivityTokenEntry] = []
            session.tokens.removeAll { token in
                if let build = token.clientBuild, build > Self.unlimitedBuildThreshold {
                    return false
                }
                if now.timeIntervalSince(token.startDate) >= Self.maximumDuration {
                    expiredTokens.append(token)
                    return true
                }
                return false
            }

            for token in expiredTokens {
                app.logger.info("🕟 \(session.logID) Token \(token.pushToken.rawValue.prefix(8))... reached max duration")
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
                    "reason": "max_duration",
                ])
            }

            if session.tokens.isEmpty {
                app.logger.info("🛑 \(session.logID) All tokens expired, removing session")
                await removeSession(app: app, username: username)
                return
            }

            // 2. Poll Dexcom and process result
            await pollAndUpdate(app: app, session: &session, now: now)

        } catch {
            app.logger.error("Error processing session \(username.prefix(8))...: \(error)")
        }
    }

    private func pollAndUpdate(app: Application, session: inout LiveActivityPollSession, now: Date) async {
        let sessionCapture = SessionCapture()
        let client = DexcomClient(
            username: session.username,
            password: session.password,
            existingAccountID: session.accountID,
            existingSessionID: session.sessionID,
            accountLocation: session.accountLocation
        )
        await client.setDelegate(sessionCapture)

        do {
            app.logger.info("🔄 \(session.logID) Checking for new readings")
            let readings = try await client.getGlucoseReadings(
                duration: .init(value: 24, unit: .hours)
            ).sorted { $0.date < $1.date }

            guard let latestReading = readings.last else {
                app.logger.warning("🛑 \(session.logID) No readings available")
                app.axiom?.emit("poll_empty", attributes: [
                    "user": session.logID,
                    "retry_count": String(session.retryCount),
                    "minutes_since_last_reading": session.lastReadingDate.map { String(Int(now.timeIntervalSince($0) / 60)) } ?? "unknown",
                ])
                await sendStaleUpdatesIfNeeded(app: app, session: &session, now: now, reason: "No new readings")
                let nextPollInterval = min(session.pollInterval * Self.backoff, Self.maxInterval)
                await reschedule(
                    app: app,
                    session: &session,
                    pollInterval: nextPollInterval,
                    lastReading: session.lastReading,
                    readings: session.readings,
                    delay: session.pollInterval,
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
                    // Reading is overdue - poll with backoff
                    let nextPollInterval = min(session.pollInterval * Self.backoff, Self.maxInterval)
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

        let staleMinutes = Int(timeSinceLastReading / 60)
        let milestone: (minutes: Int, level: LiveActivityState.StaleLevel)? = if staleMinutes >= 15 {
            (15, .offline)
        } else if staleMinutes >= 10 {
            (10, .stale)
        } else if staleMinutes >= 5 {
            (5, .warning)
        } else {
            nil
        }

        guard let milestone, session.lastStaleUpdateMinutes != milestone.minutes else { return }

        app.logger.info("📡 \(session.logID) Sending stale update at \(milestone.minutes) minutes")
        session.lastStaleUpdateMinutes = milestone.minutes

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
                staleLevel: milestone.level,
                reason: reason,
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
                Self.rateLimitBackoff(retryCount: session.retryCount)
            } else {
                session.pollInterval
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

    /// Exponential backoff for HTTP 429 from Dexcom. Rate limits are per-account
    /// and the window often outlasts a 60s wait, so escalate aggressively.
    /// 120s → 240s → 480s → 600s (capped), with ±30s jitter.
    static func rateLimitBackoff(retryCount: Int) -> TimeInterval {
        let base: TimeInterval = 120
        let max: TimeInterval = 600
        let scaled = base * pow(2, Double(Swift.min(retryCount, 4)))
        let capped = Swift.min(scaled, max)
        return capped + TimeInterval.random(in: -30...30)
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
        let delay = timeUntilNextReading + 10 // give 10s to try to ensure reading is ready
        await reschedule(
            app: app,
            session: &session,
            pollInterval: Self.minInterval,
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
        }

        let nextTimestamp = Date().addingTimeInterval(delay).timeIntervalSince1970

        do {
            try await saveSession(app: app, session: session)

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
        }

        await removeSession(app: app, username: session.username)

        app.logger.info("🛑 \(session.logID) Session ended (\(session.tokens.count) tokens): \(reason.rawValue)")
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
                if let reason = error.reason,
                   reason == .badDeviceToken || reason == .unregistered || reason.reason == "ExpiredToken" {
                    app.logger.error("\(session.logID) Removing token \(tokenPrefix)... due to \(reason.reason)")
                    tokensToRemove.insert(token.pushToken)
                    willRemove = true
                }
                app.axiom?.emit("push_failed", attributes: [
                    "user": session.logID,
                    "environment": token.environment.rawValue,
                    "token_prefix": tokenPrefix,
                    "kind": "update",
                    "error_type": "apns",
                    "apns_reason": apnsReason,
                    "token_removed": willRemove ? "true" : "false",
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

        // Remove invalid tokens
        if !tokensToRemove.isEmpty {
            session.tokens.removeAll { tokensToRemove.contains($0.pushToken) }
        }

        if session.tokens.isEmpty {
            app.logger.info("🛑 \(session.logID) All tokens invalid, removing session")
            await removeSession(app: app, username: session.username)
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
            r: reason
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
                reason: reason
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
        tokenCount: Int? = nil
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
                dismissalDate: .none,
                staleDate: nil,
                apnsID: nil
            ),
            deviceToken: pushToken.rawValue
        )
    }

    private func alert(
        for reading: GlucoseReading,
        lastReading: GlucoseReading?,
        preferences: LiveActivityPreferences?
    ) -> APNSAlertNotificationContent? {
        guard let lastReading, let preferences else {
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
