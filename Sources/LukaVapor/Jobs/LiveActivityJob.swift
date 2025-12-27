import FoundationNetworking
import Vapor
import Queues
import Redis
@preconcurrency import Dexcom
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

struct LiveActivityJob: AsyncJob {
    typealias Payload = LiveActivityJobPayload

    struct LiveActivityJobPayload: Codable, Sendable {
        // From StartLiveActivityRequest
        let pushToken: LiveActivityPushToken
        let environment: PushEnvironment
        let username: String?
        let password: String?
        let accountID: UUID?
        let sessionID: UUID?
        let accountLocation: AccountLocation
        let duration: TimeInterval
        let preferences: LiveActivityPreferences?

        // Job state
        let jobID: UUID  // Unique ID to prevent duplicate jobs
        let startDate: Date
        let lastReading: GlucoseReading?
        let pollInterval: TimeInterval

        var lastReadingDate: Date? {
            lastReading?.date
        }
    }

    // Constants
    private static let minInterval: TimeInterval = 3
    private static let maxInterval: TimeInterval = 60
    private static let readingInterval: TimeInterval = 60 * 5 // 5 minutes
    private static let maximumDuration: TimeInterval = 60 * 60 * 7.5 // 7.5 hours

    static func activeKey(for payload: LiveActivityJobPayload) -> RedisKey {
        let id = payload.username ?? payload.pushToken.rawValue
        return RedisKey("live-activity:\(id)")
    }

    static func activeKey(for request: StartLiveActivityRequest) -> RedisKey {
        let id = request.username ?? request.pushToken.rawValue
        return RedisKey("live-activity:\(id)")
    }

