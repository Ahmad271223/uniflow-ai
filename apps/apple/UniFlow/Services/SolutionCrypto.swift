import CryptoKit
import Foundation
import UniFlowCore

/// Verschluesselung der Loesungspakete mit CryptoKit (nur App; der Kern bleibt ohne CryptoKit).
///
/// - Schluessel: HKDF-SHA256 mit den VOLLSTAENDIGEN Bytes der Original-PDF als Eingabe, zufaelligem Salz (32 Byte, im
///   Kopf) und Info = Formatkennung + Loesungs-ID (`SolutionPackage.keyInfo`). Bewusst nicht aus dem Fingerabdruck:
///   der steht im Klartext im Kopf, jeder mit dem Paket koennte sonst entschluesseln.
/// - Inhalt: AES-256-GCM mit zufaelliger Nonce (12 Byte); Kopf (alles ausser dem Chiffrat) als AAD, damit jede
///   Aenderung am Kopf auffaellt.
///
/// Grenze (ehrlich): Das bindet die Lesbarkeit an den Besitz genau dieser PDF-Datei. Es beweist keine
/// Kursberechtigung – Stud.IP-Dateien sind fuer alle Kursteilnehmer gleich und koennen weitergegeben werden – und
/// ersetzt keine Zugriffskontrolle auf einem Server (docs/LOESUNGEN-TEILEN.md).
struct CryptoKitSolutionCipher: SolutionCipher {
    struct InvalidInput: Error {}

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// HKDF-SHA256 (RFC 5869) mit 32 Byte Ergebnis, gleiches Ergebnis wie `HKDF<SHA256>.deriveKey`. Extract laeuft
    /// als HMAC in Bloecken ueber die (gemappte) PDF-Datei, damit keine Vollkopie der PDF-Bytes in einem
    /// `SymmetricKey` entsteht; danach Expand mit der Info.
    static func deriveKey(_ keyMaterial: Data, salt: Data, info: Data) -> SymmetricKey {
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: salt))
        keyMaterial.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let block = 1 << 20
            var offset = 0
            while offset < buffer.count {
                let end = min(offset + block, buffer.count)
                hmac.update(data: UnsafeRawBufferPointer(rebasing: buffer[offset..<end]))
                offset = end
            }
        }
        let prk = hmac.finalize()
        return HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: 32)
    }

    private func key(_ keyMaterial: Data, salt: Data, info: Data) -> SymmetricKey {
        Self.deriveKey(keyMaterial, salt: salt, info: info)
    }

    func seal(_ plaintext: Data, keyMaterial: Data, salt: Data, info: Data, nonce: Data, aad: Data) throws -> Data {
        guard !keyMaterial.isEmpty, salt.count == 32 else { throw InvalidInput() }
        let box = try AES.GCM.seal(plaintext, using: key(keyMaterial, salt: salt, info: info),
                                   nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }

    func open(_ sealed: Data, keyMaterial: Data, salt: Data, info: Data, nonce: Data, aad: Data) throws -> Data {
        guard sealed.count >= 16, !keyMaterial.isEmpty else { throw InvalidInput() }
        let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16),
                                        tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key(keyMaterial, salt: salt, info: info), authenticating: aad)
    }
}
