import Vapor
import Dexcom
import APNS
import APNSCore
import Foundation

actor LiveActivityManager {
    private var activeSessions: [LiveActivityPushToken: Task<Void, Never>] = [:]

    func startPolling(
        sessionID: UUID,
        accountID: UUID,
        accountLocation: AccountLocation,
        pushToken: LiveActivityPushToken,
        environment: PushEnvironment,
        duration: TimeInterval,
        app: Application
    ) {
        // Cancel existing session if present
        if let existingTask = activeSessions[pushToken] {
            existingTask.cancel()
            app.logger.debug("Cancelled existing session: \(sessionID) token: \(pushToken)")
        }

        // Spawn background polling task
        let task = Task {
            await self.pollForUpdates(
                sessionID: sessionID,
                accountID: accountID,
                accountLocation: accountLocation,
                pushToken: pushToken,
                environment: environment,
                duration: duration,
                app: app
            )
        }

        activeSessions[pushToken] = task
        app.logger.info("Started Live Activity polling")
    }

    func stopPolling(pushToken: LiveActivityPushToken, app: Application) {
        if let task = activeSessions.removeValue(forKey: pushToken) {
            task.cancel()
            app.logger.debug("Stopped polling for token: \(pushToken)")
        } else {
            app.logger.debug("Not polling for token: \(pushToken)")
        }
    }

    private func pollForUpdates(
        sessionID: UUID,
        accountID: UUID,
        accountLocation: AccountLocation,
        pushToken: LiveActivityPushToken,
        environment: PushEnvironment,
        duration: TimeInterval,
        app: Application
    ) async {
        var lastReadingDate: Date?
        var pollInterval: TimeInterval = 5 // Start at 5 seconds
        let minInterval: TimeInterval = 5
        let maxInterval: TimeInterval = 60 // Cap at 60 seconds
        let readingInterval: TimeInterval = 60 * 5 // 5 minutes between readings

        // Send push notification
        let apnsClient = switch environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        nonisolated(unsafe) let client = DexcomClient(
            username: nil,
            password: nil,
            existingAccountID: accountID,
            existingSessionID: sessionID,
            accountLocation: accountLocation
        )

        while !Task.isCancelled {
            do {
                // Fetch latest readings
                let readings = try await client.getGlucoseReadings(
                    duration: .init(value: duration, unit: .seconds)
                ).sorted { $0.date < $1.date }

                guard let latestReading = readings.last else {
                    app.logger.warning("No readings available for session: \(sessionID) token: \(pushToken)")
                    try await Task.sleep(for: .seconds(pollInterval))
                    pollInterval = min(pollInterval * 1.5, maxInterval)
                    continue
                }

                // Check if we have a new reading
                if let lastDate = lastReadingDate, latestReading.date <= lastDate {
                    // No new reading yet - exponential backoff
                    let timeSinceLastReading = Date.now.timeIntervalSince(lastDate)

                    if timeSinceLastReading > readingInterval {
                        // Reading is overdue, increase polling frequency with backoff
                        app.logger.debug("Waiting for new reading (last: \(lastDate), current: \(latestReading.date)) - polling in \(Int(pollInterval))s")
                        try await Task.sleep(for: .seconds(pollInterval))
                        pollInterval = min(pollInterval * 1.5, maxInterval)
                    } else {
                        // Still within normal reading window, wait for next expected reading
                        let timeUntilNextReading = readingInterval - timeSinceLastReading
                        app.logger.debug("Next reading expected in \(Int(timeUntilNextReading))s for session: \(sessionID) token: \(pushToken)")
                        try await Task.sleep(for: .seconds(max(timeUntilNextReading, minInterval)))
                        pollInterval = minInterval // Reset backoff
                    }
                    continue
                }

                // New reading available!
                lastReadingDate = latestReading.date
                pollInterval = minInterval // Reset backoff

                app.logger.debug("New reading for session \(sessionID): \(latestReading.value) at \(latestReading.date)")

                // Build Live Activity state
                let state = LiveActivityState(
                    c: latestReading,
                    h: readings.map { .init(t: $0.date, v: Int16($0.value)) }
                )

                do {
                    try await apnsClient.sendLiveActivityNotification(
                        .init(
                            expiration: .none,
                            priority: .immediately,
                            appID: "com.kylebashour.Glimpse",
                            contentState: state,
                            event: .update,
                            timestamp: Int(Date.now.timeIntervalSince1970),
                            dismissalDate: .none,
                            staleDate: Int(Date.now.addingTimeInterval(60 * 7).timeIntervalSince1970),
                            apnsID: nil
                        ),
                        deviceToken: pushToken.rawValue
                    )
                    app.logger.debug("Sent Live Activity update for session: \(sessionID) token: \(pushToken)")
                } catch let error as APNSCore.APNSError {
                    app.logger.error("APNS error for session \(sessionID): \(error)")
                    // If token is invalid, stop polling
                    if let reason = error.reason {
                        if reason == .badDeviceToken || error.reason == .unregistered {
                            app.logger.warning("Live Activity ended because \(reason.reason), stopping polling for session: \(sessionID) token: \(pushToken)")
                            break
                        }
                    }
                } catch {
                    app.logger.error("Unexpected error sending push for session \(sessionID): \(error)")
                }
            } catch is CancellationError {
                app.logger.debug("Polling cancelled for session: \(sessionID) token: \(pushToken)")
                break
            } catch let error as DexcomClientError {
                app.logger.error("Ending polling due to DexcomClientError: \(error)")

                _ = try? await apnsClient.sendLiveActivityNotification(
                    .init(
                        expiration: .none,
                        priority: .immediately,
                        appID: "com.kylebashour.Glimpse",
                        contentState: LiveActivityState(c: nil, h: []),
                        event: .update,
                        timestamp: Int(Date.now.timeIntervalSince1970),
                        dismissalDate: .immediately,
                        staleDate: nil,
                        apnsID: nil
                    ),
                    deviceToken: pushToken.rawValue
                )

                break
            } catch {
                app.logger.error("Error polling for session \(sessionID): \(error)")
                // On error, use backoff before retrying
                try? await Task.sleep(for: .seconds(pollInterval))
                pollInterval = min(pollInterval * 1.5, maxInterval)
            }
        }

        self.cleanupSession(pushToken)
    }

    private func cleanupSession(_ pushToken: LiveActivityPushToken) {
        activeSessions.removeValue(forKey: pushToken)
    }
}

// Extension to store manager in Application
extension Application {
    private struct LiveActivityManagerKey: StorageKey {
        typealias Value = LiveActivityManager
    }

    var liveActivityManager: LiveActivityManager {
        get {
            if let existing = self.storage[LiveActivityManagerKey.self] {
                return existing
            }
            let new = LiveActivityManager()
            self.storage[LiveActivityManagerKey.self] = new
            return new
        }
        set {
            self.storage[LiveActivityManagerKey.self] = newValue
        }
    }
}
