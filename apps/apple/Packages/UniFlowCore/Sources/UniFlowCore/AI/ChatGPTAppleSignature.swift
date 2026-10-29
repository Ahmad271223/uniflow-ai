#if canImport(Security) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Security

/// Signatur eines ID-Tokens von OpenAI pruefen (wie `social_login._verify_signature`): RS256 mit dem RSA-Schluessel
/// aus `n`/`e`, ES256 mit dem P-256-Schluessel aus `x`/`y` (Signatur r||s, je 32 Bytes). Nur Apple-Systeme.
public struct ChatGPTAppleSignature: ChatGPTSignatureChecking {
    public init() {}

    public func verify(jwk: JSONValue, alg: String, signingInput: Data, signature: [UInt8]) -> Bool {
        func bytes(_ key: String) -> [UInt8]? { jwk[key]?.string.flatMap { ChatGPTIDToken.base64URLDecode(Substring($0)) } }
        switch alg {
        case "RS256":
            guard jwk["kty"]?.string == "RSA", let n = bytes("n"), let e = bytes("e"), !n.isEmpty, !e.isEmpty else { return false }
            let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            guard let key = SecKeyCreateWithData(Data(Self.rsaPublicKeyDER(n: n, e: e)) as CFData, attrs as CFDictionary, nil) else { return false }
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, Data(signature) as CFData, nil)
        case "ES256":
            guard jwk["kty"]?.string == "EC", jwk["crv"]?.string == "P-256", let x = bytes("x"), let y = bytes("y"),
                  x.count == 32, y.count == 32, signature.count == 64,
                  let key = try? P256.Signing.PublicKey(rawRepresentation: x + y),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
            return key.isValidSignature(sig, for: signingInput)
        default:
            return false
        }
    }

    /// PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e } in DER
    static func rsaPublicKeyDER(n: [UInt8], e: [UInt8]) -> [UInt8] {
        func length(_ count: Int) -> [UInt8] {
            if count < 0x80 { return [UInt8(count)] }
            var bytes: [UInt8] = []
            var c = count
            while c > 0 { bytes.insert(UInt8(c & 0xFF), at: 0); c >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ v: [UInt8]) -> [UInt8] {
            var v = Array(v.drop { $0 == 0 })
            if v.isEmpty { v = [0] }
            if v[0] & 0x80 != 0 { v.insert(0, at: 0) }          // positiv bleiben
            return [0x02] + length(v.count) + v
        }
        let body = integer(n) + integer(e)
        return [0x30] + length(body.count) + body
    }
}
#endif
