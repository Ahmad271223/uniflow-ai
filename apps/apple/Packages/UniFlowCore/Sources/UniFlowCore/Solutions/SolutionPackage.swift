import Foundation

// Loesungspaket "uniflow-solution", Formatversion 1 (docs/LOESUNGEN-TEILEN.md).
//
// Ein Paket enthaelt AUSSCHLIESSLICH eigene Anmerkungen (Objekte je Seite wie im Notizmodell, ohne `pkdrawing`) und
// eingebettete eigene Bilder, nie die Original-PDF, Seitenbilder oder PDF-Bytes. Die Zuordnung zur Original-PDF des
// Empfaengers laeuft ueber den SHA-256 der unveraenderten PDF-Datei (Fingerabdruck) und den 1-basierten
// PDF-Seitenindex.
//
// Datei (*.uniflowsolution, UTF-8-JSON):
//   { "format": "uniflow-solution", "formatVersion": 1, "header": {...}, "ciphertext": "<Base64>" }
// Kopf (Klartext, als AAD authentifiziert): Loesungs-ID, Erstellungsdatum, Anzeigename, Fingerabdruck und Seitenzahl
// des Originals, Anzahl Seiten/Bilder/fehlender Bilder, Verfahren, Salz, Nonce, Klartextgroesse.
// Inhalt (verschluesselt): `SolutionContent` als JSON.
//
// Sicherheit und Grenzen (ehrlich): Der Schluessel wird per HKDF-SHA256 aus den VOLLSTAENDIGEN Bytes der Original-PDF
// abgeleitet (zufaelliges Salz, Info = Formatkennung + Loesungs-ID), nie aus dem Fingerabdruck, denn der steht im
// Klartext im Kopf. Lesen kann das Paket also nur, wer genau diese Datei besitzt. Das beweist KEINE
// Kursberechtigung: Stud.IP-Dateien sind fuer alle Kursteilnehmer gleich und lassen sich weitergeben. Fuer eine
// Online-Community braucht es zusaetzlich eine echte Berechtigungspruefung auf dem Dienst.

/// Fehler beim Erzeugen, Lesen und Oeffnen eines Loesungspakets (Meldungen fuer die Oberflaeche).
public enum SolutionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Datei oder Inhalt groesser als erlaubt.
    case tooLarge
    /// Keine UniFlow-Loesung (kein JSON, falsche Formatkennung).
    case notASolution
    case unsupportedVersion(Int)
    /// Kopf unvollstaendig oder ungueltig (Feld).
    case invalidHeader(String)
    /// Paket gehoert zu einer anderen PDF (Fingerabdruck passt nicht).
    case fingerprintMismatch
    /// Entschluesselung gescheitert: andere PDF-Datei oder manipuliertes Paket.
    case decryptionFailed
    /// Inhalt ungueltig (Feld).
    case invalidContent(String)
    case unsupportedObjectType(String)
    case nonFiniteNumber
    /// Es sollte etwas mit PDF-Daten geteilt werden (nie erlaubt).
    case containsPDFData
    case nothingSelected
    /// Auf den gewaehlten Seiten gibt es kein einziges eigenes Notizobjekt (es entsteht kein leeres Paket).
    case noOwnNotes
    /// Eingebettetes Bild mit zu grossen Pixelmassen (Schutz vor Speicherabbruch beim Anzeigen).
    case imageTooLarge
    /// Eine andere Loesung mit derselben Loesungs-ID ist schon gespeichert (sie bleibt erhalten).
    case conflictingSolution
    /// Fehler auf einer bestimmten Seite beim Erzeugen (Seitenbezeichnung fuer den Dialog).
    indirect case onPage(String, SolutionError)

    public var description: String {
        switch self {
        case .tooLarge: return "Die Lösung ist zu groß."
        case .notASolution: return "Die Datei ist keine UniFlow-Lösung."
        case .unsupportedVersion(let v): return "Diese Lösung hat Formatversion \(v) – bitte UniFlow aktualisieren."
        case .invalidHeader(let f): return "Die Lösung ist beschädigt (Kopf: \(f))."
        case .fingerprintMismatch:
            return "Diese Lösung gehört zu einer anderen PDF-Datei (oder einer anderen Fassung). Sie wird hier nicht angezeigt."
        case .decryptionFailed:
            return "Die Lösung lässt sich mit dieser PDF-Datei nicht öffnen – andere Fassung der Datei oder beschädigtes Paket."
        case .invalidContent(let f): return "Die Lösung ist beschädigt (Inhalt: \(f))."
        case .unsupportedObjectType(let t): return "Die Lösung enthält einen unbekannten Objekttyp („\(t)“)."
        case .nonFiniteNumber: return "Die Lösung enthält ungültige Zahlen."
        case .containsPDFData: return "Geteilt werden dürfen nur eigene Notizen – PDF-Inhalte sind nicht erlaubt."
        case .nothingSelected: return "Keine Seite ausgewählt."
        case .noOwnNotes:
            return "Auf den gewählten Seiten gibt es keine eigenen Notizen. Schreibe oder zeichne zuerst etwas – leere Lösungen werden nicht geteilt."
        case .imageTooLarge: return "Die Lösung enthält ein Bild mit zu großen Abmessungen. Sie wird nicht angezeigt."
        case .conflictingSolution:
            return "Eine andere Lösung mit derselben Kennung ist schon gespeichert. Die vorhandene Lösung bleibt erhalten."
        case .onPage(let page, let inner): return "\(page): \(inner.description)"
        }
    }

    public var errorDescription: String? { description }

    /// Fehler ohne Seitenangabe.
    public var withoutPage: SolutionError {
        if case .onPage(_, let inner) = self { return inner.withoutPage }
        return self
    }
}

