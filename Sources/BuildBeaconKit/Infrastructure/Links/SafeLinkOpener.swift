import AppKit
import Foundation

public enum SafeLinkError: Error, Equatable, Sendable {
    case malformedURL
    case schemeNotAllowed
    case hostNotAllowed
    case credentialsNotAllowed
    case portNotAllowed
    case systemRejectedURL
}

public struct SafeLinkPolicy: Hashable, Sendable {
    public let allowedSchemes: Set<String>
    public let allowedHosts: Set<String>
    public let allowsSubdomains: Bool

    public init(
        allowedSchemes: Set<String> = ["https"],
        allowedHosts: Set<String> = ["bitbucket.org"],
        allowsSubdomains: Bool = false
    ) {
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.allowsSubdomains = allowsSubdomains
    }

    @discardableResult
    public func validate(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SafeLinkError.malformedURL
        }
        guard let scheme = components.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            throw SafeLinkError.schemeNotAllowed
        }
        guard let host = components.host?.lowercased(), isAllowed(host: host) else {
            throw SafeLinkError.hostNotAllowed
        }
        guard components.user == nil, components.password == nil else {
            throw SafeLinkError.credentialsNotAllowed
        }
        guard components.port == nil || (scheme == "https" && components.port == 443) else {
            throw SafeLinkError.portNotAllowed
        }
        guard let normalizedURL = components.url else {
            throw SafeLinkError.malformedURL
        }
        return normalizedURL
    }

    private func isAllowed(host: String) -> Bool {
        if allowedHosts.contains(host) { return true }
        guard allowsSubdomains else { return false }
        return allowedHosts.contains(where: { host.hasSuffix(".\($0)") })
    }
}

@MainActor
public final class SafeLinkOpener {
    public let policy: SafeLinkPolicy
    private let workspace: NSWorkspace

    public init(
        policy: SafeLinkPolicy = SafeLinkPolicy(),
        workspace: NSWorkspace = .shared
    ) {
        self.policy = policy
        self.workspace = workspace
    }

    @discardableResult
    public func open(_ url: URL) throws -> Bool {
        let safeURL = try policy.validate(url)
        guard workspace.open(safeURL) else {
            throw SafeLinkError.systemRejectedURL
        }
        return true
    }
}
