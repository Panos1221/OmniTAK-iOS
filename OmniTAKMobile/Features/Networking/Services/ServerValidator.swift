//
//  ServerValidator.swift
//  OmniTAKMobile
//
//  Validates TAK server configurations and detects common connection issues
//  Provides helpful diagnostics and troubleshooting guidance
//

import Foundation
import Network

// MARK: - Validation Result

struct ServerValidationResult {
    let isValid: Bool
    let issues: [ValidationIssue]
    let warnings: [ValidationWarning]

    var hasErrors: Bool { !issues.isEmpty }
    var hasWarnings: Bool { !warnings.isEmpty }

    var primaryIssue: ValidationIssue? { issues.first }
}

struct ValidationIssue {
    let code: IssueCode
    let message: String
    let troubleshooting: [String]

    enum IssueCode {
        case invalidHost
        case invalidPort
        case portMismatch
        case missingCredentials
        case htmlResponseDetected
        case sslRequired
        case unreachable
        // TAK Server's mTLS-rejection page (title "TAK Server resource
        // unavailable or not allowed.") — what :8443-style ports return
        // when the client doesn't present a certificate. Most commonly
        // seen when a reverse proxy forwards the enrollment hostname to
        // TAK's :8443 internally instead of :8446.
        case takMtlsPortRouted
        // TAK Server's angular login HTML (loginManager) — Authorization
        // header never reached TAK. Either the :8446 connector lacks
        // allowBasicAuth="true", or a reverse proxy stripped the header.
        case takLoginPageReturned
    }
}

struct ValidationWarning {
    let message: String
    let suggestion: String
}

// MARK: - Server Validator

class ServerValidator {

    static let shared = ServerValidator()

    // Standard TAK server ports
    private let standardPorts = StandardTAKPorts()

    private init() {}

    // MARK: - Validation Methods

    /// Validate server configuration before connection attempt
    func validateServerConfig(
        host: String,
        port: Int,
        useTLS: Bool,
        isEnrollment: Bool,
        username: String? = nil,
        password: String? = nil
    ) -> ServerValidationResult {
        var issues: [ValidationIssue] = []
        var warnings: [ValidationWarning] = []

        // 1. Validate host
        if !isValidHost(host) {
            issues.append(ValidationIssue(
                code: .invalidHost,
                message: "Invalid server address",
                troubleshooting: [
                    "Enter a valid hostname or IP address",
                    "Examples: 192.168.1.100, tak.example.com",
                    "Do not include http:// or https:// prefix"
                ]
            ))
        }

        // 2. Validate port
        if !isValidPort(port) {
            issues.append(ValidationIssue(
                code: .invalidPort,
                message: "Invalid port number",
                troubleshooting: [
                    "Port must be between 1 and 65535",
                    "Common TAK ports: 8089 (streaming), 8446 (enrollment)"
                ]
            ))
        }

        // 3. Check for port/purpose mismatch
        if let mismatch = detectPortMismatch(port: port, isEnrollment: isEnrollment, useTLS: useTLS) {
            issues.append(mismatch)
        }

        // 4. Check credentials for enrollment
        if isEnrollment {
            if username?.isEmpty ?? true || password?.isEmpty ?? true {
                issues.append(ValidationIssue(
                    code: .missingCredentials,
                    message: "Username and password required",
                    troubleshooting: [
                        "Certificate enrollment requires authentication",
                        "Enter your TAK server username and password",
                        "Contact your server administrator if you don't have credentials"
                    ]
                ))
            }
        }

        // 5. SSL/TLS recommendations
        if !useTLS && port == standardPorts.streamingTLS {
            warnings.append(ValidationWarning(
                message: "Port 8089 typically requires TLS",
                suggestion: "Enable TLS/SSL for this connection"
            ))
        }

        if useTLS && port == standardPorts.streamingTCP {
            warnings.append(ValidationWarning(
                message: "Port 8087 is typically unencrypted",
                suggestion: "Disable TLS or use port 8089"
            ))
        }

        return ServerValidationResult(
            isValid: issues.isEmpty,
            issues: issues,
            warnings: warnings
        )
    }

    /// Detect if server returned HTML instead of expected protocol
    func detectHTMLResponse(data: Data) -> ValidationIssue? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Check for HTML markers
        let htmlIndicators = [
            "<!DOCTYPE html",
            "<html",
            "<head>",
            "<body>",
            "text/html"
        ]

        let isHTML = htmlIndicators.contains { text.contains($0) }