/// Verschluesselung des Paketinhalts. Der Kern bringt bewusst keine eigene AES-Umsetzung mit (Foundation-only, Linux);
/// die App nutzt CryptoKit: HKDF-SHA256 (Eingabe `keyMaterial` = Original-PDF-Bytes, `salt`, `info`) und AES-256-GCM
/// mit `nonce` (12 Byte) und `aad`. Ergebnis von `seal` = Chiffrat + 16-Byte-Tag.
public protocol SolutionCipher: Sendable {
    /// SHA-256 als 64 Hexziffern (Standard: `SolutionSHA256`, die App nimmt CryptoKit).
    func sha256Hex(_ data: Data) -> String
    func seal(_ plaintext: Data, keyMaterial: Data, salt: Data, info: Data, nonce: Data, aad: Data) throws -> Data
    func open(_ sealed: Data, keyMaterial: Data, salt: Data, info: Data, nonce: Data, aad: Data) throws -> Data
}

extension SolutionCipher {
    public func sha256Hex(_ data: Data) -> String { SolutionSHA256.hex(data) }
}

/// Eingebettetes eigenes Bild (PNG oder JPEG), Schluessel ist `src` des Bildobjekts.
public struct SolutionImage: Equatable, Sendable {
    public var mime: String
    public var data: Data

    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }

    public static let allowedMimes: Set<String> = ["image/png", "image/jpeg"]

    /// Bildtyp aus den ersten Bytes; `nil` = kein PNG/JPEG.
    public static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 4, b == [0x89, 0x50, 0x4E, 0x47] { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        return nil
    }
}

/// Eine geteilte Seite: Zuordnung zur Original-PDF bzw. eigene Leerseite, dazu ihre Objekte unveraendert.
public struct SolutionPage: Equatable, Sendable {
    public enum Kind: String, Sendable { case pdf, blank }

    /// Seitenschluessel beim Absender (nur Information und Reihenfolge).
    public var key: String
    public var kind: Kind
    /// 1-basierte Seite der Original-PDF (nur `pdf`).
    public var pdfIndex: Int?
    /// Seitenbox ohne Drehung in PDF-Punkten (PDF: CropBox; Leerseite: `w`/`h` aus `pageOrder`).
    public var width: Double
    public var height: Double
    /// Drehung der angezeigten Seite beim Absender (PDF-`/Rotate` + `extraRotation`); in diesen Koordinaten stehen
    /// die Objekte.
    public var rotation: Int
    /// Zusaetzliche Drehung aus `pageOrder` beim Absender (Information).
    public var extraRotation: Int
    /// Vorlage der Leerseite (blank, lined, grid, dotted, mm, cornell).
    public var template: String?
    /// Objekte 1:1 aus `pages[key].objects` (alle Felder, auch unbekannte).
    public var objects: [JSONValue]

    public init(key: String, kind: Kind, pdfIndex: Int?, width: Double, height: Double, rotation: Int,
                extraRotation: Int = 0, template: String? = nil, objects: [JSONValue]) {
        self.key = key
        self.kind = kind
        self.pdfIndex = pdfIndex
        self.width = width
        self.height = height
        self.rotation = SolutionGeometry.normalized(rotation)
        self.extraRotation = SolutionGeometry.normalized(extraRotation)
        self.template = template
        self.objects = objects
    }

