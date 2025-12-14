//
//  File.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Foundation
import Dexcom

enum PushEnvironment: String, Codable {
    case development
    case production
}

struct StartLiveActivityRequest: Codable {
    var pushToken: LiveActivityPushToken
    var environment: PushEnvironment
    var username: String?
    var password: String?
    var accountID: UUID?
    var sessionID: UUID?
    var accountLocation: AccountLocation
    var duration: TimeInterval
}
