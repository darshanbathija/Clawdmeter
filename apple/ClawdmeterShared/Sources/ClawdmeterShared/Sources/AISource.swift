import Foundation

/// Source of `UsageData` for a single AI provider.
///
/// Plan D8: V1 has one implementation (`AnthropicSource`). V2 adds `CodexSource`.
/// V3 fuses both. The protocol exists from day 1 so multi-source work is a config
/// change, not a refactor.
public protocol AISource: AnyObject, Sendable {

    /// Stable identifier, e.g. "anthropic", "codex". Used for logging and disambiguation.
    var providerID: String { get }

    /// Human-readable display name, e.g. "Claude (Anthropic)".
    var displayName: String { get }

    /// Whether the source can poll right now. False if not authenticated.
    var isAuthenticated: Bool { get }

    /// Poll for the latest `UsageData`.
    /// - Returns: a `UsageData` snapshot.
    /// - Throws: `AISourceError` on any failure (auth, network, parse).
    func poll() async throws -> UsageData

    /// Refresh credentials if they're stale. Implementations should be bounded
    /// (plan E7: 2 attempts per 10-min window).
    /// - Returns: true on success, false on hard refresh failure (user must re-auth).
    func refreshCredentialsIfNeeded() async throws -> Bool
}

/// Errors any `AISource` can throw. Stable across platforms.
public enum AISourceError: Error, Sendable {
    case unauthenticated
    case rateLimited(retryAfter: TimeInterval?)
    case authExpired                  // Refresh token also expired; user must re-auth
    case networkFailure(underlying: Error?)
    case malformedResponse(detail: String)
    case dataSourceContractViolation(detail: String) // Phase 0 contract not met
}

extension AISourceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unauthenticated:
            return "AISourceError.unauthenticated"
        case .rateLimited(let retry):
            return "AISourceError.rateLimited(retryAfter: \(retry.map { "\($0)s" } ?? "nil"))"
        case .authExpired:
            return "AISourceError.authExpired"
        case .networkFailure(let err):
            return "AISourceError.networkFailure(\(err.map { "\($0)" } ?? "nil"))"
        case .malformedResponse(let detail):
            return "AISourceError.malformedResponse(\(detail))"
        case .dataSourceContractViolation(let detail):
            return "AISourceError.dataSourceContractViolation(\(detail))"
        }
    }
}
