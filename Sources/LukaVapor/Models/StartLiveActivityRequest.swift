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
    var pushToken: String
    var environment: PushEnvironment
    var accountID: UUID
    var sessionID: UUID
    var accountLocation: AccountLocation
    var durationHours: Int
}