    /// Groesse der Seite, wie der Absender sie gesehen hat (Koordinatenraum der Objekte).
    public var displaySize: (width: Double, height: Double) {
        SolutionGeometry.displaySize(width: width, height: height, rotation: rotation)
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "key": .string(key), "kind": .string(kind.rawValue),
            "width": .number(width), "height": .number(height),
            "rotation": .number(Double(rotation)), "extraRotation": .number(Double(extraRotation)),
            "objects": .array(objects),
        ]
        if let pdfIndex { o["pdfIndex"] = .number(Double(pdfIndex)) }
        if let template { o["template"] = .string(template) }
        return .object(o)
    }

    init(json: JSONValue, pdfPageCount: Int) throws {
        guard case .object = json else { throw SolutionError.invalidContent("Seite") }
        guard let key = json["key"]?.string, !key.isEmpty, key.count <= 64 else { throw SolutionError.invalidContent("Seitenschlüssel") }
        guard let kindRaw = json["kind"]?.string, let kind = Kind(rawValue: kindRaw) else {
            throw SolutionError.invalidContent("Seitenart")
        }
        guard let w = json["width"]?.double, let h = json["height"]?.double, w > 0, h > 0,
              w <= SolutionLimits.maxPageSide, h <= SolutionLimits.maxPageSide else {
            throw SolutionError.invalidContent("Seitengröße")
        }
        guard let r = SolutionValidator.exactInt(json["rotation"]), r % 90 == 0, (0..<360).contains(r),
              let er = SolutionValidator.exactInt(json["extraRotation"]), er % 90 == 0, (0..<360).contains(er) else {
            throw SolutionError.invalidContent("Drehung")
        }
        var pdfIndex: Int?
        var template: String?
        switch kind {
        case .pdf:
            guard let i = SolutionValidator.exactInt(json["pdfIndex"]), i >= 1, i <= pdfPageCount else {
                throw SolutionError.invalidContent("PDF-Seite")
            }
            pdfIndex = i
        case .blank:
            guard json["pdfIndex"] == nil else { throw SolutionError.invalidContent("Leerseite mit PDF-Seite") }
            if let t = json["template"] {
                guard let s = t.string, PageOrder.templates.contains(s) else { throw SolutionError.invalidContent("Vorlage") }
                template = s
            }
        }
        guard let objects = json["objects"]?.array else { throw SolutionError.invalidContent("Objekte") }
        guard objects.count <= SolutionLimits.maxObjectsPerPage else { throw SolutionError.tooLarge }
        for o in objects { try SolutionValidator.validateObject(o) }
        self.init(key: key, kind: kind, pdfIndex: pdfIndex, width: w, height: h, rotation: r, extraRotation: er,
                  template: template, objects: objects)
    }
}

/// Grenzen gegen zu grosse oder boesartige Pakete.
public enum SolutionLimits {
    public static let maxPlaintextBytes = 48 << 20
    /// Dateigrenze beim Empfaenger: Base64 des groessten Chiffrats (Klartext plus 16 Byte Tag) und 1 MB fuer Kopf
    /// und JSON-Rahmen. So laesst sich alles oeffnen, was `seal` an der Klartextgrenze erzeugt (rund 65 MB).
    public static let maxPackageBytes = (maxPlaintextBytes + SolutionPackage.tagBytes + 2) / 3 * 4 + (1 << 20)
    public static let maxPages = 2_000
    public static let maxObjectsPerPage = 20_000
    public static let maxObjects = 200_000
    public static let maxImages = 200
    public static let maxImageBytes = 10 << 20
    /// Pixelmasse eingebetteter Bilder: ein kleines PNG kann sonst zu vielen Gigabyte entpacken (die App prueft die
    /// Masse beim Oeffnen ohne zu dekodieren und verkleinert eigene Bilder beim Teilen).
    public static let maxImageSide = 8_192
    public static let maxImagePixels = 16_777_216
    public static let maxPDFPages = 100_000
    /// 200 Zoll, groesste Seite nach PDF-Spezifikation
    public static let maxPageSide = 14_400.0
    public static let maxDisplayName = 60
    public static let maxTitle = 200
}

/// Pruefungen, die beim Erzeugen und beim Oeffnen gleich laufen (was geteilt werden kann, laesst sich auch oeffnen).
public enum SolutionValidator {
    /// Objekttypen des gemeinsamen Notizformats (annotations.schema.json). Haftnotizen sind Textobjekte mit
    /// Hintergrund, Zeichnungen Striche und Formen.
    public static let allowedObjectTypes: Set<String> = ["stroke", "text", "shape", "image"]

