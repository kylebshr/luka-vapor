import Vapor
import Redis
import Dexcom

// Returned by the activity-count endpoint; the type itself lives in the (Vapor-free) model.
extension LiveActivityPollKeys.ActivityCounts: Content {}

func routes(_ app: Application) throws {
    app.get { req async in
        "Download Luka on the App Store."
    }

    // Unauthenticated status: how many sessions are being polled, how many Live
    // Activities (one per device token) are currently running, and how many sessions
    // are currently backing off from a Dexcom rate limit. Browsers (Accept: text/html)
    // get a small dashboard; everything else keeps the original JSON shape.
    app.get("activity-count") { req async throws -> Response in
        let counts = try await LiveActivityPollKeys.countActivities(on: req.redis)

        // Exact type/subType match: HTTPMediaType's == does wildcard matching, which
        // would count curl's default `Accept: */*` as HTML and break JSON consumers.
        if req.headers.accept.contains(where: { $0.mediaType.type == "text" && $0.mediaType.subType == "html" }) {
            var headers = HTTPHeaders()
            headers.contentType = HTTPMediaType(type: "text", subType: "html", parameters: ["charset": "utf-8"])
            return Response(status: .ok, headers: headers, body: .init(string: StatusDashboard.html(for: counts)))
        }

        let response = Response(status: .ok)
        try response.content.encode(counts)
        return response
    }

    app.get("glucose-readings") { req async throws -> Response in
        // Return statuses directly rather than `throw Abort(...)`: clients poll this
        // endpoint constantly and a missing/not-yet-populated session is a normal,
        // expected outcome. Throwing routes the abort through ErrorMiddleware, which logs
        // a WARNING per request — drowning the logs. Returning a Response skips that.
        guard let auth = req.headers.basicAuthorization else {
            return Response(status: .unauthorized)
        }

        guard case .present(let session) = try await LiveActivityPollKeys.loadSession(for: auth.username, on: req.redis),
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

        // Remove just this device's token field — keyed by the stable activityID, since the
        // push token may have rotated since the client last saw it. The HDEL and the
        // "any tokens left?" teardown check run in one atomic script, so a device registering
        // concurrently can't be wrongly dropped or leave an orphan session behind.
        let removed = try await LiveActivityPollKeys.pruneSession(for: body.username, removingActivityID: body.activityID, on: req.redis)

        if removed {
            req.logger.info("⏹️  \(body.username.redactedEmailLogID) Ended last token, removed session")
        } else {
            req.logger.info("⏹️  \(body.username.redactedEmailLogID) Removed token")
        }
        // Client-initiated teardown was previously invisible in Axiom, so a session that
        // went quiet was indistinguishable from a scheduler bug. `session_removed` says
        // whether this call took the whole session down or just one device's token.
        app.axiom?.emit("session_ended", attributes: [
            "user": body.username.redactedEmailLogID,
            "reason": "client_end",
            "session_removed": removed ? "true" : "false",
            "activity_prefix": String(body.activityID.prefix(8)),
        ])

        return .ok
    }

    // Client-side lifecycle observations (activity appeared, token arrived, send failed,
    // app woke in the background, …), stamped with the device's own timestamps. Emitted as
    // `client_event` rows so they line up with `push_started` / `restart_registered` for
    // the same user. If a restart push is pending for this user, each row also carries how
    // long after that push the observation happened.
    app.post("client-event") { req async throws -> HTTPStatus in
        let body = try req.content.decode(ClientEventRequest.self)
        let now = Date.now
        let pending = try? await LiveActivityPollKeys.peekRestartPending(for: body.username, on: req.redis)
        let appVersion = req.headers.first(name: "X-Luka-Version") ?? "unknown"
        let appBuild = req.headers.first(name: "X-Luka-Build") ?? "unknown"
        let clientTime = ISO8601DateFormatter()
        clientTime.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var emitted = 0
        for event in body.events.prefix(ClientEventSanitizer.maxEvents) {
            guard let name = ClientEventSanitizer.name(event.name) else { continue }
            let occurredAt = Date(timeIntervalSince1970: event.occurredAt)

            var attributes = ClientEventSanitizer.attributes(event.attributes)
            attributes["user"] = body.logID
            attributes["client_event"] = name
            attributes["client_time"] = clientTime.string(from: occurredAt)
            attributes["client_lag_s"] = String(Int(now.timeIntervalSince(occurredAt)))
            attributes["app_version"] = appVersion
            attributes["app_build"] = appBuild
            attributes["os_version"] = body.systemVersion ?? "unknown"
            attributes["device_model"] = body.deviceModel ?? "unknown"
            if let activityID = event.activityID {
                attributes["activity_prefix"] = String(activityID.prefix(8))
            }
            if let pending {
                attributes["restart_source"] = pending.source
                attributes["since_restart_s"] = String(Int(occurredAt.timeIntervalSince(pending.sentAt)))
            }
            app.axiom?.emit("client_event", attributes: attributes)
            emitted += 1
        }

        req.logger.info("📱 \(body.logID) Recorded \(emitted) client event(s)")
        return .ok
    }

    app.post("end-live-activities") { req async throws -> HTTPStatus in
        let body = try req.content.decode(EndLiveActivitiesRequest.self)

        // Send an end push to every active token first — removeSession only deletes Redis
        // state, so without this the activities linger on-device until their own stale
        // timeout instead of being dismissed now. dismiss: true clears them immediately.
        if case .present(let session) = try? await LiveActivityPollKeys.loadSession(for: body.username, on: req.redis) {
            for token in session.tokens {
                await LiveActivityScheduler.sendEndEvent(
                    app: req.application,
                    pushToken: token.pushToken,
                    environment: token.environment,
                    dismiss: true
                )
            }
        }

        // Explicit "end everything for this user" — tear the whole session down.
        try await LiveActivityPollKeys.removeSession(body.username, on: req.redis)

        req.logger.info("⏹️  \(body.logID) Ended all sessions")
        app.axiom?.emit("session_ended", attributes: [
            "user": body.logID,
            "reason": "client_end_all",
            "session_removed": "true",
        ])

        return .ok
    }

    app.post("start-live-activity") { req async throws -> HTTPStatus in
        // A registration that fails here (undecodable body, Redis error) used to leave no
        // trace beyond a Fly log line, so an activity the user just started that never got
        // updates looked identical to one the app never registered. Surface it.
        do {
            return try await startLiveActivity(req, app: app)
        } catch {
            let username = (try? req.content.get(String.self, at: "username")) ?? ""
            let version = req.headers.first(name: "X-Luka-Version") ?? "unknown"
            req.logger.error("🆕 \(username.redactedEmailLogID) start-live-activity failed: \(error)")
            app.axiom?.emit("session_start_failed", attributes: [
                "user": username.isEmpty ? "unknown" : username.redactedEmailLogID,
                "app_version": version,
                "app_build": req.headers.first(name: "X-Luka-Build") ?? "unknown",
                "error_type": String(describing: type(of: error)),
                "error": String(String(describing: error).prefix(300)),
            ])
            throw error
        }
    }

    func startLiveActivity(_ req: Request, app: Application) async throws -> HTTPStatus {
        let body = try req.content.decode(StartLiveActivityRequest.self)

        let loaded = try await LiveActivityPollKeys.loadSession(for: body.username, on: req.redis)

        // Determine whether this is a brand-new session and, if the activity is
        // re-registering after a push-token rotation, find its original entry so we can
        // preserve the start date — otherwise the activity's lifetime would reset on every
        // refresh.
        let existingSession: LiveActivityPollSession?
        switch loaded {
        case .present(let session): existingSession = session
        case .missing, .undecodable: existingSession = nil
        }
        let existingToken = existingSession?.tokens.first { $0.activityID == body.activityID }

        // If a push-to-start restart was just sent for this user, this registration is the
        // device coming back from it. Consume the marker first so exactly one registration
        // is attributed to each restart.
        let pendingRestart = try? await LiveActivityPollKeys.takeRestartPending(for: body.username, on: req.redis)

        // Push-to-start token bookkeeping: which token the device currently advertises,
        // whether it differs from the last registration of this activity, and when it last
        // changed. A device whose restarts stopped landing after its token rotated shows up
        // here as a token that never changes while `push_started` keeps targeting it.
        let pushToStartPrefix = body.pushToStartToken.map { String($0.prefix(8)) } ?? "none"
        let launchedByPush = body.pushToStart.map { $0 ? "true" : "false" } ?? "unknown"
        let pushToStartChanged: String
        let pushToStartTokenUpdatedAt: Date
        if let existingToken {
            if existingToken.pushToStartToken == body.pushToStartToken {
                pushToStartChanged = "false"
                pushToStartTokenUpdatedAt = existingToken.pushToStartTokenUpdatedAt ?? existingToken.startDate
            } else {
                pushToStartChanged = "true"
                pushToStartTokenUpdatedAt = Date.now
            }
        } else if let pendingRestart, pendingRestart.pushToStartTokenPrefix == pushToStartPrefix {
            // Fresh activity after a restart carrying the same token: keep the token's
            // original age rather than resetting it on every 7-hour cycle.
            pushToStartChanged = "false"
            pushToStartTokenUpdatedAt = pendingRestart.pushToStartTokenUpdatedAt ?? pendingRestart.sentAt
        } else {
            pushToStartChanged = "none"
            pushToStartTokenUpdatedAt = Date.now
        }

        let tokenEntry = LiveActivityTokenEntry(
            pushToken: body.pushToken,
            environment: body.environment,
            preferences: body.preferences,
            // Preserve the original start date across push-token rotations (matched by
            // activityID); only a genuinely new activity starts its clock now.
            startDate: existingToken?.startDate ?? Date.now,
            duration: body.duration,
            activityID: body.activityID,
            // Push-to-start info is taken from this call verbatim so the client can opt out
            // by sending nil — there's no merge with a stored value.
            pushToStartToken: body.pushToStartToken,
            attributesType: body.attributesType,
            attributes: body.attributes,
            pushToStartTokenUpdatedAt: pushToStartTokenUpdatedAt
        )

        // Persist this device's token as its own field. Because it's an isolated HSET, a
        // second device registering at the same moment can't clobber it (the bug where one
        // of two simultaneous push-to-start registrations was silently dropped).
        try await LiveActivityPollKeys.saveCred(
            for: body.username,
            password: body.password,
            accountLocation: body.accountLocation,
            on: req.redis
        )
        try await LiveActivityPollKeys.saveToken(for: body.username, tokenEntry, on: req.redis)

        // A push-to-start token is per-device, so an existing entry sharing this one but
        // keyed by a different activityID is a stale activity that's been superseded on-device
        // by the one starting now. Drop those stale entries so the scheduler stops pushing
        // updates to an activity that no longer exists — otherwise a single device accrues
        // duplicate tokens and receives redundant pushes. Only the just-saved activityID is
        // kept; nil push-to-start tokens (opted-out clients) are never matched.
        let supersededIDs: [String] = body.pushToStartToken.map { pushToStartToken in
            (existingSession?.tokens ?? [])
                .filter { $0.pushToStartToken == pushToStartToken && $0.activityID != body.activityID }
                .map(\.activityID)
        } ?? []
        for activityID in supersededIDs {
            try await LiveActivityPollKeys.removeToken(for: body.username, activityID: activityID, on: req.redis)
        }
        if !supersededIDs.isEmpty {
            req.logger.info("🧹 \(body.logID) Removed \(supersededIDs.count) stale token(s) with same push-to-start token")
        }

        if existingSession == nil {
            // New session: seed the scheduler-owned polling state, then schedule immediately.
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
            try await LiveActivityPollKeys.saveState(for: body.username, from: session, on: req.redis)

            _ = try await req.redis.zadd(
                (element: body.username, score: Date.now.timeIntervalSince1970),
                to: LiveActivityPollKeys.scheduleKey
            ).get()

            req.logger.info("🆕 \(body.logID) Started new Live Activity session")
            app.axiom?.emit("session_started", attributes: [
                "user": body.logID,
                "environment": body.environment.rawValue,
                "token_prefix": String(body.pushToken.rawValue.prefix(8)),
                "kind": "new",
                "token_count": "1",
                "pts_prefix": pushToStartPrefix,
                "pts_changed": pushToStartChanged,
                "launched_by_push": launchedByPush,
            ])
        } else {
            // Existing session: don't touch the scheduler-owned state. Ensure a schedule
            // entry exists — if a prior race or partial failure left this session orphaned
            // (hash present, no schedule entry), the scheduler never polls it; NX heals it
            // without disturbing an already-scheduled score.
            _ = try await req.redis.zadd(
                (element: body.username, score: Date.now.timeIntervalSince1970),
                to: LiveActivityPollKeys.scheduleKey,
                inserting: .onlyNewElements
            ).get()

            // Token count is best-effort for logging — derived from the pre-write snapshot,
            // adjusted for the new token and any superseded entries just removed.
            let tokenCount = (existingToken == nil)
                ? (existingSession!.tokens.count + 1 - supersededIDs.count)
                : (existingSession!.tokens.count - supersededIDs.count)

            req.logger.info("🆕 \(body.logID) Added token to existing session (\(tokenCount) tokens)")
            app.axiom?.emit("session_started", attributes: [
                "user": body.logID,
                "environment": body.environment.rawValue,
                "token_prefix": String(body.pushToken.rawValue.prefix(8)),
                "kind": "token_added",
                "token_count": String(tokenCount),
                "pts_prefix": pushToStartPrefix,
                "pts_changed": pushToStartChanged,
                "launched_by_push": launchedByPush,
            ])
        }

        if let pendingRestart {
            let latency = Date.now.timeIntervalSince(pendingRestart.sentAt)
            req.logger.info("🔁 \(body.logID) Re-registered \(Int(latency))s after push-to-start restart")
            // The positive half of restart tracking: `push_started` says APNs accepted the
            // start push; this says the device actually relaunched and came back. A
            // `push_started` with no `restart_registered` is a restart the device dropped.
            app.axiom?.emit("restart_registered", attributes: [
                "user": body.logID,
                "environment": body.environment.rawValue,
                "kind": existingSession == nil ? "new" : "token_added",
                "source": pendingRestart.source,
                "latency_s": String(Int(latency)),
                "pts_prefix_sent": pendingRestart.pushToStartTokenPrefix,
                "pts_prefix_now": pushToStartPrefix,
                "launched_by_push": launchedByPush,
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

        guard case .present(let session) = try await LiveActivityPollKeys.loadSession(for: body.username, on: req.redis) else {
            req.logger.warning("🔁 \(body.logID) No session found to restart")
            throw Abort(.notFound, reason: "No session found")
        }

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
        let now = Date()
        let cachedReadings = session.readings ?? session.lastReading.map { [$0] } ?? []
        let cutoff = now.addingTimeInterval(-token.duration)
        let sent = await LiveActivityScheduler.sendStartEvent(
            app: app,
            pushToStartToken: pushToStartToken,
            environment: token.environment,
            attributesType: attributesType,
            attributes: attributes,
            latestReading: session.lastReading,
            readings: cachedReadings.filter { $0.date >= cutoff },
            sessionStartDate: session.sessionStartDate,
            tokenCount: session.tokens.count,
            pushToStartTokenUpdatedAt: token.pushToStartTokenUpdatedAt ?? token.startDate,
            now: now,
            logID: session.logID
        )
        if sent {
            try? await LiveActivityPollKeys.markRestartPending(
                for: body.username,
                .init(
                    sentAt: now,
                    pushToStartTokenPrefix: String(pushToStartToken.prefix(8)),
                    pushToStartTokenUpdatedAt: token.pushToStartTokenUpdatedAt ?? token.startDate,
                    environment: token.environment,
                    source: "debug"
                ),
                on: req.redis
            )
        }

        return .ok
    }
}
