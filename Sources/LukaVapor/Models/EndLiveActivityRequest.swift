//
//  EndLiveActivityRequest.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Foundation

struct EndLiveActivityRequest: Codable {
    var username: String
    // Stable per-activity identity (ActivityKit's `Activity.id`). The sole matching key —
    // the push token may have rotated since the client last saw it. Required: clients are
    // force-updated to always send it. (Clients still send `pushToken`; it's ignored.)
    var activityID: String
}

struct EndLiveActivitiesRequest: Codable {
    var username: String
}

extension EndLiveActivitiesRequest {
    var logID: String { username.redactedEmailLogID }
}
