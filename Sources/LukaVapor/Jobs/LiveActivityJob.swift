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

        // Job state
        let startDate: Date
        let lastReadingDate: Date?
        let pollInterval: TimeInterval
    }

    // Constants
    private static let minInterval: TimeInterval = 5
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

        // Check if this activity is still active (key exists)
        let isActive = try await app.redis.exists(Self.activeKey(for: payload)).get() > 0
        guard isActive else {
            app.logger.info("\(payload.logID) Live activity no longer active, stopping")
            return
        }

        // Check if max duration reached
        if Date.now.timeIntervalSince(payload.startDate) >= Self.maximumDuration {
            app.logger.info("\(payload.logID) Reached maximum duration, ending live activity")
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

        var nextPollInterval = payload.pollInterval
        var nextLastReadingDate = payload.lastReadingDate

        do {
            // Fetch latest readings
            app.logger.info("\(payload.logID) Fetching latest readings")
            let readings = try await client.getGlucoseReadings(
                duration: .init(value: payload.duration, unit: .seconds)
            ).sorted { $0.date < $1.date }

            guard let latestReading = readings.last else {
                app.logger.warning("\(payload.logID) No readings available")
                nextPollInterval = min(nextPollInterval * 1.5, Self.maxInterval)
                try await reschedule(context: context, payload: payload, pollInterval: nextPollInterval, lastReadingDate: nextLastReadingDate, delay: nextPollInterval, sessionCapture: sessionCapture)
                return
            }

            // Check if we have a new reading
            if let lastDate = payload.lastReadingDate, latestReading.date <= lastDate {
                // No new reading yet
                let timeSinceLastReading = Date.now.timeIntervalSince(lastDate)

                if timeSinceLastReading > Self.readingInterval {
                    // Reading is overdue, poll with backoff
                    app.logger.info("\(payload.logID) Waiting for new reading - polling in \(nextPollInterval)s")
                    nextPollInterval = min(nextPollInterval * 1.5, Self.maxInterval)
                    try await reschedule(context: context, payload: payload, pollInterval: nextPollInterval, lastReadingDate: nextLastReadingDate, delay: nextPollInterval, sessionCapture: sessionCapture)
                } else {
                    // Still within normal reading window, wait for next expected reading
                    let timeUntilNextReading = Self.readingInterval - timeSinceLastReading
                    let delay = max(timeUntilNextReading, Self.minInterval) + 5 // extra 5s buffer
                    app.logger.info("\(payload.logID) Next reading expected in \(timeUntilNextReading)s, sleeping...")
                    nextPollInterval = Self.minInterval // Reset backoff
                    try await reschedule(context: context, payload: payload, pollInterval: nextPollInterval, lastReadingDate: nextLastReadingDate, delay: delay, sessionCapture: sessionCapture)
                }
                return
            }

            // New reading available!
            nextLastReadingDate = latestReading.date
            nextPollInterval = Self.minInterval // Reset backoff

            app.logger.info("\(payload.logID) New reading available, sending push")

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
                        timestamp: Int(Date.now.timeIntervalSince1970),
                        dismissalDate: .none,
                        staleDate: staleDate,
                        apnsID: nil
                    ),
                    deviceToken: payload.pushToken.rawValue
                )
                app.logger.info("\(payload.logID) Sent Live Activity push")
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
            let delay = max(timeUntilNextReading, Self.minInterval) + 10
            try await reschedule(context: context, payload: payload, pollInterval: nextPollInterval, lastReadingDate: nextLastReadingDate, delay: delay, sessionCapture: sessionCapture)

        } catch let error as DexcomClientError {
            app.logger.error("\(payload.logID) Ending polling due to DexcomClientError: \(error)")
            await sendEndEvent(app: app, payload: payload)
            _ = try await app.redis.delete(Self.activeKey(for: payload)).get()
        } catch {
            app.logger.error("\(payload.logID) Error polling for session: \(error)")
            if nextPollInterval >= Self.maxInterval {
                app.logger.error("\(payload.logID) Done retrying due to errors, ending activity")
                await sendEndEvent(app: app, payload: payload)
                _ = try await app.redis.delete(Self.activeKey(for: payload)).get()
            } else {
                app.logger.error("\(payload.logID) Retrying in \(nextPollInterval)s")
                nextPollInterval = min(nextPollInterval * 3, Self.maxInterval)
                try await reschedule(context: context, payload: payload, pollInterval: nextPollInterval, lastReadingDate: nextLastReadingDate, delay: nextPollInterval, sessionCapture: sessionCapture)
            }
        }
    }

    private func reschedule(
        context: QueueContext,
        payload: LiveActivityJobPayload,
        pollInterval: TimeInterval,
        lastReadingDate: Date?,
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
            startDate: payload.startDate,
            lastReadingDate: lastReadingDate,
            pollInterval: pollInterval
        )
        try await context.queue.dispatch(
            LiveActivityJob.self,
            newPayload,
            delayUntil: Date().addingTimeInterval(delay)
        )
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
            return String(accountID.uuidString.prefix(4))
        } else {
            return "n/a"
        }
    }
}
