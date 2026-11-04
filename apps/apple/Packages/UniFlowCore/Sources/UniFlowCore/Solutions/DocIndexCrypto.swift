import Foundation

// Dokument-Index ("Bibliothek"): Fingerabdruecke, Verschluesselung und die Form der Datensaetze beim Dienst
// (docs/DOKUMENT-INDEX-2026-11-04.md). Dieselben Regeln wie app/doc_index.py (file_key, page_hash, record_name;
// Erwartungswerte in packages/shared-contracts/fixtures/doc-index/cases.json).
//
// Was der Dienst sieht: `fileKey` (HMAC des Datei-SHA; wer die Datei nicht hat, kann ihn nicht bilden und findet nichts),
// Seitennummer, Fassung, Zeitpunkt und das Chiffrat. Nie den rohen SHA, nie Seitentext, nie ein Bild, nie Namen.
// Schluessel: HKDF-SHA256 aus Datei-SHA + Seiten-Abdruck (nur wer dieselbe Datei hat, rechnet ihn), Salz je Datensatz,
// AES-256-GCM ueber `SolutionCipher`; Zusatzdaten binden das Chiffrat an fileKey und Seite (kein Umhaengen).

/// Fingerabdruecke wie `file_key`, `page_hash`, `record_name` in app/doc_index.py
public enum DocIndexFingerprint {
    static let fileKeyContext = Data("uniflow.docindex.filekey.v1".utf8)
    /// wie `PageOCRStore.minimumLetters` / `MIN_LETTERS`: darunter gilt die Seite als Bild oder Scan
    public static let minimumLetters = 20

    /// HMAC-SHA256 ohne CryptoKit (der Kern baut auch unter Linux)
    public static func hmacSHA256(key: Data, message: Data) -> [UInt8] {
        var k = key.count > 64 ? SolutionSHA256.hash(key) : [UInt8](key)
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let inner = SolutionSHA256.hash(Data(k.map { $0 ^ 0x36 }) + message)
        return SolutionSHA256.hash(Data(k.map { $0 ^ 0x5c }) + Data(inner))
    }

    public static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Abfragbarer Schluessel einer Datei beim Dienst (64 Hexziffern); nil, wenn `fileSHA` kein SHA-256 ist
    public static func fileKey(fileSHA: String) -> String? {
        let sha = fileSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isSHA256Hex(sha) else { return nil }
        return SolutionSHA256.hexString(hmacSHA256(key: fileKeyContext, message: Data(sha.utf8)))
    }

    /// `normalize_text`: NFC, Kleinbuchstaben, nur Buchstaben und Ziffern
    public static func normalize(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Buchstaben eines Textes (`str.isalpha`)
    public static func letters(_ text: String) -> Int { text.reduce(0) { $0 + ($1.isLetter ? 1 : 0) } }

    /// Seiten-Abdruck: Textseite -> SHA-256 des normalisierten Texts; Bildseite (fast kein Text) -> SHA-256 aus Datei-SHA
    /// und Seitennummer (gerenderte Pixel unterscheiden sich je Geraet und taugen nicht als gemeinsamer Abdruck)
    public static func pageHash(text: String, fileSHA: String, page: Int) -> String {
        if letters(text) >= minimumLetters {
            return SolutionSHA256.hex(Data(("text:" + normalize(text)).utf8))
        }
        return SolutionSHA256.hex(Data("image:\(fileSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(page)".utf8))
    }

    /// Name des Datensatzes beim Dienst: "<fileKey>#<page>", Seite 0 = Zusammenfassung der Datei
    public static func recordName(fileKey: String, page: Int) -> String { "\(fileKey)#\(page)" }

    /// Zerlegt einen Datensatznamen; nil, wenn er nicht die Form hat
    public static func parse(recordName: String) -> (fileKey: String, page: Int)? {
        let parts = recordName.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, isSHA256Hex(String(parts[0])), let page = Int(parts[1]), page >= 0 else { return nil }
        return (String(parts[0]), page)
    }
}

/// Ein Datensatz beim Dienst (CloudKit `DocIndex`, spaeter der StudiNow-Dienst), unabhaengig von CloudKit
public struct DocIndexRecord: Equatable, Sendable {
    public var fileKey: String
    public var page: Int
    /// Chiffrat (Base64, `DocIndexCrypto.seal`)
    public var payload: String
    public var version: Int
    public var createdAt: String
    /// Nutzerkennung des Erstellers beim Dienst (nur Anzeige/Moderation), leer in Tests
    public var ownerRecordName: String

    public init(fileKey: String, page: Int, payload: String, version: Int = DocIndexSchema.version, createdAt: String, ownerRecordName: String = "") {
        self.fileKey = fileKey; self.page = page; self.payload = payload; self.version = version
        self.createdAt = createdAt; self.ownerRecordName = ownerRecordName
    }

