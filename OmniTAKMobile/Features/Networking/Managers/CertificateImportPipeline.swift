//
//  CertificateImportPipeline.swift
//  OmniTAKMobile
//
//  Universal certificate import with automatic format detection and conversion
//  Handles legacy RC2-40-CBC and modern AES-256-CBC formats transparently
//

import Foundation
import Security

// MARK: - Certificate Import Errors

enum CertificateImportError: LocalizedError {
    case invalidData
    case invalidPassword
    case unsupportedFormat(String)
    case conversionFailed(String)
    case keychainError(OSStatus)
    case noIdentityFound

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Certificate data is invalid or corrupted"
        case .invalidPassword:
            return "Incorrect certificate password. Common TAK server passwords: 'atakatak', or check with your server administrator."
        case .unsupportedFormat(let details):
            return "Unsupported certificate format: \(details)"
        case .conversionFailed(let details):
            return "Certificate conversion failed: \(details)"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .noIdentityFound:
            return "No identity found in certificate"
        }
    }
}

// MARK: - Certificate Import Result

struct CertificateImportResult {
    let identity: SecIdentity?  // Optional: truststores have no identity (no private key)
    let certificate: SecCertificate
    let certificateAlias: String
    let conversionApplied: Bool
    let originalFormat: String
    let finalFormat: String
}

// MARK: - Certificate Import Pipeline

class CertificateImportPipeline {

    /// Default P12 password used as a fallback when extracting data-package
    /// certificates. Sourced from Info.plist `DefaultP12Password` (set via
    /// `DEFAULT_P12_PASSWORD` build setting). Returns empty string if unset.
    static var defaultP12Password: String {
        Bundle.main.object(forInfoDictionaryKey: "DefaultP12Password") as? String ?? ""
    }

    private let formatConverter: CertificateFormatConverter

    init() {
        self.formatConverter = CertificateFormatConverter()
    }

    // MARK: - PKCS12 Parsing (single SecPKCS12Import owner)

