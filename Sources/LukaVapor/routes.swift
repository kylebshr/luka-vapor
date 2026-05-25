import Vapor
import Redis
import Dexcom

func routes(_ app: Application) throws {
    app.get { req async in
        "Download Luka on the App Store."
    }

    app.get("glucose-readings") { req async throws -> Response in
        guard let auth = req.headers.basicAuthorization else {
            throw Abort(.unauthorized)
        }

        let dataKey = LiveActivityPollKeys.dataKey(for: auth.username)
        guard let jsonString = try await req.redis.hget("data", from: dataKey, as: String.self).get(),
              let session = try? JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8)),
              session.password == auth.password,
              let cached = session.readings, !cached.isEmpty
        else {
            throw Abort(.notFound)
        }

        let minutes = (try? req.query.get(Int.self, at: "minutes")) ?? 1440
        let maxCount = (try? req.query.get(Int.self, at: "maxCount")) ?? 288
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(minutes) * 60)

        let filtered = cached
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
            .suffix(maxCount)

        req.logger.info("📤 \(session.logID) Served \(filtered.count) cached readings")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(Array(filtered))

        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: body))
    }

    app.post("end-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(EndLiveActivityRequest.self)

        let dataKey = LiveActivityPollKeys.dataKey(for: body.username)

        // Load existing session
        guard let jsonString = try await req.redis.hget("data", from: dataKey, as: String.self).get() else {
            req.logger.warning("⏹️  No session found for \(body.username.prefix(8))...")
            return .ok
        }

        var session = try JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8))

        // Remove the matching token
        session.tokens.removeAll { $0.pushToken == body.pushToken }

        if session.tokens.isEmpty {
            // No tokens left — clean up entirely
            _ = try await req.redis.zrem(body.username, from: LiveActivityPollKeys.scheduleKey).get()
            _ = try await req.redis.delete(dataKey).get()
            req.logger.info("⏹️  \(session.logID) Ended last token, removed session")
        } else {
            // Save updated session
            let jsonData = try JSONEncoder().encode(session)
            guard let updatedJSON = String(data: jsonData, encoding: .utf8) else {
                throw Abort(.internalServerError, reason: "Failed to encode session data")
            }
            _ = try await req.redis.hset("data", to: updatedJSON, in: dataKey).get()
            req.logger.info("⏹️  \(session.logID) Removed token, \(session.tokens.count) remaining")
        }

        return .ok
    }

    app.post("end-live-activities") { req async throws -> HTTPStatus in
        let body = try req.content.decode(EndLiveActivitiesRequest.self)

        let dataKey = LiveActivityPollKeys.dataKey(for: body.username)

        guard let jsonString = try await req.redis.hget("data", from: dataKey, as: String.self).get() else {
            req.logger.warning("⏹️  No session found for \(body.logID)")
            return .ok
        }

        let session = try JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8))
        let tokenCount = session.tokens.count

        _ = try await req.redis.zrem(body.username, from: LiveActivityPollKeys.scheduleKey).get()
        _ = try await req.redis.delete(dataKey).get()

        req.logger.info("⏹️  \(session.logID) Ended all sessions (\(tokenCount) tokens removed)")

        return .ok
    }

    app.post("start-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(StartLiveActivityRequest.self)

        let dataKey = LiveActivityPollKeys.dataKey(for: body.username)

        let tokenEntry = LiveActivityTokenEntry(
            pushToken: body.pushToken,
            environment: body.environment,
            preferences: body.preferences,
            startDate: Date.now,
            duration: body.duration
        )

        // Try to load an existing session for this username
        if let jsonString = try await req.redis.hget("data", from: dataKey, as: String.self).get(),
           var session = try? JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8)) {

            // Replace existing token entry or append new one
            if let index = session.tokens.firstIndex(where: { $0.pushToken == body.pushToken }) {
                session.tokens[index] = tokenEntry
            } else {
                session.tokens.append(tokenEntry)
            }

            // Update credentials to latest
            session.password = body.password
            session.accountID = body.accountID ?? session.accountID
            session.sessionID = body.sessionID ?? session.sessionID

            let jsonData = try JSONEncoder().encode(session)
            guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
                throw Abort(.internalServerError, reason: "Failed to encode session data")
            }
            _ = try await req.redis.hset("data", to: jsonStr, in: dataKey).get()

            req.logger.info("🆕 \(body.logID) Added token to existing session (\(session.tokens.count) tokens)")
            app.axiom?.emit("session_started", attributes: [
                "user": body.logID,
                "environment": body.environment.rawValue,
                "token_prefix": String(body.pushToken.rawValue.prefix(8)),
                "kind": "token_added",
                "token_count": String(session.tokens.count),
            ])
        } else {
            // Create new session
            let session = LiveActivityPollSession(
                username: body.username,
                password: body.password,
                accountID: body.accountID,
                sessionID: body.sessionID,
                accountLocation: body.accountLocation,
                tokens: [tokenEntry],
                sessionStartDate: Date.now,
                pollInterval: LiveActivityScheduler.minInterval,
                retryCount: 0
            )

            let jsonData = try JSONEncoder().encode(session)
            guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
                throw Abort(.internalServerError, reason: "Failed to encode session data")
            }
            _ = try await req.redis.hset("data", to: jsonStr, in: dataKey).get()

            // Add to schedule sorted set (immediate execution)
            let nowTimestamp = Date.now.timeIntervalSince1970
            _ = try await req.redis.zadd(
                (element: body.username, score: nowTimestamp),
                to: LiveActivityPollKeys.scheduleKey
            ).get()

            req.logger.info("🆕 \(body.logID) Started new Live Activity session")
            app.axiom?.emit("session_started", attributes: [
                "user": body.logID,
                "environment": body.environment.rawValue,
                "token_prefix": String(body.pushToken.rawValue.prefix(8)),
                "kind": "new",
                "token_count": "1",
            ])
        }

        return .ok
    }
}