    public var recordName: String { DocIndexFingerprint.recordName(fileKey: fileKey, page: page) }
}

/// Zugang zu den Datensaetzen des Index (App: CloudKit, oeffentliche Datenbank; Tests: Speicher). Lesen geht fuer alle,
/// Schreiben nur angemeldet; `save` ueberschreibt nie einen fremden Datensatz (der Dienst lehnt das ab).
public protocol DocIndexCloud: Sendable {
    /// Alle Datensaetze einer Datei (Seite 0 und Seiten), `fileKey` ist das abfragbare Feld
    func records(fileKey: String) async throws -> [DocIndexRecord]
    func record(fileKey: String, page: Int) async throws -> DocIndexRecord?
    func save(_ record: DocIndexRecord) async throws
}

/// Verschluesselung der Eintraege (wie `CommunityDiscussion.seal/open`, eigener Namensraum)
public enum DocIndexCrypto {
    static let payloadVersion: UInt8 = 1
    static let saltBytes = 32, nonceBytes = 12, tagBytes = 16
    static let format = "uniflow-docindex"
    /// Chiffrat hoechstens so gross (Base64), groessere werden ungeprueft verworfen
    public static let maxPayloadChars = 256 * 1024

    /// Schluesselmaterial: Datei-SHA und Seiten-Abdruck (beides Hex, klein) - nur wer die Datei hat, rechnet es
    public static func keyMaterial(fileSHA: String, pageHash: String) -> Data {
        Data((fileSHA.lowercased() + "|" + pageHash.lowercased()).utf8)
    }

    static func keyInfo(page: Int) -> Data { Data("\(format)/v\(payloadVersion)|page:\(page)".utf8) }

    /// Zusatzdaten: binden das Chiffrat an Datei-Schluessel, Seite und Fassung des Schemas
    static func aad(fileKey: String, page: Int, version: Int) -> Data {
        Data("\(format)/v\(payloadVersion)|\(fileKey.lowercased())|\(page)|schema:\(version)".utf8)
    }

    /// Inhalt verschluesseln: Base64 aus Version (1 Byte), Salz (32), Nonce (12) und Chiffrat mit Tag
    public static func seal(_ content: JSONValue, fileSHA: String, pageHash: String, fileKey: String, page: Int, cipher: SolutionCipher,
                            version: Int = DocIndexSchema.version, salt: Data? = nil, nonce: Data? = nil) throws -> String {
        try sealRaw(content.serialized(sortedKeys: true), keyMaterial: keyMaterial(fileSHA: fileSHA, pageHash: pageHash), info: keyInfo(page: page),
                    aad: aad(fileKey: fileKey, page: page, version: version), cipher: cipher, salt: salt, nonce: nonce)
    }

    /// Entschluesseln; falscher Schluessel (andere Datei, andere Seite), veraendertes oder umgehaengtes Chiffrat werfen
    /// `SolutionError.decryptionFailed`
    public static func open(_ payload: String, fileSHA: String, pageHash: String, fileKey: String, page: Int, cipher: SolutionCipher,
                            version: Int = DocIndexSchema.version) throws -> JSONValue {
        let plaintext = try openRaw(payload, keyMaterial: keyMaterial(fileSHA: fileSHA, pageHash: pageHash), info: keyInfo(page: page),
                                    aad: aad(fileKey: fileKey, page: page, version: version), cipher: cipher)
        guard let json = try? JSONValue.parse(plaintext) else { throw SolutionError.decryptionFailed }
        return json
    }

    /// Die Byte-Form (Version, Salz, Nonce, Chiffrat mit Tag; Base64) - dieselbe fuer den Erklaerungsspeicher
    /// (`PageExplainCrypto`), der nur andere `info`- und Zusatzdaten mitgibt
    static func sealRaw(_ plaintext: Data, keyMaterial: Data, info: Data, aad: Data, cipher: SolutionCipher, salt: Data? = nil,
                        nonce: Data? = nil) throws -> String {
        let salt = salt ?? SolutionPackage.randomBytes(saltBytes), nonce = nonce ?? SolutionPackage.randomBytes(nonceBytes)
        guard salt.count == saltBytes, nonce.count == nonceBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        let sealed = try cipher.seal(plaintext, keyMaterial: keyMaterial, salt: salt, info: info, nonce: nonce, aad: aad)
        guard sealed.count == plaintext.count + tagBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        return (Data([payloadVersion]) + salt + nonce + sealed).base64EncodedString()
    }

    static func openRaw(_ payload: String, keyMaterial: Data, info: Data, aad: Data, cipher: SolutionCipher) throws -> Data {
        guard payload.count <= maxPayloadChars, let raw = Data(base64Encoded: payload),
              raw.count > 1 + saltBytes + nonceBytes + tagBytes, raw.first == payloadVersion else { throw SolutionError.decryptionFailed }
        let bytes = [UInt8](raw)
        let salt = Data(bytes[1..<(1 + saltBytes)])
        let nonce = Data(bytes[(1 + saltBytes)..<(1 + saltBytes + nonceBytes)])
        let sealed = Data(bytes[(1 + saltBytes + nonceBytes)...])
        do {
            return try cipher.open(sealed, keyMaterial: keyMaterial, salt: salt, info: info, nonce: nonce, aad: aad)
        } catch {
            throw SolutionError.decryptionFailed
        }
    }

    /// Seiten-Abdruck der Zusammenfassung (Seite 0): der Abdruck aller Seiten-Abdruecke, damit auch Seite 0 an den
    /// Inhalt der Datei gebunden ist
    public static func summaryHash(pageHashes: [String]) -> String {
        SolutionSHA256.hex(Data(("summary:" + pageHashes.joined(separator: ",")).utf8))
    }
}
