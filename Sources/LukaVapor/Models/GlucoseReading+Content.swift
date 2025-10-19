//
//  File.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Dexcom
import Vapor

extension GlucoseReading: @retroactive @unchecked Sendable {}
extension GlucoseReading: @retroactive Content {}
