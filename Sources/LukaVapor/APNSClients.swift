//
//  APNSClients.swift
//  LukaVapor
//
//  Created by Claude on 9/12/26.
//

import APNS
import APNSCore
import Vapor

/// The two APNs clients (sandbox and production), held directly on the Application.
///
/// Replaces the `vapor/apns` container, which is pinned to APNSwift 6.x and can't carry
/// the iOS 18 `input-push-token` field that push-to-start restarts need. Same clients,
/// same JWT configuration — just without the wrapper.
struct APNSClients: Sendable {
    typealias Client = APNSClient<JSONDecoder, JSONEncoder>

    let development: Client
    let production: Client

    func client(for environment: PushEnvironment) -> Client {
        switch environment {
        case .development: development
        case .production: production
        }
    }

    func shutdown() async throws {
        try await development.shutdown()
        try await production.shutdown()
    }
}

struct APNSNotConfiguredError: Error, CustomStringConvertible {
    var description: String { "APNs is not configured (missing PUSH_NOTIFICATION_KEY/ID or TEAM_IDENTIFIER)" }
}

extension Application {
    private struct APNSClientsKey: StorageKey {
        typealias Value = APNSClients
    }

    var apnsClients: APNSClients? {
        get { storage[APNSClientsKey.self] }
        set { storage[APNSClientsKey.self] = newValue }
    }

    /// The client for an environment, or a thrown error where the old container would
    /// have crashed on an unconfigured app.
    func apnsClient(for environment: PushEnvironment) throws -> APNSClients.Client {
        guard let clients = apnsClients else { throw APNSNotConfiguredError() }
        return clients.client(for: environment)
    }
}

/// Shuts the clients down with the app so their HTTP/2 connections don't leak.
struct APNSClientsLifecycle: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        try? await application.apnsClients?.shutdown()
    }
}
