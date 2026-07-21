import Foundation
import OSLog

public enum BuildBeaconLog {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.buildbeacon"

    public static let authentication = Logger(subsystem: subsystem, category: "authentication")
    public static let networking = Logger(subsystem: subsystem, category: "networking")
    public static let monitoring = Logger(subsystem: subsystem, category: "monitoring")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let notifications = Logger(subsystem: subsystem, category: "notifications")
    public static let userAction = Logger(subsystem: subsystem, category: "user-action")
}

public enum LogRedactor {
    private static let sensitiveHeaderNames: Set<String> = [
        "authorization", "cookie", "set-cookie", "proxy-authorization", "x-api-key",
    ]

    /// Redacts known secret values and common header/JSON representations before
    /// dynamic text is sent to unified logging.
    public static func redact(_ value: String, secrets: [String] = []) -> String {
        var result = value
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }

        let patterns = [
            #"(?i)(authorization\s*[:=]\s*)([^\r\n,;]+)"#,
            #"(?i)(\"?(?:access[_-]?token|api[_-]?token|token|password)\"?\s*[:=]\s*\"?)([^\"\s,;}]+)"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1<redacted>"
            )
        }
        return result
    }

    public static func redact(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, item in
            result[item.key] = sensitiveHeaderNames.contains(item.key.lowercased())
                ? "<redacted>"
                : item.value
        }
    }
}
