import Foundation

// Erklaerungsspeicher ("Einmal erklaeren, alle profitieren", docs/ERKLAERUNGSSPEICHER-2026-11-04.md): die Antworten
// der KI-Hilfe fuer ganze Seiten (erklaeren, einfach erklaeren, zusammenfassen, Fachbegriffe, Aufgabe loesen, Hinweise)
// werden je Seiten-Abdruck geteilt - nur ohne Markierung und ohne eigene Frage. Der erste Studierende bekommt die
// Antwort live, jeder weitere mit derselben Seite sofort (0 Credits). Hoechstens drei Varianten je Schluessel wie bei
// den Wochentests; ein Datensatz wird nie ueberschrieben.
//
// Was der Dienst sieht: `fileKey` (HMAC des Datei-SHA), Seite, Modus, Variante, Fassung, Zeitpunkt und das Chiffrat.
// Nie Seitentext, nie Namen, nie ein Bild. Schluessel wie beim Dokument-Index (HKDF aus Datei-SHA + Seiten-Abdruck);
// die Zusatzdaten binden das Chiffrat an Datei, Seite, Modus, Variante und Formatfassung.
// Format der Datensaetze fuer den Dienst: packages/shared-contracts/page-explain.md (Python spiegelt es spaeter).

/// Regeln des Erklaerungsspeichers (reine Funktionen)
public enum PageExplain {
    /// Fassung des gespeicherten Formats (Inhalt `v`, Datensatz `version`, Zusatzdaten `format:1`)
    public static let version = 1
    /// hoechstens so viele Varianten je Schluessel (wie `TestShare.maxVariants`)
    public static let maxVariants = 3
    /// Variante 0 = nur auf diesem Geraet (kein Platz frei oder kein Dienst)
    public static let localOnlyVariant = 0
    /// Modi, deren Antwort fuer die ganze Seite geteilt wird; alles andere (Frage, Loesung pruefen, aehnliche Aufgabe,
    /// Karteikarten) bleibt live und ungeteilt
    public static let sharedModes: Set<String> = ["explain", "explain_simple", "summary", "terms", "steps", "hints"]
    /// so lang darf eine Antwort hoechstens sein, um geteilt zu werden (Zeichen); laengere bleiben lokal
    public static let maxTextChars = 24_000
    /// so viel Einordnung aus der Bibliothek geht in den Prompt einer eigenen Frage
    public static let indexContextChars = 1200

    /// Modus eines gespeicherten Datensatzes: ein geteilter Modus der KI-Hilfe oder ein Teil eines Laufs fuer das ganze
    /// Dokument (`DocExplain.isStoreMode`, 05.11.2026)
    public static func isStoredMode(_ mode: String) -> Bool { sharedModes.contains(mode) || DocExplain.isStoreMode(mode) }

    /// Wird die Antwort geteilt? Nur ein geteilter Modus fuer die ganze Seite: ohne markierten Text und ohne eigene Frage
    public static func isShareable(mode: String, selection: String, question: String) -> Bool {
        sharedModes.contains(mode) && PyText.strip(selection).isEmpty && PyText.strip(question).isEmpty
    }

    /// Name des Datensatzes beim Dienst: "<fileKey>#<page>#<mode>#<variant>"
    public static func recordName(fileKey: String, page: Int, mode: String, variant: Int) -> String {
        "\(fileKey)#\(page)#\(mode)#\(variant)"
    }

