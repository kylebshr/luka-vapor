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
    static let minInterval: TimeInterval = 4
    static let maxInterval: TimeInterval = 60
    static let readingInterval: TimeInterval = 60 * 5 // 5 minutes
    static let maximumDuration: TimeInterval = 60 * 60 * 6 // 6h
    static let backoff: TimeInterval = 1.8
    static let errorBackoff: TimeInterval = 3

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

            // 1. Per-token expiry: remove tokens past maximumDuration, send end to each
            var expiredTokens: [LiveActivityTokenEntry] = []
            session.tokens.removeAll { token in
                if now.timeIntervalSince(token.startDate) >= Self.maximumDuration {
                    expiredTokens.append(token)
                    return true
                }
                return false
            }

            for token in expiredTokens {
                app.logger.info("🕟 \(session.logID) Token \(token.pushToken.rawValue.prefix(8))... reached max duration")
                await sendEndEvent(app: app, pushToken: token.pushToken, environment: token.environment)
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
        // Check if we should send stale updates (before fetching, so we send even if fetch fails)
        if let lastReadingDate = session.lastReadingDate, let lastReading = session.lastReading {
            let timeSinceLastReading = now.timeIntervalSince(lastReadingDate)
            if timeSinceLastReading >= Self.readingInterval {
                let staleMinutes = Int(timeSinceLastReading / 60)
                let milestone: Int? = staleMinutes >= 10 ? 10 : (staleMinutes >= 5 ? 5 : nil)

                if let milestone, session.lastStaleUpdateMinutes != milestone {
                    app.logger.info("📡 \(session.logID) Sending stale update at \(milestone) minutes")
                    session.lastStaleUpdateMinutes = milestone

                    let readings = session.readings ?? [lastReading]
                    // Send stale updates only to tokens that opted in
                    for token in session.tokens where token.preferences?.sendStaleUpdates == true {
                        await sendStaleUpdate(
                            app: app,
                            pushToken: token.pushToken,
                            environment: token.environment,
                            readings: readings,
                            latestReading: lastReading,
                            logID: session.logID
                        )
                    }
                }
            }
        }

        let sessionCapture = SessionCapture()
        let client = DexcomClient(
            username: session.username,
            password: session.password,
            existingAccountID: session.accountID,
            existingSessionID: session.sessionID,
            accountLocation: session.accountLocation
        )
        await client.setDelegate(sessionCapture)

        let maxDuration = session.tokens.map(\.duration).max() ?? 3600

        do {
            app.logger.info("🔄 \(session.logID) Checking for new readings")
            let readings = try await client.getGlucoseReadings(
                duration: .init(value: maxDuration, unit: .seconds)
            ).sorted { $0.date < $1.date }

            guard let latestReading = readings.last else {
                app.logger.warning("🛑 \(session.logID) No readings available")
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
            await endAllTokens(app: app, session: session, reason: .dexcomError)
        } catch let error as DexcomDecodingError {
            await handleDecodingError(app: app, session: &session, error: error, sessionCapture: sessionCapture)
        } catch {
            await handleGenericError(app: app, session: &session, error: error, sessionCapture: sessionCapture)
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

        if session.pollInterval >= Self.maxInterval && session.retryCount > 5 {
            app.logger.error("🤬 \(session.logID) Done retrying due to errors, ending all tokens")
            await endAllTokens(app: app, session: session, reason: .tooManyRetries)
        } else {
            let nextPollInterval = min(session.pollInterval * Self.errorBackoff, Self.maxInterval)
            let delay = error.statusCode == 429 ? 60 + jitter() : session.pollInterval

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

        if session.pollInterval >= Self.maxInterval && session.retryCount >= 3 {
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

    private func jitter() -> TimeInterval {
        TimeInterval.random(in: -10...10)
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
            session.lastStaleUpdateMinutes = nil
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
            await sendEndEvent(app: app, pushToken: token.pushToken, environment: token.environment)
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
            do {
                try await sendActivityPush(
                    app: app,
                    pushToken: token.pushToken,
                    environment: token.environment,
                    readings: readings,
                    latestReading: latestReading,
                    alert: alertContent
                )
                app.logger.info("🚚 \(session.logID) Sent push to \(token.pushToken.rawValue.prefix(8))...")
            } catch let error as APNSCore.APNSError {
                app.logger.error("\(session.logID) APNS error for \(token.pushToken.rawValue.prefix(8))...: \(error)")
                if let reason = error.reason,
                   reason == .badDeviceToken || reason == .unregistered || reason.reason == "ExpiredToken" {
                    app.logger.error("\(session.logID) Removing token \(token.pushToken.rawValue.prefix(8))... due to \(reason.reason)")
                    tokensToRemove.insert(token.pushToken)
                }
            } catch {
                app.logger.error("\(session.logID) Unexpected error sending push to \(token.pushToken.rawValue.prefix(8))...: \(error)")
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
        alert: APNSAlertNotificationContent? = nil
    ) async throws {
        let apnsClient = switch environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        let state = LiveActivityState(
            c: latestReading,
            h: readings.map { .init(t: $0.date, v: Int16($0.value)) }
        )

        let staleDate = Int(Date.now.addingTimeInterval(60 * 10).timeIntervalSince1970)
        try await apnsClient.sendLiveActivityNotification(
            .init(
                expiration: .timeIntervalSince1970InSeconds(staleDate),
                priority: .immediately,
                appID: "com.kylebashour.Glimpse",
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
        logID: String
    ) async {
        do {
            try await sendActivityPush(
                app: app,
                pushToken: pushToken,
                environment: environment,
                readings: readings,
                latestReading: latestReading
            )
            app.logger.info("🚚 \(logID) Sent stale update push to \(pushToken.rawValue.prefix(8))...")
        } catch {
            app.logger.error("\(logID) Error sending stale update to \(pushToken.rawValue.prefix(8))...: \(error)")
        }
    }

    private func sendEndEvent(app: Application, pushToken: LiveActivityPushToken, environment: PushEnvironment) async {
        let apnsClient = switch environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        _ = try? await apnsClient.sendLiveActivityNotification(
            .init(
                expiration: .none,
                priority: .immediately,
                appID: "com.kylebashour.Glimpse",
                contentState: LiveActivityState(c: nil, h: [], se: true),
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