    func dequeue(_ context: QueueContext, _ payload: LiveActivityJobPayload) async throws {
        let app = context.application

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        app.logger.notice("🔔 \(payload.logID) Job dequeued at \(formatter.string(from: Date()))")

        // Check if this job's ID matches the current active job ID
        // This prevents duplicate jobs when a new activity starts before the old one's jobs finish
        let currentJobID = try await app.redis.get(Self.activeKey(for: payload), as: String.self).get()
        guard currentJobID == payload.jobID.uuidString else {
            app.logger.notice("🛑 \(payload.logID) Job ID mismatch (stale job), stopping")
            return
        }

        // Check if max duration reached
        if Date.now.timeIntervalSince(payload.startDate) >= Self.maximumDuration {
            app.logger.notice("🕔 \(payload.logID) Reached maximum duration, ending live activity")
            await sendEndEvent(app: app, payload: payload)
            _ = try await app.redis.delete(Self.activeKey(for: payload)).get()
            return
        }

        // Get APNS client
        let apnsClient = switch payload.environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        // Create Dexcom client
        let sessionCapture = SessionCapture()
        nonisolated(unsafe) let client = DexcomClient(
            username: payload.username,
            password: payload.password,
            existingAccountID: payload.accountID,
            existingSessionID: payload.sessionID,
            accountLocation: payload.accountLocation
        )
        client.delegate = sessionCapture

        do {
            // Fetch latest readings
            app.logger.notice("☁️  \(payload.logID) Fetching latest readings")
            let readings = try await client.getGlucoseReadings(
                duration: .init(value: payload.duration, unit: .seconds)
            ).sorted { $0.date < $1.date }

            guard let latestReading = readings.last else {
                app.logger.warning("🚫 \(payload.logID) No readings available")
                let nextPollInterval = min(payload.pollInterval * 1.5, Self.maxInterval)
                try await reschedule(
                    context: context,
                    payload: payload,
                    pollInterval: nextPollInterval,
                    lastReading: payload.lastReading,
                    delay: payload.pollInterval,
                    sessionCapture: sessionCapture
                )
                return
            }

            // Check if we have a new reading
            if let lastDate = payload.lastReadingDate, latestReading.date <= lastDate {
                // No new reading yet
                let timeSinceLastReading = Date.now.timeIntervalSince(lastDate)

                if timeSinceLastReading > Self.readingInterval {
                    // Reading is overdue, poll with backoff
                    let nextPollInterval = min(payload.pollInterval * 1.5, Self.maxInterval)
                    try await reschedule(
                        context: context,
                        payload: payload,
                        pollInterval: nextPollInterval,
                        lastReading: payload.lastReading,
                        delay: payload.pollInterval,
                        sessionCapture: sessionCapture
                    )
                } else {
                    // Still within normal reading window, wait for next expected reading
                    let timeUntilNextReading = Self.readingInterval - timeSinceLastReading
                    let delay = max(timeUntilNextReading + 2, Self.minInterval) // extra 2s buffer
                    try await reschedule(
                        context: context,
                        payload: payload,
                        pollInterval: Self.minInterval,
                        lastReading: payload.lastReading,
                        delay: delay,
                        sessionCapture: sessionCapture
                    )
                }
                return
            }

            app.logger.notice("✅ \(payload.logID) New reading available - sending push")

            // Build Live Activity state
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
                        alert: alert(
                            context,
                            for: latestReading,
                            lastReading: payload.lastReading,
                            preferences: payload.preferences
                        ),
                        timestamp: Int(Date.now.timeIntervalSince1970),
                        dismissalDate: .none,
                        staleDate: staleDate,
                        apnsID: nil
                    ),
                    deviceToken: payload.pushToken.rawValue
                )
                app.logger.notice("🚚 \(payload.logID) Sent Live Activity push to \(payload.pushToken.rawValue.prefix(8))")
            } catch let error as APNSCore.APNSError {
                app.logger.error("\(payload.logID) APNS error: \(error)")
                // If token is invalid, stop polling
                if let reason = error.reason {
                    if reason == .badDeviceToken || reason == .unregistered || reason.reason == "ExpiredToken" {
                        app.logger.error("\(payload.logID) Live Activity ended because \(reason.reason), stopping polling")
                        _ = try await app.redis.delete(Self.activeKey(for: payload)).get()
                        return
                    }
                }
            } catch {
                app.logger.error("\(payload.logID) Unexpected error sending push: \(error)")
            }

            // Wait for next expected reading
            let timeSinceReading = Date.now.timeIntervalSince(latestReading.date)
            let timeUntilNextReading = Self.readingInterval - timeSinceReading
            let delay = max(timeUntilNextReading + Self.minInterval, Self.minInterval)
            try await reschedule(
                context: context,
                payload: payload,
                pollInterval: Self.minInterval,
                lastReading: latestReading,
                delay: delay,
                sessionCapture: sessionCapture
            )
        } catch let error as DexcomClientError {
            app.logger.error("\(payload.logID) Ending polling due to DexcomClientError: \(error)")
            await sendEndEvent(app: app, payload: payload)
            _ = try await app.redis.delete(Self.activeKey(for: payload)).get()
        } catch let error as DexcomDecodingError {
            let bodyString = String(data: error.body, encoding: .utf8) ?? "<non-utf8 data, \(error.body.count) bytes>"
            let httpResponse = error.response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode.description ?? "unknown"
            let url = error.response.url?.absoluteString ?? "unknown"
            app.logger.error("""
                \(payload.logID) 🤬 DexcomDecodingError: \(error.error)
                  URL: \(url)
                  Status: \(statusCode)
                  Body: \(bodyString)
                """)
            if payload.pollInterval >= Self.maxInterval {
                app.logger.error("\(payload.logID) Done retrying due to errors, ending activity")
                await sendEndEvent(app: app, payload: payload)
                _ = try await app.redis.delete(Self.activeKey(for: payload)).get()
            } else {
                let nextPollInterval = min(payload.pollInterval * 3, Self.maxInterval)
                try await reschedule(
                    context: context,
                    payload: payload,
                    pollInterval: nextPollInterval,
                    lastReading: payload.lastReading,
                    delay: payload.pollInterval,
                    sessionCapture: sessionCapture
                )
            }
        } catch {
            app.logger.error("\(payload.logID) Error polling for session: \(error)")
            if payload.pollInterval >= Self.maxInterval {
                app.logger.error("\(payload.logID) Done retrying due to errors, ending activity")
                await sendEndEvent(app: app, payload: payload)
                _ = try await app.redis.delete(Self.activeKey(for: payload)).get()
            } else {
                let nextPollInterval = min(payload.pollInterval * 3, Self.maxInterval)
                try await reschedule(
                    context: context,
                    payload: payload,
                    pollInterval: nextPollInterval,
                    lastReading: payload.lastReading,
                    delay: payload.pollInterval,
                    sessionCapture: sessionCapture
                )
            }
        }
    }

    private func alert(
        _ context: QueueContext,
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

        context.logger.notice("🔔 Sending an alert in the payload")

        return APNSAlertNotificationContent(
            title: .raw(title),
            subtitle: nil,
            body: .raw(body),
            launchImage: nil,
            sound: nil
        )
    }

    private func reschedule(
        context: QueueContext,
        payload: LiveActivityJobPayload,
        pollInterval: TimeInterval,
        lastReading: GlucoseReading?,
        delay: TimeInterval,
        sessionCapture: SessionCapture
    ) async throws {
        let newPayload = LiveActivityJobPayload(
            pushToken: payload.pushToken,
            environment: payload.environment,
            username: payload.username,
            password: payload.password,
            accountID: sessionCapture.accountID ?? payload.accountID,
            sessionID: sessionCapture.sessionID ?? payload.sessionID,
            accountLocation: payload.accountLocation,
            duration: payload.duration,
            preferences: payload.preferences,
            jobID: payload.jobID,
            startDate: payload.startDate,
            lastReading: lastReading,
            pollInterval: pollInterval
        )

        let scheduledTime = Date().addingTimeInterval(delay)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        try await context.queue.dispatch(
            LiveActivityJob.self,
            newPayload,
            maxRetryCount: 3,
            delayUntil: scheduledTime
        )

        context.application.logger.notice("😴 \(payload.logID) Scheduled for \(formatter.string(from: scheduledTime)) (in \(delay)s)")
    }

    private func sendEndEvent(app: Application, payload: LiveActivityJobPayload) async {
        let apnsClient = switch payload.environment {
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
            deviceToken: payload.pushToken.rawValue
        )
    }
}

extension LiveActivityJob.LiveActivityJobPayload {
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