    public static func validateObject(_ o: JSONValue) throws {
        guard case .object = o else { throw SolutionError.invalidContent("Objekt") }
        guard let type = o["type"]?.string else { throw SolutionError.invalidContent("Objekttyp") }
        guard allowedObjectTypes.contains(type) else { throw SolutionError.unsupportedObjectType(type) }
        if let id = o["id"], id.string == nil { throw SolutionError.invalidContent("Objekt-ID") }
        try checkFinite(o)
        try checkNoPDF(o)
    }

    /// Felder, die auf Daten verweisen oder Daten tragen (Bildquelle, Daten-URL): hier wird streng nach PDF gesucht.
    public static let referenceFields: Set<String> = ["src", "data", "url", "href", "file", "asset", "uri"]
    /// Freitext des Nutzers: wird nie auf PDF-Kennungen geprueft (eine Notiz "als application/pdf speichern" ist
    /// eigener Inhalt und darf geteilt werden).
    public static let proseFields: Set<String> = ["text"]

    /// Alle Zahlen endlich (der JSON-Leser macht aus 1e999 Unendlich).
    public static func checkFinite(_ v: JSONValue) throws {
        switch v {
        case .number(let d): if !d.isFinite { throw SolutionError.nonFiniteNumber }
        case .array(let a): for x in a { try checkFinite(x) }
        case .object(let o): for x in o.values { try checkFinite(x) }
        default: break
        }
    }

    /// Zusatzsicherung (Heuristik), keine Garantie: Die eigentliche Garantie ist der Aufbau des Builders, der nur
    /// eigene Objekte uebernimmt (keine asset-Seiten, kein `pkdrawing`, keine PDF-Daten); eingebettete Bilder muessen
    /// PNG/JPEG sein. Diese Pruefung faengt zusaetzlich offensichtliche PDF-Daten ab:
    /// - Verweis- und Datenfelder (`referenceFields`): kein `application/pdf`, `%PDF-` oder `JVBERi0` (Base64 von
    ///   "%PDF-") im Wert.
    /// - uebrige Werte ausser Freitext (`proseFields`): beginnen nicht mit `%PDF-`, `JVBERi0` oder
    ///   `data:application/pdf`.
    /// Base64 einer PDF in anderer Ausrichtung (nicht ab Byte 0) erkennt sie nicht.
    public static func checkNoPDF(_ v: JSONValue, field: String? = nil) throws {
        switch v {
        case .string(let s):
            let f = field?.lowercased() ?? ""
            if proseFields.contains(f) { return }
            if referenceFields.contains(f) {
                if s.contains("%PDF-") || s.contains("JVBERi0") || s.lowercased().contains("application/pdf") {
                    throw SolutionError.containsPDFData
                }
            } else {
                let t = s.drop(while: { $0.isWhitespace })
                if t.hasPrefix("%PDF-") || t.hasPrefix("JVBERi0") || t.lowercased().hasPrefix("data:application/pdf") {
                    throw SolutionError.containsPDFData
                }
            }
        case .array(let a): for x in a { try checkNoPDF(x, field: field) }
        case .object(let o):
            for (k, x) in o {
                if k.contains("%PDF-") { throw SolutionError.containsPDFData }
                try checkNoPDF(x, field: k)
            }
        default: break
        }
    }

    /// Ganze Zahl nur, wenn der Wert genau ganzzahlig ist (90.5 ist keine Drehung).
    static func exactInt(_ v: JSONValue?) -> Int? {
        guard let d = v?.double, d.isFinite, d == d.rounded(), abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }

