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

/// Redis key helpers for live activity storage
enum LiveActivityKeys {
    static let scheduleKey = RedisKey("live-activities:schedule")

    static func dataKey(for id: String) -> RedisKey {
        RedisKey("live-activity:data:\(id)")
    }
}

/// A scheduled job that runs every second to process due live activities.
/// Uses Redis sorted set for scheduling and hash for activity data.
struct LiveActivityScheduler: AsyncScheduledJob {
    static let minInterval: TimeInterval = 4
    static let maxInterval: TimeInterval = 60
    static let readingInterval: TimeInterval = 60 * 5 // 5 minutes
    static let maximumDuration: TimeInterval = 60 * 60 * 7.75 // 7h45m
    static let backoff: TimeInterval = 1.8
    static let errorBackoff: TimeInterval = 3

    func run(context: QueueContext) async throws {
        let app = context.application
        let now = Date()
        let nowTimestamp = now.timeIntervalSince1970

        // Query Redis sorted set for all activities due now or earlier
        let dueActivities = try await getDueActivities(app: app, beforeTimestamp: nowTimestamp)

        guard !dueActivities.isEmpty else { return }

        context.logger.info("📥 Dequeued activities (\(dueActivities.count))")

        for activityID in dueActivities {
            await processActivity(id: activityID, app: app, now: now)
        }
    }

    // MARK: - Redis Operations

    /// Queries for activities due for processing and immediately bumps their scores
    /// to prevent re-pickup by subsequent scheduler runs.
    ///
    /// We bump scores rather than removing entries because if processing crashes
    /// before `reschedule()` is called, the activity will still be retried after
    /// `maxInterval` seconds. Removing would orphan the activity permanently.
    private func getDueActivities(app: Application, beforeTimestamp: Double) async throws -> [String] {
        let results = try await app.redis.zrangebyscore(
            from: LiveActivityKeys.scheduleKey,
            withScoresBetween: (.inclusive(-.infinity), .inclusive(beforeTimestamp))
        ).get()

        let activityIDs = results.compactMap { String(fromRESP: $0) }

        // Bump scores to prevent re-pickup while processing.
        // Each activity will set its real next time via reschedule().
        let processingTimestamp = beforeTimestamp + Self.maxInterval
        for activityID in activityIDs {
            _ = try? await app.redis.zadd(
                (element: activityID, score: processingTimestamp),
                to: LiveActivityKeys.scheduleKey
            ).get()
        }

        return activityIDs
    }

    private func loadActivityData(app: Application, id: String) async throws -> LiveActivityData? {
        let key = LiveActivityKeys.dataKey(for: id)
        guard let jsonString = try await app.redis.hget("data", from: key, as: String.self).get() else {
            return nil
        }
        return try JSONDecoder().decode(LiveActivityData.self, from: Data(jsonString.utf8))
    }

