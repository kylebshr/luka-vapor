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
}

extension StartLiveActivityRequest {
    var logID: String { username.redactedEmailLogID }
}