    static func isHex64(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func isUUID(_ s: String) -> Bool { s.count == 36 && UUID(uuidString: s) != nil }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

/// Entschluesselter Inhalt eines Pakets.
public struct SolutionContent: Equatable, Sendable {
    public static let format = "uniflow-solution-content"

    public var solutionID: String
    /// ISO 8601 (UTC, Sekunden)
    public var createdAt: String
    public var title: String
    /// Leer = anonym.
    public var displayName: String
    /// SHA-256 der unveraenderten Original-PDF-Datei (64 Hexziffern).
    public var fingerprint: String
    public var pdfPageCount: Int
    public var pages: [SolutionPage]
    /// Eingebettete Bilder nach `src`.
    public var images: [String: SolutionImage]
    /// Bilder, die beim Absender nicht verfuegbar waren (fehlen im Paket).
    public var missingImages: [String]

    public init(solutionID: String, createdAt: String, title: String, displayName: String, fingerprint: String,
                pdfPageCount: Int, pages: [SolutionPage], images: [String: SolutionImage] = [:], missingImages: [String] = []) {
        self.solutionID = solutionID
        self.createdAt = createdAt
        self.title = title
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.pdfPageCount = pdfPageCount
        self.pages = pages
        self.images = images
        self.missingImages = missingImages
    }

    public var objectCount: Int { pages.reduce(0) { $0 + $1.objects.count } }

    public var json: JSONValue {
        .object([
            "format": .string(SolutionContent.format), "formatVersion": .number(Double(SolutionPackage.formatVersion)),
            "solutionId": .string(solutionID), "createdAt": .string(createdAt), "title": .string(title),
            "displayName": .string(displayName),
            "document": .object(["sha256": .string(fingerprint), "pageCount": .number(Double(pdfPageCount))]),
            "pages": .array(pages.map(\.json)),
            "images": .object(images.mapValues { .object(["mime": .string($0.mime), "data": .string($0.data.base64EncodedString())]) }),
            "missingImages": .array(missingImages.map { .string($0) }),
        ])
    }

    /// Liest und prueft den Inhalt vollstaendig (Typen, Zahlen, Grenzen, keine PDF-Daten).
    public init(json: JSONValue) throws {
        guard case .object = json, json["format"]?.string == SolutionContent.format else {
            throw SolutionError.invalidContent("Formatkennung")
        }
        guard let v = SolutionValidator.exactInt(json["formatVersion"]) else { throw SolutionError.invalidContent("Formatversion") }
        guard v == SolutionPackage.formatVersion else { throw SolutionError.unsupportedVersion(v) }
        try SolutionValidator.checkFinite(json)
        guard let id = json["solutionId"]?.string, SolutionValidator.isUUID(id) else { throw SolutionError.invalidContent("Lösungs-ID") }
        guard let created = json["createdAt"]?.string, SolutionValidator.parseDate(created) != nil else {
            throw SolutionError.invalidContent("Erstellungsdatum")
        }
        guard let title = json["title"]?.string, title.count <= SolutionLimits.maxTitle else { throw SolutionError.invalidContent("Titel") }
        guard let name = json["displayName"]?.string, name.count <= SolutionLimits.maxDisplayName else {
            throw SolutionError.invalidContent("Anzeigename")
        }
        guard let fp = json["document"]?["sha256"]?.string, SolutionValidator.isHex64(fp) else {
            throw SolutionError.invalidContent("Fingerabdruck")
        }
        guard let count = SolutionValidator.exactInt(json["document"]?["pageCount"]), count >= 1, count <= SolutionLimits.maxPDFPages else {
            throw SolutionError.invalidContent("Seitenzahl")
        }
        guard let rawPages = json["pages"]?.array, !rawPages.isEmpty else { throw SolutionError.invalidContent("Seiten") }
        guard rawPages.count <= SolutionLimits.maxPages else { throw SolutionError.tooLarge }
        var pages: [SolutionPage] = []
        var keys = Set<String>(), pdfIndices = Set<Int>()
        var total = 0
        for raw in rawPages {
            let p = try SolutionPage(json: raw, pdfPageCount: count)
            guard keys.insert(p.key).inserted else { throw SolutionError.invalidContent("doppelte Seite") }
            if let i = p.pdfIndex, !pdfIndices.insert(i).inserted { throw SolutionError.invalidContent("doppelte PDF-Seite") }
            total += p.objects.count
            guard total <= SolutionLimits.maxObjects else { throw SolutionError.tooLarge }
            pages.append(p)
        }
        guard let rawImages = json["images"]?.object else { throw SolutionError.invalidContent("Bilder") }
        guard rawImages.count <= SolutionLimits.maxImages else { throw SolutionError.tooLarge }
        var images: [String: SolutionImage] = [:]
        for (src, img) in rawImages {
            guard let mime = img["mime"]?.string, SolutionImage.allowedMimes.contains(mime),
                  let b64 = img["data"]?.string, let data = Data(base64Encoded: b64) else {
                throw SolutionError.invalidContent("Bild")
            }
            guard data.count <= SolutionLimits.maxImageBytes else { throw SolutionError.tooLarge }
            guard SolutionImage.sniff(data) == mime else { throw SolutionError.invalidContent("Bilddaten") }
            images[src] = SolutionImage(mime: mime, data: data)
        }
        guard let rawMissing = json["missingImages"]?.array else { throw SolutionError.invalidContent("fehlende Bilder") }
        let missing = try rawMissing.map { v -> String in
            guard let s = v.string else { throw SolutionError.invalidContent("fehlende Bilder") }
            return s
        }
        // Bildquellen sind Verweise: streng pruefen
        try SolutionValidator.checkNoPDF(.array(missing.map { .string($0) }), field: "src")
        try SolutionValidator.checkNoPDF(.array(images.keys.map { .string($0) }), field: "src")
        self.init(solutionID: id.lowercased(), createdAt: created, title: title, displayName: name, fingerprint: fp,
                  pdfPageCount: count, pages: pages, images: images, missingImages: missing)
    }
}

/// Kopfdaten (Klartext, authentifiziert).
public struct SolutionHeader: Equatable, Sendable {
    public static let cipherName = "AES-256-GCM"
    public static let kdfName = "HKDF-SHA256"
    public static let keyMaterialName = "original-pdf-bytes"

    public var solutionID: String
    public var createdAt: String
    public var displayName: String
    public var fingerprint: String
    public var pdfPageCount: Int
    public var pageCount: Int
    public var imageCount: Int
    public var missingImageCount: Int
    public var salt: Data
    public var nonce: Data
    public var plaintextBytes: Int

    public var json: JSONValue {
        .object([
            "solutionId": .string(solutionID), "createdAt": .string(createdAt), "displayName": .string(displayName),
            "document": .object(["sha256": .string(fingerprint), "pageCount": .number(Double(pdfPageCount))]),
            "contents": .object(["pages": .number(Double(pageCount)), "images": .number(Double(imageCount)),
                                 "missingImages": .number(Double(missingImageCount))]),
            "encryption": .object([
                "cipher": .string(SolutionHeader.cipherName), "kdf": .string(SolutionHeader.kdfName),
                "keyMaterial": .string(SolutionHeader.keyMaterialName),
                "salt": .string(salt.base64EncodedString()), "nonce": .string(nonce.base64EncodedString()),
                "plaintextBytes": .number(Double(plaintextBytes)),
            ]),
        ])
    }

    init(json h: JSONValue) throws {
        guard case .object = h else { throw SolutionError.invalidHeader("fehlt") }
        guard let id = h["solutionId"]?.string, SolutionValidator.isUUID(id) else { throw SolutionError.invalidHeader("Lösungs-ID") }
        guard let created = h["createdAt"]?.string, SolutionValidator.parseDate(created) != nil else {
            throw SolutionError.invalidHeader("Erstellungsdatum")
        }
        guard let name = h["displayName"]?.string, name.count <= SolutionLimits.maxDisplayName else {
            throw SolutionError.invalidHeader("Anzeigename")
        }
        guard let fp = h["document"]?["sha256"]?.string, SolutionValidator.isHex64(fp) else {
            throw SolutionError.invalidHeader("Fingerabdruck")
        }
        guard let count = SolutionValidator.exactInt(h["document"]?["pageCount"]), count >= 1, count <= SolutionLimits.maxPDFPages else {
            throw SolutionError.invalidHeader("Seitenzahl")
        }
        guard let pages = SolutionValidator.exactInt(h["contents"]?["pages"]), pages >= 1, pages <= SolutionLimits.maxPages,
              let images = SolutionValidator.exactInt(h["contents"]?["images"]), images >= 0, images <= SolutionLimits.maxImages,
              let missing = SolutionValidator.exactInt(h["contents"]?["missingImages"]), missing >= 0, missing <= SolutionLimits.maxObjects else {
            throw SolutionError.invalidHeader("Inhaltsangaben")
        }
        let e = h["encryption"]
        guard e?["cipher"]?.string == SolutionHeader.cipherName, e?["kdf"]?.string == SolutionHeader.kdfName,
              e?["keyMaterial"]?.string == SolutionHeader.keyMaterialName else {
            throw SolutionError.invalidHeader("Verfahren")
        }
        guard let saltB64 = e?["salt"]?.string, let salt = Data(base64Encoded: saltB64), salt.count == 32 else {
            throw SolutionError.invalidHeader("Salz")
        }
        guard let nonceB64 = e?["nonce"]?.string, let nonce = Data(base64Encoded: nonceB64), nonce.count == 12 else {
            throw SolutionError.invalidHeader("Nonce")
        }
        guard let size = SolutionValidator.exactInt(e?["plaintextBytes"]), size >= 1, size <= SolutionLimits.maxPlaintextBytes else {
            throw SolutionError.invalidHeader("Größe")
        }
        self.init(solutionID: id.lowercased(), createdAt: created, displayName: name, fingerprint: fp, pdfPageCount: count,
                  pageCount: pages, imageCount: images, missingImageCount: missing, salt: salt, nonce: nonce, plaintextBytes: size)
    }

    public init(solutionID: String, createdAt: String, displayName: String, fingerprint: String, pdfPageCount: Int,
                pageCount: Int, imageCount: Int, missingImageCount: Int, salt: Data, nonce: Data, plaintextBytes: Int) {
        self.solutionID = solutionID
        self.createdAt = createdAt
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.pdfPageCount = pdfPageCount
        self.pageCount = pageCount
        self.imageCount = imageCount
        self.missingImageCount = missingImageCount
        self.salt = salt
        self.nonce = nonce
        self.plaintextBytes = plaintextBytes
    }
}

/// Verschluesseltes Loesungspaket (Inhalt der Datei *.uniflowsolution).
public struct SolutionPackage: Equatable, Sendable {
    public static let format = "uniflow-solution"
    public static let formatVersion = 1
    public static let fileExtension = "uniflowsolution"
    /// Exportierter Dokumenttyp der App (project.yml, UTExportedTypeDeclarations).
    public static let typeIdentifier = "de.uniflow.solution"
    static let tagBytes = 16

    public var header: SolutionHeader
    /// Chiffrat + 16-Byte-Tag.
    public var ciphertext: Data

    public init(header: SolutionHeader, ciphertext: Data) {
        self.header = header
        self.ciphertext = ciphertext
    }

    /// HKDF-Info: Formatkennung + Version + Loesungs-ID (ein Schluessel je Paket, auch bei gleichem Salz).
    public static func keyInfo(solutionID: String) -> Data {
        Data("\(format)/v\(formatVersion)|\(solutionID.lowercased())".utf8)
    }

    /// Alles ausser dem Chiffrat, kanonisch (sortierte Schluessel): Zusatzdaten (AAD) der Verschluesselung. Jede
    /// Aenderung an Kopf, Format oder Version laesst die Entschluesselung scheitern.
    public var authenticatedHeader: Data { SolutionPackage.aad(header: header.json) }

    static func aad(header: JSONValue) -> Data {
        JSONValue.object(["format": .string(format), "formatVersion": .number(Double(formatVersion)), "header": header])
            .serialized(sortedKeys: true)
    }

    /// Datei-Inhalt (UTF-8-JSON, sortierte Schluessel).
    public func encoded() -> Data {
        JSONValue.object([
            "format": .string(SolutionPackage.format), "formatVersion": .number(Double(SolutionPackage.formatVersion)),
            "header": header.json, "ciphertext": .string(ciphertext.base64EncodedString()),
        ]).serialized(sortedKeys: true)
    }

    /// Felder der Datei auf oberster Ebene (genau diese, sonst abgewiesen).
    static let rootFields: Set<String> = ["format", "formatVersion", "header", "ciphertext"]

    /// Datei lesen und den Kopf pruefen (ohne PDF, ohne Entschluesselung). Wirft bei falschem Format, falscher
    /// Version, ungueltigem Kopf, unbekannten Feldern, falscher Groesse und nicht endlichen Zahlen. Laeuft auf
    /// ungeprueften fremden Bytes: nie eine Umwandlung, die abbrechen kann (`exactInt` statt `Int(Double)`).
    public static func decode(_ data: Data) throws -> SolutionPackage {
        guard data.count <= SolutionLimits.maxPackageBytes else { throw SolutionError.tooLarge }
        guard let root = try? JSONValue.parse(data), case .object(let fields) = root else { throw SolutionError.notASolution }
        guard root["format"]?.string == format else { throw SolutionError.notASolution }
        guard let v = SolutionValidator.exactInt(root["formatVersion"]) else { throw SolutionError.invalidHeader("Formatversion") }
        guard v == formatVersion else { throw SolutionError.unsupportedVersion(v) }
        // nur die Felder, die das Format kennt: alles ausser dem Chiffrat ist damit authentifiziert (AAD), es gibt
        // keinen unbemerkten Traeger fuer weitere Daten
        guard Set(fields.keys) == rootFields else { throw SolutionError.invalidHeader("unbekannte Felder") }
        try SolutionValidator.checkFinite(root)
        guard let rawHeader = root["header"] else { throw SolutionError.invalidHeader("fehlt") }
        let header = try SolutionHeader(json: rawHeader)
        // Kopf genau in der Form von Version 1: zusaetzliche oder anders geschriebene Felder werden abgewiesen (die AAD
        // wird aus dem geprueften Kopf neu gebildet und deckt damit genau diese Felder ab)
        guard rawHeader == header.json else { throw SolutionError.invalidHeader("unbekannte Felder") }
        guard let b64 = root["ciphertext"]?.string, let sealed = Data(base64Encoded: b64) else {
            throw SolutionError.invalidHeader("Chiffrat")
        }
        guard sealed.count == header.plaintextBytes + tagBytes else { throw SolutionError.invalidHeader("Größe") }
        return SolutionPackage(header: header, ciphertext: sealed)
    }

    /// Inhalt verschluesseln. `originalPDF` sind die unveraenderten Bytes der Datei, aus der der Editor die PDF laedt;
    /// ihr SHA-256 muss zum Fingerabdruck des Inhalts passen.
    public static func seal(_ content: SolutionContent, originalPDF: Data, cipher: SolutionCipher,
                            salt: Data? = nil, nonce: Data? = nil) throws -> SolutionPackage {
        guard cipher.sha256Hex(originalPDF) == content.fingerprint else { throw SolutionError.fingerprintMismatch }
        // dieselben Pruefungen wie beim Oeffnen: was geteilt wird, muss sich auch oeffnen lassen
        let checked = try SolutionContent(json: content.json)
        guard checked == content else { throw SolutionError.invalidContent("nicht verlustfrei") }
        let plaintext = content.json.serialized(sortedKeys: true)
        guard plaintext.count <= SolutionLimits.maxPlaintextBytes else { throw SolutionError.tooLarge }
        // keine pauschale Textsuche nach "%PDF-" mehr: eigener Freitext darf das enthalten; PDF-Daten in Verweisen und
        // Bildern sind oben schon abgewiesen (SolutionValidator.checkNoPDF, Bild nur PNG/JPEG)
        let header = SolutionHeader(
            solutionID: content.solutionID, createdAt: content.createdAt, displayName: content.displayName,
            fingerprint: content.fingerprint, pdfPageCount: content.pdfPageCount, pageCount: content.pages.count,
            imageCount: content.images.count, missingImageCount: content.missingImages.count,
            salt: salt ?? randomBytes(32), nonce: nonce ?? randomBytes(12), plaintextBytes: plaintext.count)
        let aad = SolutionPackage.aad(header: header.json)
        let sealed = try cipher.seal(plaintext, keyMaterial: originalPDF, salt: header.salt,
                                     info: keyInfo(solutionID: header.solutionID), nonce: header.nonce, aad: aad)
        guard sealed.count == plaintext.count + tagBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        return SolutionPackage(header: header, ciphertext: sealed)
    }

    /// Mit der eigenen Original-PDF entschluesseln und vollstaendig pruefen. Passt der Fingerabdruck nicht, wird gar
    /// nicht erst entschluesselt.
    public func open(originalPDF: Data, cipher: SolutionCipher) throws -> SolutionContent {
        guard cipher.sha256Hex(originalPDF) == header.fingerprint else { throw SolutionError.fingerprintMismatch }
        let plaintext: Data
        do {
            plaintext = try cipher.open(ciphertext, keyMaterial: originalPDF, salt: header.salt,
                                        info: SolutionPackage.keyInfo(solutionID: header.solutionID), nonce: header.nonce,
                                        aad: authenticatedHeader)
        } catch {
            throw SolutionError.decryptionFailed
        }
        guard plaintext.count == header.plaintextBytes else { throw SolutionError.invalidContent("Größe") }
        guard let json = try? JSONValue.parse(plaintext) else { throw SolutionError.invalidContent("JSON") }
        let content = try SolutionContent(json: json)
        guard content.solutionID == header.solutionID, content.fingerprint == header.fingerprint,
              content.pdfPageCount == header.pdfPageCount, content.createdAt == header.createdAt,
              content.displayName == header.displayName, content.pages.count == header.pageCount,
              content.images.count == header.imageCount, content.missingImages.count == header.missingImageCount else {
            throw SolutionError.invalidContent("passt nicht zum Kopf")
        }
        return content
    }

    static func randomBytes(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()            // kryptografisch sicher (arc4random_buf / getrandom)
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// Erstellungsdatum im Format des Pakets (UTC, Sekunden).
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
