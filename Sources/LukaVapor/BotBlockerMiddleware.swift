import Vapor

/// Middleware that blocks common bot/scanner requests probing for PHP vulnerabilities
struct BotBlockerMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = request.url.path.lowercased()

        // Block all .php requests - this is a Swift app, there are no legitimate PHP endpoints
        if path.hasSuffix(".php") || path.contains(".php7") || path.contains(".php/") {
            // Return 404 silently without logging
            return Response(status: .notFound)
        }

        return try await next.respond(to: request)
    }
}
