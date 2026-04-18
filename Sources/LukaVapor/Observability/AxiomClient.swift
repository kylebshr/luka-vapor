import Vapor
import Foundation
import NIOCore

/// Minimal Axiom ingest client. Fire-and-forget per event.
///
/// Env vars:
///   AXIOM_TOKEN    — API token (api-xxxxxxxx)
///   AXIOM_DATASET  — destination dataset name
///   AXIOM_URL      — optional base URL (defaults to https://api.axiom.co)
///
/// Emits events as single-item JSON arrays to `/v1/datasets/{dataset}/ingest`.
/// If env vars are missing, `emit` is a no-op so local/dev runs stay quiet.
final class AxiomClient: Sendable {
    private let token: String
    private let dataset: String
    private let baseURL: String
    private let client: any Client
    private let logger: Logger

    init?(client: any Client, logger: Logger) {
        guard let token = Environment.get("AXIOM_TOKEN"),
              let dataset = Environment.get("AXIOM_DATASET") else {
            return nil
        }
        self.token = token
        self.dataset = dataset
        self.baseURL = Environment.get("AXIOM_URL") ?? "https://api.axiom.co"
        self.client = client
        self.logger = logger
    }

    /// Emit one event. Fire-and-forget: returns immediately, ships on a detached Task.
    func emit(_ name: String, attributes: [String: String] = [:]) {
        // Axiom auto-timestamps on ingest if `_time` omitted.
        var payload = attributes
        payload["event"] = name

        Task { [client, token, dataset, baseURL, logger] in
            do {
                let uri = URI(string: "\(baseURL)/v1/datasets/\(dataset)/ingest")
                var headers = HTTPHeaders()
                headers.add(name: "Authorization", value: "Bearer \(token)")
                headers.add(name: "Content-Type", value: "application/json")

                let body = try JSONEncoder().encode([payload])
                var buffer = ByteBufferAllocator().buffer(capacity: body.count)
                buffer.writeBytes(body)

                let response = try await client.post(uri, headers: headers) { req in
                    req.body = buffer
                }

                if response.status.code >= 300 {
                    logger.warning("Axiom ingest non-2xx: \(response.status.code)")
                }
            } catch {
                logger.warning("Axiom ingest failed: \(error)")
            }
        }
    }

}

extension Application {
    private struct AxiomKey: StorageKey {
        typealias Value = AxiomClient
    }

    var axiom: AxiomClient? {
        get { storage[AxiomKey.self] }
        set { storage[AxiomKey.self] = newValue }
    }
}
