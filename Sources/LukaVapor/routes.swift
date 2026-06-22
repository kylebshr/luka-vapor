import Vapor
import Redis
import Dexcom

func routes(_ app: Application) throws {
    app.get { req async in
        "Download Luka on the App Store."
    }

    app.get("glucose-readings") { req async throws -> Response in
        // Return statuses directly rather than `throw Abort(...)`: clients poll this
        // endpoint constantly and a missing/not-yet-populated session is a normal,
        // expected outcome. Throwing routes the abort through ErrorMiddleware, which logs
        // a WARNING per request — drowning the logs. Returning a Response skips that.
        guard let auth = req.headers.basicAuthorization else {
            return Response(status: .unauthorized)
        }

        let dataKey = LiveActivityPollKeys.dataKey(for: auth.username)
        guard let jsonString = try await req.redis.hget("data", from: dataKey, as: String.self).get(),
              let session = try? JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8)),
              session.password == auth.password,
              let cached = session.readings, !cached.isEmpty
        else {
            return Response(status: .notFound)
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

        // Remove the matching entry by its stable activityID — the push token may have
        // rotated since the client last saw it, so it's not a reliable key.
        session.tokens.removeAll { $0.activityID == body.activityID }

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

        let tokenEntry = LiveActivityTokenEntry(
            pushToken: body.pushToken,
            environment: body.environment,
            preferences: body.preferences,
            startDate: Date.now,
            duration: body.duration,
            activityID: body.activityID,
            pushToStartToken: body.pushToStartToken,
            attributesType: body.attributesType,
            attributes: body.attributes
        )

        // Try to load an existing session for this username
        if let jsonString = try await req.redis.hget("data", from: dataKey, as: String.self).get(),
           var session = try? JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8)) {

            // Find the existing entry for this activity by its stable activityID, which
            // survives push-token rotation: a rotated token updates the existing entry
            // instead of creating a duplicate that resets the activity's lifetime.
            let existingIndex = session.tokens.firstIndex { $0.activityID == body.activityID }

            // Replace the existing entry or append a new one. When replacing, preserve the
            // original start date so the activity's lifetime isn't reset on every refresh —
            // only the push token and other fields are updated.
            if let index = existingIndex {
                session.tokens[index] = LiveActivityTokenEntry(
                    pushToken: tokenEntry.pushToken,
                    environment: tokenEntry.environment,
                    preferences: tokenEntry.preferences,
                    startDate: session.tokens[index].startDate,
                    duration: tokenEntry.duration,
                    activityID: tokenEntry.activityID,
                    // Take push-to-start info from the latest call verbatim (no fallback to the
                    // stored value): the client re-registers whenever its push-to-start token
                    // arrives or changes, so honoring exactly what it sends lets the user opt
                    // out — sending nil clears a previously stored token instead of pinning it.
                    pushToStartToken: tokenEntry.pushToStartToken,
                    attributesType: tokenEntry.attributesType,
                    attributes: tokenEntry.attributes
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

    // Debug-only: manually trigger a push-to-start restart for one activity (dismiss old,
    // start new) without waiting for the time limit. Returns 404 if no session/token is
    // found, and 422 if the token has no push-to-start info stored (e.g. the client never
    // opted in). The session is left untouched — the app's lifecycle observers re-register
    // the new activity, just like the real max-duration restart.
    app.post("restart-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(DebugRestartLiveActivityRequest.self)

        let dataKey = LiveActivityPollKeys.dataKey(for: body.username)
        guard let jsonString = try await req.redis.hget("data", from: dataKey, as: String.self).get() else {
            req.logger.warning("🔁 \(body.logID) No session found to restart")
            throw Abort(.notFound, reason: "No session found")
        }

        let session = try JSONDecoder().decode(LiveActivityPollSession.self, from: Data(jsonString.utf8))

        // Match the token by its stable activityID, the same way end-live-activity does.
        let token = session.tokens.first { $0.activityID == body.activityID }

        guard let token else {
            req.logger.warning("🔁 \(session.logID) No matching token to restart")
            throw Abort(.notFound, reason: "No matching token")
        }

        guard let pushToStartToken = token.pushToStartToken,
              let attributesType = token.attributesType,
              let attributes = token.attributes else {
            req.logger.warning("🔁 \(session.logID) Token has no push-to-start info")
            throw Abort(.unprocessableEntity, reason: "No push-to-start token for this activity")
        }

        req.logger.notice("🔁 \(session.logID) Debug restart via push-to-start")
        await LiveActivityScheduler.sendEndEvent(
            app: app,
            pushToken: token.pushToken,
            environment: token.environment,
            sessionStartDate: session.sessionStartDate,
            tokenStartDate: token.startDate,
            tokenCount: session.tokens.count,
            dismiss: true
        )
        await LiveActivityScheduler.sendStartEvent(
            app: app,
            pushToStartToken: pushToStartToken,
            environment: token.environment,
            attributesType: attributesType,
            attributes: attributes,
            logID: session.logID
        )

        return .ok
    }
}
