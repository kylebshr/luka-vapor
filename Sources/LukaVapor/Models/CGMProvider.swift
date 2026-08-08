//
//  CGMProvider.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 8/8/26.
//

/// Which CGM sharing API a session polls. Stored with each session's
/// credentials; older clients and stored sessions don't send it, so a missing
/// value always means Dexcom.
enum CGMProvider: String, Codable, Sendable {
    case dexcom
    case libre
}
