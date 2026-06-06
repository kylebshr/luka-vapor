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
            try await LiveActivityPollKeys.removeSession(body.username, on: req.redis)
            req.logger.info("⏹️  \(session.logID) Ended last token, removed session")
        } else {
            // Save updated session
            try await LiveActivityPollKeys.saveSession(session, on: req.redis)
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

        try await LiveActivityPollKeys.removeSession(body.username, on: req.redis)

        req.logger.info("⏹️  \(session.logID) Ended all sessions (\(tokenCount) tokens removed)")

        return .ok
    }

    app.post("start-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(StartLiveActivityRequest.self)

        let dataKey = LiveActivityPollKeys.dataKey(for: body.username)

        let clientBuild = req.headers.first(name: "X-Luka-Build").flatMap(Int.init)

        let tokenEntry = LiveActivityTokenEntry(
            pushToken: body.pushToken,
            environment: body.environment,
            preferences: body.preferences,
            startDate: Date.now,
            duration: body.duration,
            clientBuild: clientBuild
        )

        // Try to load an existing session for this username
        if let jsonString = try await req.redis.hget("data", from: dataKey, as: String.self).get(),
           var session = try? JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8)) {

            // Replace existing token entry or append new one. When the push token is
            // unchanged, preserve its original start date so the activity's lifetime
            // isn't reset on every refresh — only its other fields are updated.
            if let index = session.tokens.firstIndex(where: { $0.pushToken == body.pushToken }) {
                session.tokens[index] = LiveActivityTokenEntry(
                    pushToken: tokenEntry.pushToken,
                    environment: tokenEntry.environment,
                    preferences: tokenEntry.preferences,
                    startDate: session.tokens[index].startDate,
                    duration: tokenEntry.duration,
                    clientBuild: tokenEntry.clientBuild
                )
            } else {
                session.tokens.append(tokenEntry)
            }

            // Update credentials to latest
            session.password = body.password
            session.accountID = body.accountID ?? session.accountID
            session.sessionID = body.sessionID ?? session.sessionID

            try await LiveActivityPollKeys.saveSession(session, on: req.redis)

            // Ensure a schedule entry exists. If a prior race or partial failure left this
            // session orphaned (data hash present, no schedule entry), the scheduler never
            // polls it and the activity gets stuck — NX heals it without disturbing an
            // already-scheduled score.
            _ = try await req.redis.zadd(
                (element: body.username, score: Date.now.timeIntervalSince1970),
                to: LiveActivityPollKeys.scheduleKey,
                inserting: .onlyNewElements
            ).get()

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

            try await LiveActivityPollKeys.saveSession(session, on: req.redis)

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
