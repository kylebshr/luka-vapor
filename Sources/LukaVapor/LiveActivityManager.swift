import Vapor
import Dexcom
import APNS
import APNSCore
import VaporAPNS
import Foundation

actor LiveActivityManager {
    private var activeSessions: [LiveActivityPushToken: Task<Void, Never>] = [:]

    func startPolling(
        request: StartLiveActivityRequest,
        app: Application
    ) {
        // Cancel existing session if present
        if let existingTask = activeSessions[request.pushToken] {
            existingTask.cancel()
            app.logger.info("\(request.logID) Cancelled session for existing token")
        }

        // Spawn background polling task
        let task = Task {
            await self.pollForUpdates(request: request, app: app)
        }

        activeSessions[request.pushToken] = task
        app.logger.info("\(request.logID) Started Live Activity polling")
    }

    func stopPolling(pushToken: LiveActivityPushToken, app: Application) {
        app.logger.info("Ending Live Activity session explicitly")

        if let task = activeSessions.removeValue(forKey: pushToken) {
            task.cancel()
            app.logger.debug("Stopped polling for token: \(pushToken)")
        } else {
            app.logger.debug("Not polling for token: \(pushToken)")
        }
    }

    private func pollForUpdates(
        request: StartLiveActivityRequest,
        app: Application
    ) async {
        var lastReadingDate: Date?

        let minInterval: TimeInterval = 2
        let maxInterval: TimeInterval = 60 // Cap at 60 seconds
        let readingInterval: TimeInterval = 60 * 5 // 5 minutes between readings
        var pollInterval: TimeInterval = minInterval

        // Send push notification
        let apnsClient = switch request.environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        nonisolated(unsafe) let client = DexcomClient(
            username: request.username,
            password: request.password,
            existingAccountID: request.accountID,
            existingSessionID: request.sessionID,
            accountLocation: request.accountLocation
        )

        while !Task.isCancelled {
            do {
                // Fetch latest readings
                let readings = try await client.getGlucoseReadings(
                    duration: .init(value: request.duration, unit: .seconds)
                ).sorted { $0.date < $1.date }

                guard let latestReading = readings.last else {
                    app.logger.warning("\(request.logID) No readings available")
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
                        app.logger.info("\(request.logID) Waiting for new reading - polling in \(pollInterval)s")
                        try await Task.sleep(for: .seconds(pollInterval))
                        pollInterval = min(pollInterval * 1.5, maxInterval)
                    } else {
                        // Still within normal reading window, wait for next expected reading
                        let timeUntilNextReading = readingInterval - timeSinceLastReading
                        app.logger.info("\(request.logID) Next reading expected in \(timeUntilNextReading)s, sleeping...")
                        try await Task.sleep(for: .seconds(max(timeUntilNextReading, minInterval) + 5)) // extra 5s to give time for reading to upload
                        pollInterval = minInterval // Reset backoff
                    }
                    continue
                }

                // New reading available!
                lastReadingDate = latestReading.date
                pollInterval = minInterval // Reset backoff

                app.logger.info("\(request.logID) New reading available, sending push")

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
                            staleDate: Int(Date.now.addingTimeInterval(60 * 10).timeIntervalSince1970),
                            apnsID: nil
                        ),
                        deviceToken: request.pushToken.rawValue
                    )
                    app.logger.info("\(request.logID) Sent Live Activity push")
                } catch let error as APNSCore.APNSError {
                    app.logger.error("\(request.logID) APNS error: \(error)")
                    // If token is invalid, stop polling
                    if let reason = error.reason {
                        // "ExpiredToken" is not yet supported by APNSWift
                        if reason == .badDeviceToken || reason == .unregistered || reason.reason == "ExpiredToken" {
                            app.logger.error("\(request.logID) Live Activity ended because \(reason.reason), stopping polling")
                            break
                        }
                    }
                } catch {
                    app.logger.error("\(request.logID) Unexpected error sending push: \(error)")
                }

                // Wait for next expected reading
                let timeSinceReading = Date.now.timeIntervalSince(latestReading.date)
                let timeUntilNextReading = readingInterval - timeSinceReading
                try await Task.sleep(for: .seconds(max(timeUntilNextReading, minInterval) + 5))
            } catch is CancellationError {
                app.logger.info("\(request.logID) Polling explicitly cancelled")
                break
            } catch let error as DexcomClientError {
                app.logger.error("\(request.logID) Ending polling due to DexcomClientError: \(error)")
                await sendEndEvent(apnsClient: apnsClient, pushToken: request.pushToken)
                break
            } catch {
                app.logger.error("\(request.logID) Error polling for session: \(error)")
                if pollInterval > maxInterval {
                    app.logger.error("\(request.logID) Done retrying due to errors, ending activity")
                    await sendEndEvent(apnsClient: apnsClient, pushToken: request.pushToken)
                    break
                } else {
                    app.logger.error("\(request.logID) Retrying in \(pollInterval)s")
                    // On error, use a more aggressive exponential backoff
                    try? await Task.sleep(for: .seconds(pollInterval))
                    pollInterval = min(pollInterval * 3, maxInterval)
                }
            }
        }

        cleanupSession(request.pushToken)
    }

    private func sendEndEvent(apnsClient: APNSGenericClient, pushToken: LiveActivityPushToken) async {
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

extension StartLiveActivityRequest {
    var logID: String {
        if let username {
            let parts = username.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return String(username.prefix(4)) }  // not a valid email

            let local = parts[0]
            let domain = parts[1]

            // Keep first character, replace the rest (if any) with dots
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
