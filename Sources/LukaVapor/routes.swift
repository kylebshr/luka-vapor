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

        // Determine activity ID from request
        let activityID: String
        if let username = body.username {
            activityID = username
        } else if let pushToken = body.pushToken {
            activityID = pushToken.rawValue
        } else {
            req.logger.error("Must provide username or pushToken")
            throw Abort(.badRequest, reason: "Must provide username or pushToken")
        }

        // Remove from schedule sorted set
        _ = try await req.redis.zrem(activityID, from: LiveActivityKeys.scheduleKey).get()

        // Delete activity data hash
        _ = try await req.redis.delete(LiveActivityKeys.dataKey(for: activityID)).get()

        req.logger.notice("⏹️  Ended Live Activity for \(activityID.prefix(8))...")

        return .ok
    }

    app.post("start-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(StartLiveActivityRequest.self)

        let activityID = LiveActivityData.makeID(username: body.username, pushToken: body.pushToken)

        // Create activity data
        let data = LiveActivityData(
            id: activityID,
            pushToken: body.pushToken,
            environment: body.environment,
            accountLocation: body.accountLocation,
            duration: body.duration,
            username: body.username,
            password: body.password,
            accountID: body.accountID,
            sessionID: body.sessionID,
            preferences: body.preferences,
            startDate: Date.now,
            lastReadingDate: nil,
            lastReading: nil,
            pollInterval: LiveActivityScheduler.minInterval,
            retryCount: 0
        )

        // Store in Redis hash
        let dataKey = LiveActivityKeys.dataKey(for: activityID)
        let jsonData = try JSONEncoder().encode(data)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode activity data")
        }
        _ = try await req.redis.hset("data", to: jsonString, in: dataKey).get()

        // Add to schedule sorted set (immediate execution)
        let nowTimestamp = Date.now.timeIntervalSince1970
        _ = try await req.redis.zadd(
            (element: activityID, score: nowTimestamp),
            to: LiveActivityKeys.scheduleKey
        ).get()

        req.logger.notice("🆕 \(body.logID) Started Live Activity polling")

        return .ok
    }
}