        if isHTML {
            // Try to extract error message from HTML title tag
            var pageTitle: String? = nil

            // Use NSRegularExpression for reliable extraction
            if let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]+)</title>", options: .caseInsensitive),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               let titleRange = Range(match.range(at: 1), in: text) {
                let extractedTitle = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extractedTitle.isEmpty && extractedTitle.count < 100 {
                    pageTitle = extractedTitle
                }
            }

            // Pattern-match known TAK Server response HTMLs and surface
            // tailored troubleshooting. This is much more useful than the
            // generic "wrong port" hint when the user is already on the
            // right port but a reverse proxy is sending traffic to the
            // wrong TAK port internally (Pangolin, Traefik, nginx, Caddy).
            if let tailored = detectTAKErrorPage(body: text, title: pageTitle) {
                return tailored
            }

            let errorMessage: String
            if let title = pageTitle {
                errorMessage = "Server returned web page: \"\(title)\""
            } else {
                errorMessage = "Server returned a web page instead of expected data"
            }

            return ValidationIssue(
                code: .htmlResponseDetected,
                message: errorMessage,
                troubleshooting: [
                    "This usually means you're connecting to the wrong port.",
                    "",
                    "TAK Server Ports:",
                    "• Port 8089 - CoT Streaming (TLS) - use for connections",
                    "• Port 8446 - Certificate Enrollment API",
                    "• Port 8443 - Web Interface (browsers only, not for apps)",
                    "",
                    "Common fixes:",
                    "1. For enrollment: ensure you're using port 8446",
                    "2. For streaming: use port 8089 with TLS enabled",
                    "3. Verify with your server administrator"
                ]
            )
        }

        return nil
    }

    /// Recognise specific TAK Server HTML responses and surface
    /// actionable guidance. Returns nil if the body doesn't match a
    /// known pattern, in which case the caller falls back to the
    /// generic "Server returned a web page" issue.
    private func detectTAKErrorPage(body: String, title: String?) -> ValidationIssue? {
        // Case 1: TAK's mTLS-rejection page.
        // Hit when a request lands on a TAK port that requires a client
        // certificate (typically :8443) and the client doesn't present
        // one. The user almost certainly typed the right port in the
        // app — what's wrong is the proxy in front of TAK is forwarding
        // their enrollment hostname to TAK's :8443 internally.
        let titleLower = title?.lowercased() ?? ""
        if titleLower.contains("tak server resource unavailable")
            || titleLower.contains("not allowed")
            || body.contains("TAK Server resource unavailable or not allowed") {
            return ValidationIssue(
                code: .takMtlsPortRouted,
                message: "TAK denied the enrollment request",
                troubleshooting: [
                    "This is TAK's generic \"access denied\" response. The request reached TAK,",
                    "but TAK refused to serve the resource. Three likely causes:",
                    "",
                    "1. Reverse proxy is sending traffic to the wrong TAK port.",
                    "   If you're behind Pangolin / Traefik / nginx / Caddy, the proxy is",
                    "   probably forwarding your enrollment hostname to TAK's :8443",
                    "   (cert-required) instead of :8446 (cert-enrollment).",
                    "   → Repoint that route to TAK's internal :8446.",
                    "   → Keep :8089 on a separate TCP-passthrough route.",
                    "   → Verify the proxy preserves the Authorization header.",
                    "",
                    "2. Your account isn't authorized for certificate enrollment.",
                    "   If you can reach TAK with iTAK / ATAK / WinTAK using pre-issued",
                    "   certs but OmniTAK can't enroll, this is the most likely cause.",
                    "   Ask your admin to grant the account the cert-enrollment role.",
                    "",
                    "3. Server-side LDAP / group assignment failure.",
                    "   TAK accepted the credentials but couldn't complete the post-auth",
                    "   group lookup (common with fresh LDAP integrations).",
                    "   Have the admin check takserver-api.log for",
                    "   \"exception during group assignment\".",
                    "",
                    "Quick diagnostic from the TAK host:",
                    "  curl -sk -u USER:PASS https://YOUR_HOST:8446/Marti/api/tls/config",
                    "  → XML body = success, fix is in the proxy or on your device.",
                    "  → this same HTML = server config (LDAP groups, allowBasicAuth, etc.).",
                    "",
                    "Alternative: if your admin can issue a QR enrollment package, use",
                    "\"Scan QR Code Instead\" on the previous screen to bypass this flow."
                ]
            )
        }

        // Case 2: TAK's angular login UI (loginManager).
        // The request reached TAK but the Authorization header never
        // arrived, so TAK is serving its browser login screen. Either
        // :8446's connector lacks allowBasicAuth, or the proxy stripped
        // the Authorization header.
        if body.contains("loginManager") || body.contains("data-ng-app") {
            return ValidationIssue(
                code: .takLoginPageReturned,
                message: "Server returned its browser login screen",
                troubleshooting: [
                    "TAK didn't see a Basic auth header, so it served its login page instead of the API response.",
                    "",
                    "On the TAK server, the :8446 connector needs allowBasicAuth=\"true\":",
                    "  <connector port=\"8446\" clientAuth=\"false\" allowBasicAuth=\"true\" .../>",
                    "",
                    "Also make sure your <auth> block engages an authenticator:",
                    "  <auth default=\"ldap\" ...>   (or default=\"file\" with users defined)",
                    "",
                    "If the server is behind a reverse proxy, confirm the proxy",
                    "isn't stripping the Authorization header. Quick sanity check from",
                    "the TAK host:",
                    "  curl -sk -u USER:PASS https://YOUR_HOST:8446/Marti/api/tls/config",
                    "  → should return XML; if it returns this same HTML the server itself needs the fix."
                ]
            )
        }

        return nil
    }

    /// Validate error response and provide guidance
    func analyzeErrorResponse(statusCode: Int, data: Data, context: ErrorContext) -> ValidationIssue {
        // Check if it's an HTML response
        if let htmlIssue = detectHTMLResponse(data: data) {
            return htmlIssue
        }

        // Analyze HTTP status codes
        switch statusCode {
        case 401:
            return ValidationIssue(
                code: .missingCredentials,
                message: "Authentication failed (401)",
                troubleshooting: [
                    "Possible causes:",
                    "• Username or password is incorrect",
                    "• Account is not active or not authorized for enrollment",
                    "• Server requires different authentication method",
                    "",
                    "Try these steps:",
                    "1. Double-check your username and password",
                    "2. Verify your account is active on the TAK server",
                    "3. Ask your admin if your account has enrollment permissions",
                    "4. Try scanning a QR code or importing a Data Package instead"
                ]
            )

        case 403:
            return ValidationIssue(
                code: .missingCredentials,
                message: "Access forbidden",
                troubleshooting: [
                    "Your account doesn't have permission for this operation",
                    "Contact the server administrator to enable enrollment permissions",
                    "You may need to be added to a specific group"
                ]
            )

        case 404:
            return ValidationIssue(
                code: .portMismatch,
                message: "Enrollment endpoint not found",
                troubleshooting: [
                    "The server doesn't have the enrollment API at this address",
                    "Verify you're using the correct port (usually 8446)",
                    "The server may not support CSR-based enrollment",
                    "You may need to use a Data Package instead",
                    "Contact your administrator for the correct enrollment method"
                ]
            )

        case 500:
            let responseText = String(data: data, encoding: .utf8) ?? ""
            var troubleshooting = [
                "The server encountered an internal error",
                "This could indicate:"
            ]

            if responseText.contains("unavailable") || responseText.contains("not allowed") {
                troubleshooting.append("• The enrollment API is disabled on this server")
                troubleshooting.append("• Your account lacks required permissions")
            }

            troubleshooting.append("• Server misconfiguration")
            troubleshooting.append("")
            troubleshooting.append("Try these steps:")
            troubleshooting.append("1. Contact your server administrator")
            troubleshooting.append("2. Ask if certificate enrollment is enabled")
            troubleshooting.append("3. Request a Data Package (.zip) instead")
            troubleshooting.append("4. Verify the server is properly configured")

            return ValidationIssue(
                code: .htmlResponseDetected,
                message: "Server error (500)",
                troubleshooting: troubleshooting
            )

        case 502, 503, 504:
            return ValidationIssue(
                code: .unreachable,
                message: "Server unavailable",
                troubleshooting: [
                    "The server is not responding",
                    "Check if the server is online",
                    "Verify your network connection",
                    "The server may be undergoing maintenance"
                ]
            )

        default:
            return ValidationIssue(
                code: .htmlResponseDetected,
                message: "Server error (\(statusCode))",
                troubleshooting: [
                    "Unexpected server response",
                    "Contact your server administrator",
                    "Provide them with error code: \(statusCode)"
                ]
            )
        }
    }

    // MARK: - Private Validation Helpers

    private func isValidHost(_ host: String) -> Bool {
        if host.isEmpty {
            return false
        }

        // The host field may legitimately carry a full endpoint when
        // the TAK server sits behind a reverse proxy — e.g.
        // "https://tak.example.com" or "tak.example.com/tak". Strip an
        // optional scheme and path prefix, then validate just the
        // host[:port] core. (Previously any "://" or "/" was rejected
        // outright, which made proxied servers impossible to enter.)
        var core = host.trimmingCharacters(in: .whitespaces)
        if let schemeRange = core.range(of: "://") {
            core = String(core[schemeRange.upperBound...])
        }
        if let slash = core.firstIndex(of: "/") {
            core = String(core[..<slash])
        }
        // Drop an optional :port suffix before host validation.
        if let colon = core.lastIndex(of: ":"),
           Int(core[core.index(after: colon)...]) != nil {
            core = String(core[..<colon])
        }
        if core.isEmpty {
            return false
        }

        // Check if it's a valid IP address
        if IPv4Address(core) != nil || IPv6Address(core) != nil {
            return true
        }

        // Check if it's a valid hostname
        let hostnameRegex = "^([a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)*[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?$"
        let hostnamePredicate = NSPredicate(format: "SELF MATCHES %@", hostnameRegex)

        return hostnamePredicate.evaluate(with: core)
    }

    private func isValidPort(_ port: Int) -> Bool {
        return port > 0 && port <= 65535
    }

    private func detectPortMismatch(port: Int, isEnrollment: Bool, useTLS: Bool) -> ValidationIssue? {
        // Check for obvious mismatches
        if isEnrollment {
            // Enrollment should use API ports (8446, 8443)
            if port == standardPorts.streamingTLS || port == standardPorts.streamingTCP {
                return ValidationIssue(
                    code: .portMismatch,
                    message: "Wrong port for enrollment",
                    troubleshooting: [
                        "Port \(port) is for streaming connections, not enrollment",
                        "Certificate enrollment typically uses port 8446",
                        "Change the enrollment port to 8446",
                        "If unsure, contact your server administrator"
                    ]
                )
            }
        } else {
            // Streaming should use CoT ports (8089, 8087)
            if port == standardPorts.enrollmentAPI || port == standardPorts.webInterface {
                return ValidationIssue(
                    code: .portMismatch,
                    message: "Wrong port for streaming",
                    troubleshooting: [
                        "Port \(port) is for web/API access, not streaming",
                        "Streaming connections typically use port 8089",
                        "Make sure TLS is enabled for port 8089",
                        "If unsure, contact your server administrator"
                    ]
                )
            }
        }

        // Check for web interface port
        if port == standardPorts.webInterface {
            return ValidationIssue(
                code: .portMismatch,
                message: "Cannot connect to web interface",
                troubleshooting: [
                    "Port 8443 is the web interface (for browsers)",
                    "Mobile apps cannot connect to this port",
                    "Use port 8089 for streaming (TLS required)",
                    "Use port 8446 for certificate enrollment"
                ]
            )
        }

        return nil
    }
}