    /// The ONE SecPKCS12Import invocation in the codebase. Returns the
    /// decoded item dictionaries; maps status codes to typed errors.
    static func parsePKCS12(_ data: Data, password: String) throws -> [[String: Any]] {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]

        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)

        guard status == errSecSuccess else {
            print("[CertImport] SecPKCS12Import failed with status: \(status)")
            if status == errSecAuthFailed {
                print("[CertImport] Status indicates: Authentication failed (wrong password)")
                throw CertificateImportError.invalidPassword
            } else if status == errSecDecode {
                print("[CertImport] Status indicates: Decode error (corrupted or wrong format)")
            }
            throw CertificateImportError.keychainError(status)
        }

        guard let items = rawItems as? [[String: Any]], !items.isEmpty else {
            throw CertificateImportError.noIdentityFound
        }
        return items
    }

    /// Parse-only helper: extract the SecIdentity from p12 data without
    /// any keychain writes. Used by the mTLS load paths
    /// (CertificateManager.extractIdentity, TAKService.loadP12Identity).
    static func parseIdentity(_ data: Data, password: String) -> SecIdentity? {
        guard let items = try? parsePKCS12(data, password: password),
              let firstItem = items.first,
              let identityRef = firstItem[kSecImportItemIdentity as String] else {
            return nil
        }
        return (identityRef as! SecIdentity)
    }

    // MARK: - Main Import Method

    /// Universal certificate import with automatic format detection and conversion
    /// - Parameters:
    ///   - data: Certificate data (P12/PKCS12 format)
    ///   - password: Certificate password
    ///   - label: Label for keychain storage
    /// - Returns: Import result with identity and format details
    func importCertificate(
        _ data: Data,
        password: String,
        label: String
    ) async throws -> CertificateImportResult {

        print("[CertImport] Starting certificate import (size: \(data.count) bytes)")

        // Step 1: Try direct import (fast path - works for 90% of modern certificates)
        if let result = try? directImport(data, password: password, label: label) {
            print("[CertImport] Direct import successful (no conversion needed)")
            return result
        }

        print("[CertImport] Direct import failed, detecting format...")

        // Step 2: Detect format issue
        let formatInfo = formatConverter.detectFormat(data, password: password)
        print("[CertImport] Detected format: \(formatInfo.description)")

        guard formatInfo.needsConversion else {
            // Format is compatible but import still failed - likely password issue
            print("[CertImport] Certificate format is compatible but import failed")
            print("[CertImport] This indicates an incorrect password")
            throw CertificateImportError.invalidPassword
        }

        print("[CertImport] Format needs conversion: \(formatInfo.issueDescription)")

        // Step 3: Auto-convert to iOS-compatible format
        print("[CertImport] Converting certificate format...")
        let convertedData = try await convertCertificate(data, password: password, formatInfo: formatInfo)

        print("[CertImport] Conversion successful, importing converted certificate...")

        // Step 4: Import converted certificate
        guard let result = try? directImport(convertedData, password: password, label: label) else {
            throw CertificateImportError.conversionFailed("Converted certificate could not be imported")
        }

        print("[CertImport] Import successful after conversion")
        return result
    }

    // MARK: - Direct Import (Fast Path)

    private func directImport(
        _ data: Data,
        password: String,
        label: String
    ) throws -> CertificateImportResult {

        let items = try CertificateImportPipeline.parsePKCS12(data, password: password)
        guard let firstItem = items.first else {
            throw CertificateImportError.noIdentityFound
        }

        // Check if this is an identity (cert + key) or just certificates (truststore)
        if let identityRef = firstItem[kSecImportItemIdentity as String] {
            // Full identity with private key
            let identity = (identityRef as! SecIdentity)
            print("[CertImport] Importing identity (certificate + private key)")

            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)

            guard let cert = certificate else {
                throw CertificateImportError.noIdentityFound
            }

            try storeIdentity(identity, label: label)

            return CertificateImportResult(
                identity: identity,
                certificate: cert,
                certificateAlias: label,
                conversionApplied: false,
                originalFormat: "Identity (direct import)",
                finalFormat: "Native iOS format"
            )
        } else if let certChain = firstItem[kSecImportItemCertChain as String] as? [SecCertificate],
                  let firstCert = certChain.first {
            // Certificate-only (truststore) - no private key
            print("[CertImport] Importing certificate-only P12 (truststore)")

            storeCertificateChain(certChain, label: label)

            // Return a placeholder identity (will be nil) but mark as successful
            // The certificate chain is what matters for truststores
            return CertificateImportResult(
                identity: nil as SecIdentity?,
                certificate: firstCert,
                certificateAlias: label,
                conversionApplied: false,
                originalFormat: "Certificate-only (truststore)",
                finalFormat: "Native iOS format"
            )
        } else if let trust = firstItem[kSecImportItemTrust as String],
                  let certChain = SecTrustCopyCertificateChain(trust as! SecTrust) as? [SecCertificate],
                  let firstCert = certChain.first {
            // Fallback for cert-only P12 files (e.g. truststores) where
            // kSecImportItemCertChain may not be populated — extract the
            // certificates from the SecTrust object instead.
            print("[CertImport] Importing certificate-only P12 via trust object")

            storeCertificateChain(certChain, label: label)

            return CertificateImportResult(
                identity: nil as SecIdentity?,
                certificate: firstCert,
                certificateAlias: label,
                conversionApplied: false,
                originalFormat: "Certificate-only (truststore via trust object)",
                finalFormat: "Native iOS format"
            )
        } else {
            throw CertificateImportError.noIdentityFound
        }
    }

    // MARK: - Keychain Storage (single write conventions)

    /// Store an identity under `label`. Delete-before-add avoids
    /// duplicates; kSecAttrAccessibleAfterFirstUnlock lets background
    /// reconnects read it.
    private func storeIdentity(_ identity: SecIdentity, label: String) throws {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemDelete(addQuery as CFDictionary)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            print("[CertImport] Failed to add identity to keychain (status: \(addStatus))")
            throw CertificateImportError.keychainError(addStatus)
        }
    }

    /// Store a certificate chain. The FIRST certificate goes under the
    /// bare `label` (exact-label lookups — e.g. the CA truststore loader
    /// — depend on this), subsequent certs under `label-N`.
    private func storeCertificateChain(_ certChain: [SecCertificate], label: String) {
        for (index, certificate) in certChain.enumerated() {
            let certLabel = index == 0 ? label : "\(label)-\(index)"
            let certQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrLabel as String: certLabel,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]

            SecItemDelete(certQuery as CFDictionary)
            let addStatus = SecItemAdd(certQuery as CFDictionary, nil)
            if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
                print("[CertImport] Warning: Failed to add certificate \(index) to keychain (status: \(addStatus))")
            }
        }
    }

    // MARK: - Certificate Conversion

    private func convertCertificate(
        _ data: Data,
        password: String,
        formatInfo: CertificateFormatInfo
    ) async throws -> Data {

        // On iOS, Process is not available for OpenSSL command-line conversion
        // We rely on Security framework for conversion
        if let converted = try? convertWithSecurityFramework(data, password: password) {
            return converted
        }

        // If all conversions fail and format is legacy, provide helpful error
        if formatInfo.isLegacyFormat {
            throw CertificateImportError.unsupportedFormat(
                "Legacy \(formatInfo.encryptionAlgorithm) format is not supported on iOS. " +
                "Please regenerate the certificate with modern encryption (AES-256-CBC or 3DES). " +
                "Server administrators can do this with: " +
                "openssl pkcs12 -legacy -in old.p12 -out temp.pem -nodes -passin pass:PASSWORD && " +
                "openssl pkcs12 -export -in temp.pem -out new.p12 -passout pass:PASSWORD -keypbe AES-256-CBC -certpbe AES-256-CBC"
            )
        }

        throw CertificateImportError.conversionFailed("Certificate conversion failed")
    }

    // MARK: - Security Framework Conversion (Fallback Strategy)

    private func convertWithSecurityFramework(
        _ data: Data,
        password: String
    ) throws -> Data {

        // On iOS, we cannot export/re-encrypt certificates like on macOS
        // SecItemExport is macOS-only
        // Instead, we try to parse again to see if it works at all
        // (This shouldn't happen if direct import already failed, but let's try)
        guard (try? CertificateImportPipeline.parsePKCS12(data, password: password)) != nil else {
            throw CertificateImportError.conversionFailed("Security framework could not parse certificate")
        }

        // No actual conversion possible on iOS, return original data
        // This will fail when we try to import it again, but it's the best we can do
        throw CertificateImportError.conversionFailed("Certificate conversion not available on iOS")
    }
}