    private func saveActivityData(app: Application, data: LiveActivityData) async throws {
        let key = LiveActivityKeys.dataKey(for: data.id)
        let jsonData = try JSONEncoder().encode(data)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode activity data as JSON string")
        }
        _ = try await app.redis.hset("data", to: jsonString, in: key).get()
    }

    private func removeFromSchedule(app: Application, id: String) async {
        _ = try? await app.redis.zrem(id, from: LiveActivityKeys.scheduleKey).get()
    }

    private func deleteActivityData(app: Application, id: String) async {
        _ = try? await app.redis.delete(LiveActivityKeys.dataKey(for: id)).get()
    }

    // MARK: - Activity Processing

    private func processActivity(id: String, app: Application, now: Date) async {
        do {
            // Load activity data from hash
            guard let data = try await loadActivityData(app: app, id: id) else {
                // Activity was deleted, remove from schedule
                await removeFromSchedule(app: app, id: id)
                return
            }

            // Check max duration
            if now.timeIntervalSince(data.startDate) >= Self.maximumDuration {
                app.logger.info("🕟 \(data.logID) Reached maximum duration, ending live activity")
                await endActivity(app: app, data: data, reason: .maxDuration)
                return
            }

            // Poll Dexcom and process result
            await pollAndUpdate(app: app, data: data, now: now)

        } catch {
            app.logger.error("Error processing activity \(id): \(error)")
        }
    }

    private func pollAndUpdate(app: Application, data: LiveActivityData, now: Date) async {
        let sessionCapture = SessionCapture()
        let client = DexcomClient(
            username: data.username,
            password: data.password,
            existingAccountID: data.accountID,
            existingSessionID: data.sessionID,
            accountLocation: data.accountLocation
        )
        await client.setDelegate(sessionCapture)

        do {
            // Fetch latest readings
            app.logger.info("🔄 \(data.logID) Checking for new readings")
            let readings = try await client.getGlucoseReadings(
                duration: .init(value: data.duration, unit: .seconds)
            ).sorted { $0.date < $1.date }

            guard let latestReading = readings.last else {
                app.logger.warning("🛑 \(data.logID) No readings available")
                let nextPollInterval = min(data.pollInterval * Self.backoff, Self.maxInterval)
                await reschedule(
                    app: app,
                    data: data,
                    pollInterval: nextPollInterval,
                    lastReading: data.lastReading,
                    delay: data.pollInterval,
                    sessionCapture: sessionCapture,
                    resetRetries: true
                )
                return
            }

            // Check if we have a new reading
            if let lastDate = data.lastReadingDate, latestReading.date <= lastDate {
                // No new reading yet
                let timeSinceLastReading = now.timeIntervalSince(lastDate)

                if timeSinceLastReading > Self.readingInterval {
                    // Reading is overdue, poll with backoff
                    let nextPollInterval = min(data.pollInterval * Self.backoff, Self.maxInterval)
                    await reschedule(
                        app: app,
                        data: data,
                        pollInterval: nextPollInterval,
                        lastReading: data.lastReading,
                        delay: data.pollInterval,
                        sessionCapture: sessionCapture,
                        resetRetries: false
                    )
                } else {
                    // Still within normal reading window, wait for next expected reading
                    await scheduleForNextReading(
                        app: app,
                        data: data,
                        now: now,
                        readingDate: lastDate,
                        reading: data.lastReading,
                        sessionCapture: sessionCapture
                    )
                }
                return
            }

            app.logger.info("✅ \(data.logID) New reading available - sending push")

            // Send push notification and schedule next poll (or end activity on fatal APNS error)
            await sendUpdateAndScheduleNext(
                app: app,
                data: data,
                now: now,
                readings: readings,
                latestReading: latestReading,
                sessionCapture: sessionCapture
            )

        } catch let error as DexcomClientError {
            // These errors are usually fatal.
            app.logger.error("\(data.logID) Ending polling due to DexcomClientError: \(error)")
            await endActivity(app: app, data: data, reason: .dexcomError)
        } catch let error as DexcomDecodingError {
            await handleDecodingError(app: app, data: data, error: error, sessionCapture: sessionCapture)
        } catch {
            await handleGenericError(app: app, data: data, error: error, sessionCapture: sessionCapture)
        }
    }

    // MARK: - Error Handling

    private func handleDecodingError(
        app: Application,
        data: LiveActivityData,
        error: DexcomDecodingError,
        sessionCapture: SessionCapture
    ) async {
        let bodyString = String(data: error.body, encoding: .utf8) ?? "<non-utf8 data, \(error.body.count) bytes>"
        let statusCode = error.statusCode?.description ?? "unknown"
        app.logger.error("🚫 \(data.logID) DexcomDecodingError status: \(statusCode) body: \(bodyString)")

        if data.pollInterval >= Self.maxInterval && data.retryCount > 5 {
            app.logger.error("🤬 \(data.logID) Done retrying due to errors, ending activity")
            await endActivity(app: app, data: data, reason: .tooManyRetries)
        } else {
            let nextPollInterval = min(data.pollInterval * Self.errorBackoff, Self.maxInterval)
            let delay = error.statusCode == 429 ? 60 + jitter() : data.pollInterval // wait a whole minute after a 429

            var updatedData = data
            updatedData.retryCount += 1

            await reschedule(
                app: app,
                data: updatedData,
                pollInterval: nextPollInterval,
                lastReading: data.lastReading,
                delay: delay,
                sessionCapture: sessionCapture,
                resetRetries: false
            )
        }
    }

    private func handleGenericError(
        app: Application,
        data: LiveActivityData,
        error: any Error,
        sessionCapture: SessionCapture
    ) async {
        app.logger.error("🚫 \(data.logID) Error polling for session: \(error)")

        if data.pollInterval >= Self.maxInterval && data.retryCount >= 3 {
            app.logger.error("🤬 \(data.logID) Done retrying due to errors, ending activity")
            await endActivity(app: app, data: data, reason: .tooManyRetries)
        } else {
            let nextPollInterval = min(data.pollInterval * Self.errorBackoff, Self.maxInterval)

            var updatedData = data
            updatedData.retryCount += 1

            await reschedule(
                app: app,
                data: updatedData,
                pollInterval: nextPollInterval,
                lastReading: data.lastReading,
                delay: data.pollInterval,
                sessionCapture: sessionCapture,
                resetRetries: false
            )
        }
    }

    private func jitter() -> TimeInterval {
        TimeInterval.random(in: -10...10)
    }

    // MARK: - Scheduling

    /// Schedules the next poll based on when the next Dexcom reading is expected.
    private func scheduleForNextReading(
        app: Application,
        data: LiveActivityData,
        now: Date,
        readingDate: Date,
        reading: GlucoseReading?,
        sessionCapture: SessionCapture
    ) async {
        let timeSinceReading = now.timeIntervalSince(readingDate)
        let timeUntilNextReading = Self.readingInterval - timeSinceReading
        let delay = max(timeUntilNextReading + Self.minInterval, Self.minInterval)
        await reschedule(
            app: app,
            data: data,
            pollInterval: Self.minInterval,
            lastReading: reading,
            delay: delay,
            sessionCapture: sessionCapture,
            resetRetries: true
        )
    }

    private func reschedule(
        app: Application,
        data: LiveActivityData,
        pollInterval: TimeInterval,
        lastReading: GlucoseReading?,
        delay: TimeInterval,
        sessionCapture: SessionCapture,
        resetRetries: Bool
    ) async {
        var updatedData = data
        updatedData.pollInterval = pollInterval
        updatedData.lastReading = lastReading
        updatedData.lastReadingDate = lastReading?.date
        updatedData.accountID = sessionCapture.accountID ?? data.accountID
        updatedData.sessionID = sessionCapture.sessionID ?? data.sessionID
        if resetRetries {
            updatedData.retryCount = 0
        }

        let nextTimestamp = Date().addingTimeInterval(delay).timeIntervalSince1970

        do {
            // Update data hash
            try await saveActivityData(app: app, data: updatedData)

            // Update schedule sorted set
            _ = try await app.redis.zadd(
                (element: data.id, score: nextTimestamp),
                to: LiveActivityKeys.scheduleKey
            ).get()

            let scheduledTime = Date(timeIntervalSince1970: nextTimestamp)
                .formatted(.dateTime.hour().minute().second())
            let formattedDelay = Duration.seconds(delay).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            app.logger.info("😴 \(data.logID) Scheduled for \(scheduledTime) (in \(formattedDelay))")
        } catch {
            app.logger.error("Failed to reschedule \(data.logID): \(error)")
        }
    }

    // MARK: - Activity Lifecycle

    private enum EndReason: String {
        case maxDuration
        case dexcomError
        case apnsInvalidToken
        case manualStop
        case tooManyRetries
    }

    private func endActivity(app: Application, data: LiveActivityData, reason: EndReason) async {
        // Send end event
        await sendEndEvent(app: app, data: data)

        // Remove from schedule
        await removeFromSchedule(app: app, id: data.id)

        // Delete data hash
        await deleteActivityData(app: app, id: data.id)

        app.logger.info("🛑 \(data.logID) Activity ended: \(reason.rawValue)")
    }

    // MARK: - APNS

    /// Sends a live activity update and schedules the next poll.
    /// On fatal APNS error (invalid token), ends the activity instead of scheduling.
    private func sendUpdateAndScheduleNext(
        app: Application,
        data: LiveActivityData,
        now: Date,
        readings: [GlucoseReading],
        latestReading: GlucoseReading,
        sessionCapture: SessionCapture
    ) async {
        let apnsClient = switch data.environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        let state = LiveActivityState(
            c: latestReading,
            h: readings.map { .init(t: $0.date, v: Int16($0.value)) }
        )

        do {
            let staleDate = Int(Date.now.addingTimeInterval(60 * 10).timeIntervalSince1970)
            try await apnsClient.sendLiveActivityNotification(
                .init(
                    expiration: .timeIntervalSince1970InSeconds(staleDate),
                    priority: .immediately,
                    appID: "com.kylebashour.Glimpse",
                    contentState: state,
                    event: .update,
                    alert: alert(for: latestReading, lastReading: data.lastReading, preferences: data.preferences),
                    timestamp: Int(Date.now.timeIntervalSince1970),
                    dismissalDate: .none,
                    staleDate: staleDate,
                    apnsID: nil
                ),
                deviceToken: data.pushToken.rawValue
            )
            app.logger.info("🚚 \(data.logID) Sent Live Activity push to \(data.pushToken.rawValue.prefix(8))")
        } catch let error as APNSCore.APNSError {
            app.logger.error("\(data.logID) APNS error: \(error)")
            // If token is invalid, stop polling
            if let reason = error.reason {
                if reason == .badDeviceToken || reason == .unregistered || reason.reason == "ExpiredToken" {
                    app.logger.error("\(data.logID) Live Activity ended because \(reason.reason), stopping polling")
                    await endActivity(app: app, data: data, reason: .apnsInvalidToken)
                    return
                }
            }
        } catch {
            app.logger.error("\(data.logID) Unexpected error sending push: \(error)")
        }

        // Schedule next poll
        await scheduleForNextReading(
            app: app,
            data: data,
            now: now,
            readingDate: latestReading.date,
            reading: latestReading,
            sessionCapture: sessionCapture
        )
    }

    private func sendEndEvent(app: Application, data: LiveActivityData) async {
        let apnsClient = switch data.environment {
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
            deviceToken: data.pushToken.rawValue
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