// MARK: - Standard TAK Ports

struct StandardTAKPorts {
    let streamingTCP = 8087      // Unencrypted CoT streaming
    let streamingTLS = 8089      // TLS-encrypted CoT streaming (most common)
    let webInterface = 8443      // HTTPS web interface
    let enrollmentAPI = 8446     // Certificate enrollment API
}

// MARK: - Error Context

enum ErrorContext {
    case enrollment
    case connection
    case dataSync
}

// MARK: - User-Friendly Error Formatter

class ErrorMessageFormatter {

    static func format(issue: ValidationIssue) -> (title: String, message: String, steps: String) {
        let title = issue.message

        var message = ""
        var steps = ""

        switch issue.code {
        case .htmlResponseDetected:
            message = "The server returned a web page instead of the expected response. This usually means you're connecting to the wrong port."

        case .portMismatch:
            message = "The port you're using doesn't match the type of connection you're trying to make."

        case .missingCredentials:
            message = "This operation requires authentication."

        case .unreachable:
            message = "Cannot reach the server at this address."

        case .invalidHost:
            message = "The server address format is invalid."

        case .invalidPort:
            message = "The port number is outside the valid range."

        case .sslRequired:
            message = "This connection requires TLS/SSL encryption."

        case .takMtlsPortRouted:
            message = "TAK reached your request but refused to serve the resource. The cause is usually one of: a reverse proxy routing traffic to TAK's cert-required :8443 instead of :8446, an account that isn't authorized for enrollment, or a server-side LDAP/group-assignment failure. The steps below help isolate which."

        case .takLoginPageReturned:
            message = "TAK served its browser login screen because no Basic auth header arrived. The server's :8446 connector probably needs allowBasicAuth=\"true\", or a reverse proxy is stripping the Authorization header."
        }

        if !issue.troubleshooting.isEmpty {
            steps = issue.troubleshooting.joined(separator: "\n")
        }

        return (title, message, steps)
    }
}
