import Foundation
import Security

final class CertificateTrustVerifier {
    /// Check whether a CA certificate (given as PEM data) is installed and fully trusted
    /// by the system. Uses SecTrust evaluation against system anchors only — no network needed.
    static func isCACertificateTrusted(certPEM: String) -> Bool {
        guard let pemData = certPEM.data(using: .utf8),
              let block = pemData.pemCertificateBlock,
              let cert = SecCertificateCreateWithData(nil, block as CFData) else {
            RuntimeLogger.error("APP", "Trust", "Unable to parse CA certificate PEM")
            return false
        }

        // Create a basic trust with the CA cert, using system anchor certificates only
        var trust: SecTrust?
        let createStatus = SecTrustCreateWithCertificates(
            [cert] as CFArray,
            SecPolicyCreateBasicX509(),
            &trust
        )
        guard createStatus == errSecSuccess, let trust = trust else {
            RuntimeLogger.error("APP", "Trust", "Unable to create SecTrust")
            return false
        }

        // Use system anchors only — if our CA is installed & trusted, evaluation passes
        SecTrustSetAnchorCertificatesOnly(trust, false)

        var error: CFError?
        let result = SecTrustEvaluateWithError(trust, &error)
        if let error {
            RuntimeLogger.warning("APP", "Trust", "SecTrust evaluation returned an error", details: [
                "error": (error as Error).localizedDescription
            ])
        }

        RuntimeLogger.info("APP", "Trust", result ? "CA certificate is trusted by the system" : "CA certificate is not trusted by the system")
        return result
    }
}

private extension Data {
    var pemCertificateBlock: Data? {
        guard let text = String(data: self, encoding: .utf8),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----") else { return nil }
        let body = text[begin.upperBound..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: body)
    }
}
