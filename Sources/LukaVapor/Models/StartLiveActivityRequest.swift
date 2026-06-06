//
//  File.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Foundation
import Dexcom

enum PushEnvironment: String, Codable, Sendable {
    case development
    case production
}

struct LiveActivityPreferences: Codable {
    var targetRange: ClosedRange<Int>
    var unit: GlucoseFormatter.Unit
    // Optional for backwards compatibility — older clients/stored entries won't have it.
    // nil is treated as alerts-enabled.
    var alertsEnabled: Bool?
}

struct StartLiveActivityRequest: Codable, Sendable {
    var pushToken: LiveActivityPushToken
    var environment: PushEnvironment
    var username: String
    var password: String
    var accountID: UUID?
    var sessionID: UUID?
    var accountLocation: AccountLocation
    var duration: TimeInterval
    var preferences: LiveActivityPreferences?
    // Stable per-activity identity (ActivityKit's `Activity.id`). Sent on every call —
    // initial start and subsequent push-token updates — so a rotated token maps back to
    // the same activity. Optional for older clients that don't send it yet.
    var activityID: String?
}

extension StartLiveActivityRequest {
    var logID: String { username.redactedEmailLogID }
}
