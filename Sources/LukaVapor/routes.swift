import Vapor
import Dexcom
import APNS
import Queues
import Redis

func routes(_ app: Application) throws {
    app.get { req async in
        "Download Luka on the App Store."
    }

    app.post("end-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(EndLiveActivityRequest.self)

        // Build the key from the request
        let key: RedisKey
        if let username = body.username {
            key = RedisKey("live-activity:\(username)")
        } else if let pushToken = body.pushToken {
            key = RedisKey("live-activity:\(pushToken.rawValue)")
        } else {
            req.logger.error("Must provide username or pushToken")
            throw Abort(.badRequest, reason: "Must provide username or pushToken")
        }

        // Delete the key - job will see it's gone and stop rescheduling
        let count = try await req.redis.delete(key).get()
        req.logger.notice("🛑 Ended Live Activity \(count) session(s)")

        return .ok
    }

    app.post("start-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(StartLiveActivityRequest.self)

        // Generate unique job ID - any old jobs with different IDs will stop themselves
        let jobID = UUID()

        // Store the job ID (replaces any previous ID, invalidating old jobs)
        try await req.redis.set(LiveActivityJob.activeKey(for: body), to: jobID.uuidString).get()

        // Dispatch the job with initial payload
        let payload = LiveActivityJob.LiveActivityJobPayload(
            pushToken: body.pushToken,
            environment: body.environment,
            username: body.username,
            password: body.password,
            accountID: body.accountID,
            sessionID: body.sessionID,
            accountLocation: body.accountLocation,
            duration: body.duration,
            preferences: body.preferences,
            jobID: jobID,
            startDate: Date.now,
            lastReading: nil,
            pollInterval: 5
        )
        let dispatchTime = Date()
        try await req.queue.dispatch(LiveActivityJob.self, payload, maxRetryCount: 3)

        let timestamp = dispatchTime.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        req.logger.notice("🆕 \(body.logID) Started Live Activity polling, dispatched at \(timestamp)")

        return .ok
    }
}
