import Vapor
import Dexcom
import APNS
import APNSCore
import Foundation

actor LiveActivityManager {
    private var activeSessions: [UUID: Task<Void, Never>] = [:]

    func startPolling(
        sessionID: UUID,
        accountID: UUID,
        accountLocation: AccountLocation,
        pushToken: String,
        environment: PushEnvironment,
        duration: Int,
        app: Application
    ) {
        // Cancel existing session if present
        if let existingTask = activeSessions[sessionID] {
            existingTask.cancel()
            app.logger.info("Cancelled existing session: \(sessionID)")
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

        activeSessions[sessionID] = task
        app.logger.info("Started polling for session: \(sessionID)")
    }

    func stopPolling(sessionID: UUID, app: Application) {
        if let task = activeSessions.removeValue(forKey: sessionID) {
            task.cancel()
            app.logger.info("Stopped polling for session: \(sessionID)")
        } else {
            app.logger.info("Not polling for session: \(sessionID)")
        }
    }

    private func pollForUpdates(
        sessionID: UUID,
        accountID: UUID,
        accountLocation: AccountLocation,
        pushToken: String,
        environment: PushEnvironment,
        duration: Int,
        app: Application
    ) async {
        var lastReadingDate: Date?
        var pollInterval: TimeInterval = 5 // Start at 5 seconds
        let minInterval: TimeInterval = 5
        let maxInterval: TimeInterval = 60 // Cap at 60 seconds
        let readingInterval: TimeInterval = 60 * 5 // 5 minutes between readings

        while !Task.isCancelled {
            do {
                nonisolated(unsafe) let client = DexcomClient(
                    username: nil,
                    password: nil,
                    existingAccountID: accountID,
                    existingSessionID: sessionID,
                    accountLocation: accountLocation
                )

                // Fetch latest readings
                let readings = try await client.getGlucoseReadings(
                    duration: .init(value: Double(duration), unit: .hours)
                ).sorted { $0.date < $1.date }

                guard let latestReading = readings.last else {
                    app.logger.warning("No readings available for session: \(sessionID)")
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
                        app.logger.info("Waiting for new reading (last: \(lastDate), current: \(latestReading.date)) - polling in \(Int(pollInterval))s")
                        try await Task.sleep(for: .seconds(pollInterval))
                        pollInterval = min(pollInterval * 1.5, maxInterval)
                    } else {
                        // Still within normal reading window, wait for next expected reading
                        let timeUntilNextReading = readingInterval - timeSinceLastReading
                        app.logger.info("Next reading expected in \(Int(timeUntilNextReading))s for session: \(sessionID)")
                        try await Task.sleep(for: .seconds(max(timeUntilNextReading, minInterval)))
                        pollInterval = minInterval // Reset backoff
                    }
                    continue
                }

                // New reading available!
                lastReadingDate = latestReading.date
                pollInterval = minInterval // Reset backoff

                app.logger.info("New reading for session \(sessionID): \(latestReading.value) at \(latestReading.date)")

                // Build Live Activity state
                let state = LiveActivityState(
                    c: latestReading,
                    h: readings.map { .init(t: $0.date, v: Int16($0.value)) }
                )

                // Send push notification
                let apnsClient = switch environment {
                case .development: await app.apns.client(.development)
                case .production: await app.apns.client(.production)
                }

                do {
                    try await apnsClient.sendLiveActivityNotification(
                        .init(
                            expiration: .immediately,
                            priority: .immediately,
                            appID: "com.kylebashour.Glimpse",
                            contentState: state,
                            event: .update,
                            timestamp: Int(Date.now.timeIntervalSince1970),
                            dismissalDate: .none,
                            apnsID: nil
                        ),
                        deviceToken: pushToken
                    )
                    app.logger.info("Sent Live Activity update for session: \(sessionID)")
                } catch let error as APNSCore.APNSError {
                    app.logger.error("APNS error for session \(sessionID): \(error)")
                    // If token is invalid, stop polling
                    if error.reason == .badDeviceToken || error.reason == .unregistered {
                        app.logger.warning("Live Activity ended, stopping polling for session: \(sessionID)")
                        break
                    }
                } catch {
                    app.logger.error("Unexpected error sending push for session \(sessionID): \(error)")
                }
            } catch is CancellationError {
                app.logger.info("Polling cancelled for session: \(sessionID)")
                break
            } catch {
                app.logger.error("Error polling for session \(sessionID): \(error)")
                // On error, use backoff before retrying
                try? await Task.sleep(for: .seconds(pollInterval))
                pollInterval = min(pollInterval * 1.5, maxInterval)
            }
        }

        self.cleanupSession(sessionID)
    }

    private func cleanupSession(_ sessionID: UUID) {
        activeSessions.removeValue(forKey: sessionID)
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
