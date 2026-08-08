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
    // Which API the credentials are for. Optional for backwards compatibility —
    // older clients don't send it and are always Dexcom.
    var provider: CGMProvider?
    var accountID: UUID?
    var sessionID: UUID?
    // Optional for backwards compatibility on the wire: Dexcom clients always
    // send it; Libre clients have no account location.
    var accountLocation: AccountLocation?
    var duration: TimeInterval
    var preferences: LiveActivityPreferences?
    // Stable per-activity identity (ActivityKit's `Activity.id`). Sent on every call —
    // initial start and subsequent push-token updates — so a rotated token maps back to
    // the same activity. Required: clients are force-updated to always send it.
    var activityID: String

    // Push-to-start support. When the client opts in (experimental toggle), it sends the
    // device's push-to-start token plus the attributes needed to start a fresh activity.
    // The server uses these to auto-restart the activity on the same device when it ends
    // because the time limit was reached. All optional for backward compatibility.
    var pushToStartToken: String?
    var attributesType: String?      // e.g. "ReadingAttributes"
    var attributes: JSONValue?       // opaque, app-encoded ActivityAttributes (e.g. {"range": ...})
}

extension StartLiveActivityRequest {
    var logID: String { username.redactedEmailLogID }
}