    /// Zerlegt einen Datensatznamen; nil, wenn er nicht die Form hat (Seite >= 1, geteilter Modus, Variante 1...3)
    public static func parse(recordName: String) -> (fileKey: String, page: Int, mode: String, variant: Int)? {
        let parts = recordName.split(separator: "#", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, DocIndexFingerprint.isSHA256Hex(String(parts[0])), let page = Int(parts[1]), page >= 1,
              isStoredMode(String(parts[2])), let variant = Int(parts[3]), (1...maxVariants).contains(variant) else { return nil }
        return (String(parts[0]), page, String(parts[2]), variant)
    }

    /// Freie Plaetze in aufsteigender Reihenfolge (leer, wenn alle drei belegt sind)
    public static func freeVariants(existing: Set<Int>) -> [Int] { (1...maxVariants).filter { !existing.contains($0) } }

    /// Naechster freier Platz fuer "Neu erklaeren lassen"; nil = alle belegt, die Antwort bleibt lokal
    public static func nextVariant(existing: Set<Int>) -> Int? { freeVariants(existing: existing).first }

    /// Welche Variante ein Leser nimmt: die niedrigste vorhandene
    public static func preferredVariant(existing: [Int]) -> Int? { existing.filter { (1...maxVariants).contains($0) }.min() }

    /// Eine lokal gespeicherte Antwort (fuer die Wahl ohne Datenbank)
    public struct LocalEntry: Equatable, Sendable {
        public var variant: Int
        /// ai (selbst gefragt) | cloud (uebernommen)
        public var source: String
        public var createdAt: String
        public init(variant: Int, source: String, createdAt: String) { self.variant = variant; self.source = source; self.createdAt = createdAt }
    }

    /// Woher die Antwort kommt
    public enum Choice: Equatable, Sendable {
        /// aus dem eigenen Zwischenspeicher (Index in `local`)
        case local(Int)
        /// aus dem Dienst, diese Variante
        case cloud(Int)
        /// live fragen
        case ai
    }

    /// Vorrang lokal -> Dienst -> KI: lokal die juengste Antwort (bei gleichem Zeitpunkt die zuerst genannte; der
    /// Aufrufer gibt die zuletzt gespeicherte zuerst), beim Dienst die niedrigste Variante; sonst live
    public static func choose(local: [LocalEntry], cloud: [Int]) -> Choice {
        if !local.isEmpty {
            var best = 0
            for i in local.indices where local[i].createdAt > local[best].createdAt { best = i }
            return .local(best)
        }
        if let v = preferredVariant(existing: cloud) { return .cloud(v) }
        return .ai
    }

    /// Ein Punkt des Vorwaermens: diese Seite in diesem Modus
    public struct PlanItem: Hashable, Sendable {
        public var page: Int
        public var mode: String
        public init(page: Int, mode: String) { self.page = page; self.mode = mode }
    }

    /// Plan fuer das Vorwaermen (Schalter "Vorab einordnen"): `basic` erzeugt keine Erklaerungen; `full` je Seite
    /// `explain` und fuer Seiten mit Aufgaben `steps`, nur was noch fehlt (`have`), Seiten aufsteigend
    public static func prewarmPlan(level: DocIndexPrewarmLevel, pageCount: Int, pagesWithTasks: Set<Int>, have: Set<PlanItem>) -> [PlanItem] {
        guard level == .full, pageCount >= 1 else { return [] }
        var out: [PlanItem] = []
        for p in 1...pageCount {
            let e = PlanItem(page: p, mode: "explain")
            if !have.contains(e) { out.append(e) }
            let s = PlanItem(page: p, mode: "steps")
            if pagesWithTasks.contains(p), !have.contains(s) { out.append(s) }
        }
        return out
    }

    /// Quellenmarken "[n]" entfernen: die Quellen des ersten Fragenden hat der naechste nicht
    public static func shareableText(_ answer: String) -> String {
        let s = citation.stringByReplacingMatches(in: answer, range: NSRange(answer.startIndex..., in: answer), withTemplate: "")
        return PyText.strip(s)
    }

    private static let citation = try! NSRegularExpression(pattern: #" ?\[\d{1,2}\]"#)

    /// Einordnung der Seite aus der Bibliothek als Zeilen fuer den Prompt einer eigenen Frage: Zusammenfassung,
    /// Begriffe, Elemente, Aufgaben (hoechstens `indexContextChars`); leer ohne Eintrag
    public static func indexContext(_ entry: DocIndexEntry) -> String {
        var lines: [String] = []
        if !entry.summary.isEmpty { lines.append("Zusammenfassung: \(entry.summary)") }
        if !entry.terms.isEmpty { lines.append("Begriffe: " + entry.terms.joined(separator: ", ")) }
        if !entry.elements.isEmpty {
            lines.append("Elemente: " + entry.elements.map { "\($0.order). \($0.typeLabel) \"\($0.title)\": \($0.explanation)" }.joined(separator: " "))
        }
        if !entry.tasks.isEmpty {
            lines.append("Aufgaben: " + entry.tasks.map { "\($0.label): \($0.asks)" }.joined(separator: " "))
        }
        return PyText.slice(lines.joined(separator: "\n"), 0, indexContextChars)
    }
}

/// Stufe des Vorwaermens nach dem Abgleich (Einstellung `uniflow.docIndexPrewarmLevel`): `basic` = Zusammenfassung
/// und Begriffe (Dokument-Index), `full` = dazu Erklaerungen und Loesungen (Erklaerungsspeicher)
public enum DocIndexPrewarmLevel: String, Sendable, CaseIterable {
    case basic, full
}

/// Ein Datensatz beim Dienst (CloudKit `PageExplain`, spaeter der StudiNow-Dienst), unabhaengig von CloudKit
public struct PageExplainRecord: Equatable, Sendable {
    public var fileKey: String
    public var page: Int
    public var mode: String
    public var variant: Int
    /// Chiffrat (Base64, `PageExplainCrypto.seal`)
    public var payload: String
    public var version: Int
    public var createdAt: String
    /// Nutzerkennung des Erstellers beim Dienst (nur Moderation), leer in Tests
    public var ownerRecordName: String

    public init(fileKey: String, page: Int, mode: String, variant: Int, payload: String, version: Int = PageExplain.version, createdAt: String,
                ownerRecordName: String = "") {
        self.fileKey = fileKey; self.page = page; self.mode = mode; self.variant = variant; self.payload = payload
        self.version = version; self.createdAt = createdAt; self.ownerRecordName = ownerRecordName
    }

    public var recordName: String { PageExplain.recordName(fileKey: fileKey, page: page, mode: mode, variant: variant) }
}

/// Zugang zu den Datensaetzen des Erklaerungsspeichers (App: CloudKit, oeffentliche Datenbank; Tests: Speicher).
public protocol PageExplainCloud: Sendable {
    /// Alle Varianten einer Seite in einem Modus (Variante aufsteigend)
    func records(fileKey: String, page: Int, mode: String) async throws -> [PageExplainRecord]
    /// Speichern; false, wenn der Platz schon belegt ist (nie ueberschreiben). Wirft bei Netz- und Kontofehlern.
    func save(_ record: PageExplainRecord) async throws -> Bool
}

/// Inhalt des verschluesselten Datensatzes: {v, page, pageHash, mode, variant, text, model, createdAt}
public struct PageExplainContent: Equatable, Sendable {
    public var page: Int
    public var pageHash: String
    public var mode: String
    public var variant: Int
    public var text: String
    public var model: String?
    public var createdAt: String

    public init(page: Int, pageHash: String, mode: String, variant: Int, text: String, model: String? = nil, createdAt: String) {
        self.page = page; self.pageHash = pageHash; self.mode = mode; self.variant = variant; self.text = text; self.model = model; self.createdAt = createdAt
    }

    public var json: JSONValue {
        ["v": .number(Double(PageExplain.version)), "page": .number(Double(page)), "pageHash": .string(pageHash), "mode": .string(mode),
         "variant": .number(Double(variant)), "text": .string(text), "model": model.map(JSONValue.string) ?? .null, "createdAt": .string(createdAt)]
    }

    public init?(json: JSONValue) {
        guard json["v"]?.int == PageExplain.version, let page = json["page"]?.int, let hash = json["pageHash"]?.string, let mode = json["mode"]?.string,
              let variant = json["variant"]?.int, let text = json["text"]?.string, let created = json["createdAt"]?.string, !text.isEmpty else { return nil }
        self.init(page: page, pageHash: hash, mode: mode, variant: variant, text: text, model: json["model"]?.string, createdAt: created)
    }
}

/// Verschluesselung der Erklaerungen: derselbe Schluesselstoff wie der Dokument-Index (Datei-SHA + Seiten-Abdruck),
/// eigener Namensraum; Zusatzdaten binden an Datei, Seite, Modus, Variante und Formatfassung
public enum PageExplainCrypto {
    static let format = "uniflow-pageexplain"

    static func keyInfo(page: Int, mode: String) -> Data { Data("\(format)/v\(DocIndexCrypto.payloadVersion)|page:\(page)|mode:\(mode)".utf8) }

    static func aad(fileKey: String, page: Int, mode: String, variant: Int, version: Int) -> Data {
        Data("\(format)/v\(DocIndexCrypto.payloadVersion)|\(fileKey.lowercased())|\(page)|\(mode)|\(variant)|format:\(version)".utf8)
    }

    public static func seal(_ content: PageExplainContent, fileSHA: String, pageHash: String, fileKey: String, cipher: SolutionCipher,
                            version: Int = PageExplain.version, salt: Data? = nil, nonce: Data? = nil) throws -> String {
        try DocIndexCrypto.sealRaw(content.json.serialized(sortedKeys: true), keyMaterial: DocIndexCrypto.keyMaterial(fileSHA: fileSHA, pageHash: pageHash),
                                   info: keyInfo(page: content.page, mode: content.mode),
                                   aad: aad(fileKey: fileKey, page: content.page, mode: content.mode, variant: content.variant, version: version),
                                   cipher: cipher, salt: salt, nonce: nonce)
    }

    /// Entschluesseln und pruefen: Inhalt muss zu Seite, Abdruck, Modus und Variante passen; sonst
    /// `SolutionError.decryptionFailed`
    public static func open(_ payload: String, fileSHA: String, pageHash: String, fileKey: String, page: Int, mode: String, variant: Int,
                            cipher: SolutionCipher, version: Int = PageExplain.version) throws -> PageExplainContent {
        let plaintext = try DocIndexCrypto.openRaw(payload, keyMaterial: DocIndexCrypto.keyMaterial(fileSHA: fileSHA, pageHash: pageHash),
                                                   info: keyInfo(page: page, mode: mode),
                                                   aad: aad(fileKey: fileKey, page: page, mode: mode, variant: variant, version: version), cipher: cipher)
        guard let json = try? JSONValue.parse(plaintext), let content = PageExplainContent(json: json),
              content.page == page, content.pageHash == pageHash, content.mode == mode, content.variant == variant else {
            throw SolutionError.decryptionFailed
        }
        return content
    }
}
