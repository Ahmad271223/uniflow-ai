import Foundation

/// Korrekturvorschlag (03.11.2026, Wunsch des Inhabers): Ein Mitglied der Community markiert auf einer fremden,
/// geteilten Loesung (Tinte und Marker auf den Seiten, Randnotizen an einer Stelle, dazu ein Begleittext) und schickt
/// das dem Ersteller. Die Loesung des Erstellers bleibt unveraendert; er sieht "Deine Lösung hat einen Korrekturhinweis
/// von <Pseudonym> bekommen" mit Öffnen / Ignorieren, die anderen Mitglieder sehen die Korrektur unter der Diskussion
/// der Loesung.
///
/// Format: dieselben Seiten wie im Loesungspaket (`SolutionPage`: CropBox ohne Drehung, `rotation` = Drehung der
/// angezeigten Seite beim Korrigierenden, Objekte in diesen Koordinaten), nur Striche (`type` = "stroke"), im
/// Klartext wie Formatversion 2 (`SolutionWire`, Punkte als ganze Zahlen), dann raw DEFLATE. Randnotizen haben x, y in
/// 0...1 der angezeigten Seite (von links oben) und einen Text.
///
/// Verschluesselung wie die Kommentare (`CommunityDiscussion`): Schluessel aus dem Community-Geheimnis per HKDF-SHA256
/// mit eigenem Salz je Korrektur, AES-256-GCM ueber `SolutionCipher`; die Zusatzdaten binden das Chiffrat an die
/// Ziel-Loesung und die Korrektur-ID (kein Umhaengen). Beim Dienst stehen nur Ziel-Loesung, Ersteller der Loesung,
/// Zeitpunkt und das Chiffrat.
public struct CommunityCorrection: Equatable, Sendable, Identifiable {
    /// Zustand beim Betrachter (nur lokal, je Geraet): offen (neu, zaehlt am Menuepunkt), gesehen (einmal geoeffnet:
    /// bleibt im Posteingang unter "Gesehen", zaehlt nicht mehr) oder ignoriert (weg)
    public enum Status: String, Sendable, CaseIterable { case open, seen, ignored }

    /// Randnotiz an einer Stelle der Seite
    public struct Note: Equatable, Sendable, Identifiable {
        public var id: String
        /// 0...1 von links oben, in der angezeigten Seite (`Page.rotation`)
        public var x: Double
        public var y: Double
        public var text: String

        public init(id: String = UUID().uuidString.lowercased(), x: Double, y: Double, text: String) {
            self.id = id
            self.x = x
            self.y = y
            self.text = text
        }
    }

    /// Korrektur einer PDF-Seite: Striche (Format der Loesungsseiten) und Randnotizen
    public struct Page: Equatable, Sendable {
        /// 1-basierte Seite der Original-PDF
        public var pdfIndex: Int
        /// CropBox ohne Drehung in PDF-Punkten
        public var width: Double
        public var height: Double
        /// Drehung der angezeigten Seite beim Korrigierenden (Koordinatenraum der Striche und Notizen)
        public var rotation: Int
        /// Strich-Objekte (`StrokeConverter`), Seitenpunkte der angezeigten Seite
        public var strokes: [JSONValue]
        public var notes: [Note]

        public init(pdfIndex: Int, width: Double, height: Double, rotation: Int = 0, strokes: [JSONValue] = [], notes: [Note] = []) {
            self.pdfIndex = pdfIndex
            self.width = width
            self.height = height
            self.rotation = SolutionGeometry.normalized(rotation)
            self.strokes = strokes
            self.notes = notes
        }

        /// Dieselbe Seite als Loesungsseite (fuer `ForeignLayerView` und die Vorschau)
        public var solutionPage: SolutionPage {
            SolutionPage(key: "c\(pdfIndex)", kind: .pdf, pdfIndex: pdfIndex, width: width, height: height, rotation: rotation,
                         objects: strokes)
        }

        public var isEmpty: Bool { strokes.isEmpty && notes.isEmpty }
    }

    public var id: String
    /// Loesung, die korrigiert wird (Kennung beim Dienst, klein geschrieben)
    public var targetSolutionID: String
    /// Pseudonym des Korrigierenden; leer = anonym
    public var pseudonym: String
    /// UTC, Sekunden (`SolutionPackage.timestamp`)
    public var createdAt: String
    /// Begleittext an den Ersteller (darf leer sein, wenn es Striche oder Notizen gibt)
    public var note: String
    public var pages: [Page]

    // vom Dienst, nicht im Chiffrat
    /// Nutzerkennung des Korrigierenden beim Dienst (Ersteller des Datensatzes)
    public var author: String = ""
    /// selbst geschickt (darf geloescht werden)
    public var isMine = false
    /// an die eigene Loesung gerichtet (Posteingang)
    public var isForMe = false
    /// Zustand beim Betrachter (`CommunityCorrectionStatusStore`)
    public var status: Status = .open
    /// feinere Reihenfolge bei gleicher Sekunde
    public var order = 0

    public init(id: String = UUID().uuidString.lowercased(), targetSolutionID: String, pseudonym: String,
                createdAt: String = SolutionPackage.timestamp(Date()), note: String = "", pages: [Page] = []) {
        self.id = id.lowercased()
        self.targetSolutionID = targetSolutionID.lowercased()
        self.pseudonym = pseudonym
        self.createdAt = createdAt
        self.note = note
        self.pages = pages
    }

    /// Name fuer die Oberflaeche ("Anonym" ohne Pseudonym)
    public var displayName: String { pseudonym.isEmpty ? CommunityDiscussion.anonymousName : pseudonym }
    public var strokeCount: Int { pages.reduce(0) { $0 + $1.strokes.count } }
    public var noteCount: Int { pages.reduce(0) { $0 + $1.notes.count } }
    /// nichts zu schicken (keine Striche, keine Notizen, kein Text)
    public var isEmpty: Bool { strokeCount == 0 && noteCount == 0 && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Seite zu einer PDF-Seite (1-basiert)
    public func page(pdfIndex: Int) -> Page? { pages.first { $0.pdfIndex == pdfIndex } }

    /// Hinweis im Posteingang des Erstellers
    public var inboxMessage: String { CommunityCorrections.inboxMessage(pseudonym: pseudonym) }

    /// Nur der Inhalt (ohne Angaben des Dienstes und den lokalen Zustand)
    public var content: CommunityCorrection {
        CommunityCorrection(id: id, targetSolutionID: targetSolutionID, pseudonym: pseudonym, createdAt: createdAt, note: note, pages: pages)
    }
}

/// Reine Funktionen zum Korrekturvorschlag: pruefen, verschluesseln, oeffnen, ordnen.
public enum CommunityCorrections {
    /// Begleittext und Text einer Randnotiz hoechstens so lang (wie ein Kommentar)
    public static let maxText = CommunityDiscussion.maxComment
    public static let maxNotesPerPage = 50
    public static let maxPages = 300
    /// Klartext hoechstens so gross (vor dem Packen)
    public static let maxPlaintextBytes = 8 << 20
    /// Chiffrat (Base64) hoechstens so gross: CloudKit erlaubt je Datensatz ~1 MB ohne Assets
    public static let maxPayloadChars = 750_000

    static let payloadVersion: UInt8 = 1
    static let saltBytes = 32, nonceBytes = 12, tagBytes = 16
    public static let format = "uniflow-community-correction"
    static let contentVersion = 2

    /// "Deine Lösung hat einen Korrekturhinweis von <Pseudonym> bekommen"
    public static func inboxMessage(pseudonym: String) -> String {
        let name = pseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Deine Lösung hat einen Korrekturhinweis von \(name.isEmpty ? CommunityDiscussion.anonymousName : name) bekommen"
    }

    // MARK: Pruefen

    static func cleanText(_ text: String, allowEmpty: Bool) throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty, !allowEmpty { throw CommunityServiceError.service("Die Randnotiz ist leer.") }
        guard t.unicodeScalars.count <= maxText else { throw CommunityServiceError.service("Höchstens \(maxText) Zeichen.") }
        return t
    }

    static func checkStroke(_ o: JSONValue) throws {
        try SolutionValidator.validateObject(o)
        guard o["type"]?.string == "stroke" else { throw SolutionError.unsupportedObjectType(o["type"]?.string ?? "") }
    }

    /// Korrektur pruefen und bereinigen (Texte getrimmt, leere Seiten weg, nach Seite sortiert). Wirft bei leerer
    /// Korrektur, ungueltiger Stelle, zu langen Texten, anderen Objekten als Strichen und zu vielen Seiten.
    public static func validated(_ c: CommunityCorrection) throws -> CommunityCorrection {
        var out = c.content
        guard !out.id.isEmpty, out.id.count <= 64, !out.targetSolutionID.isEmpty, out.targetSolutionID.count <= 64 else {
            throw SolutionError.invalidContent("Kennung")
        }
        guard out.pseudonym.count <= SolutionLimits.maxDisplayName else { throw SolutionError.invalidContent("Pseudonym") }
        out.note = try cleanText(c.note, allowEmpty: true)
        var pages: [CommunityCorrection.Page] = []
        for var p in c.pages {
            guard p.pdfIndex >= 1, p.pdfIndex <= SolutionLimits.maxPDFPages else { throw SolutionError.invalidContent("PDF-Seite") }
            guard p.width.isFinite, p.height.isFinite, p.width > 0, p.height > 0,
                  p.width <= SolutionLimits.maxPageSide, p.height <= SolutionLimits.maxPageSide else {
                throw SolutionError.invalidContent("Seitengröße")
            }
            guard p.rotation % 90 == 0 else { throw SolutionError.invalidContent("Drehung") }
            guard p.strokes.count <= SolutionLimits.maxObjectsPerPage else { throw SolutionError.tooLarge }
            for s in p.strokes { try checkStroke(s) }
            guard p.notes.count <= maxNotesPerPage else { throw CommunityServiceError.service("Höchstens \(maxNotesPerPage) Randnotizen je Seite.") }
            p.notes = try p.notes.map { n in
                guard n.x.isFinite, n.y.isFinite, (0...1).contains(n.x), (0...1).contains(n.y) else {
                    throw CommunityServiceError.service("Ungültige Stelle (x und y zwischen 0 und 1).")
                }
                guard !n.id.isEmpty, n.id.count <= 64 else { throw SolutionError.invalidContent("Notiz-ID") }
                return CommunityCorrection.Note(id: n.id, x: n.x, y: n.y, text: try cleanText(n.text, allowEmpty: false))
            }
            if !p.isEmpty { pages.append(p) }
        }
        guard Set(pages.map(\.pdfIndex)).count == pages.count else { throw SolutionError.invalidContent("doppelte Seite") }
        guard pages.count <= maxPages else { throw SolutionError.tooLarge }
        out.pages = pages.sorted { $0.pdfIndex < $1.pdfIndex }
        guard !out.isEmpty else { throw CommunityServiceError.service("Die Korrektur ist leer: markiere etwas oder schreibe eine Notiz.") }
        return out
    }

    // MARK: Klartext

    /// Klartext im Speicher (Striche als Zahlenlisten wie Version 1)
    static func json(_ c: CommunityCorrection, wire: Bool) throws -> JSONValue {
        let pages: [JSONValue] = try c.pages.map { p in
            guard case .object(var o) = p.solutionPage.json else { throw SolutionError.invalidContent("Seite") }
            if wire { o["objects"] = .array(try p.strokes.map(SolutionWire.encodeObject)) }
            o["notes"] = .array(p.notes.map { .object(["id": .string($0.id), "x": .number($0.x), "y": .number($0.y), "text": .string($0.text)]) })
            return .object(o)
        }
        return .object([
            "format": .string(format), "formatVersion": .number(Double(contentVersion)),
            "correctionID": .string(c.id), "solutionID": .string(c.targetSolutionID),
            "pseudonym": .string(c.pseudonym), "createdAt": .string(c.createdAt), "note": .string(c.note),
            "pages": .array(pages),
        ])
    }

    /// Klartext lesen (fremde Daten: alles pruefen, nie eine Umwandlung, die abbrechen kann)
    static func correction(json: JSONValue, wire: Bool) throws -> CommunityCorrection {
        guard json["format"]?.string == format else { throw SolutionError.invalidContent("Formatkennung") }
        guard let v = SolutionValidator.exactInt(json["formatVersion"]), v == contentVersion else {
            throw SolutionError.unsupportedVersion(SolutionValidator.exactInt(json["formatVersion"]) ?? 0)
        }
        try SolutionValidator.checkFinite(json)
        try SolutionWire.checkStrokeSizes(json)
        guard let id = json["correctionID"]?.string, let sid = json["solutionID"]?.string, let name = json["pseudonym"]?.string,
              let created = json["createdAt"]?.string, let note = json["note"]?.string, let rawPages = json["pages"]?.array else {
            throw SolutionError.invalidContent("Korrektur")
        }
        guard rawPages.count <= maxPages else { throw SolutionError.tooLarge }
        var pages: [CommunityCorrection.Page] = []
        for raw in rawPages {
            guard case .object(var o) = raw else { throw SolutionError.invalidContent("Seite") }
            if wire, let objects = o["objects"]?.array { o["objects"] = .array(try objects.map(SolutionWire.decodeObject)) }
            let sp = try SolutionPage(json: .object(o), pdfPageCount: SolutionLimits.maxPDFPages)
            guard sp.kind == .pdf, let index = sp.pdfIndex else { throw SolutionError.invalidContent("Seitenart") }
            guard let rawNotes = o["notes"]?.array, rawNotes.count <= maxNotesPerPage else { throw SolutionError.invalidContent("Notizen") }
            let notes = try rawNotes.map { n -> CommunityCorrection.Note in
                guard let nid = n["id"]?.string, let x = n["x"]?.double, let y = n["y"]?.double, let t = n["text"]?.string else {
                    throw SolutionError.invalidContent("Notiz")
                }
                return CommunityCorrection.Note(id: nid, x: x, y: y, text: t)
            }
            pages.append(CommunityCorrection.Page(pdfIndex: index, width: sp.width, height: sp.height, rotation: sp.rotation,
                                                  strokes: sp.objects, notes: notes))
        }
        let c = CommunityCorrection(id: id, targetSolutionID: sid, pseudonym: name, createdAt: created, note: note, pages: pages)
        let checked = try validated(c)
        // nur, was auch so geschrieben werden durfte (keine leeren Seiten, Texte schon getrimmt)
        guard checked == c else { throw SolutionError.invalidContent("Korrektur") }
        return checked
    }

    // MARK: Verschluesseln

    /// HKDF-Info: Format + Version + Ziel-Loesung
    static func keyInfo(solutionID: String) -> Data { Data("\(format)/v\(payloadVersion)|\(solutionID.lowercased())".utf8) }

    /// Zusatzdaten: binden das Chiffrat an Ziel-Loesung und Korrektur
    static func aad(solutionID: String, correctionID: String) -> Data {
        Data("\(format)/v\(payloadVersion)|\(solutionID.lowercased())|\(correctionID.lowercased())".utf8)
    }

    /// Korrektur pruefen, packen (Version 2 + raw DEFLATE) und verschluesseln: Base64 aus Version (1 Byte), Salz (32),
    /// Nonce (12) und Chiffrat mit Tag. Zu gross (`maxPayloadChars`) wirft eine verstaendliche Meldung.
    public static func seal(_ correction: CommunityCorrection, communitySecret: Data, cipher: SolutionCipher,
                            salt: Data? = nil, nonce: Data? = nil) throws -> String {
        let c = try validated(correction)
        let salt = salt ?? SolutionPackage.randomBytes(saltBytes), nonce = nonce ?? SolutionPackage.randomBytes(nonceBytes)
        guard salt.count == saltBytes, nonce.count == nonceBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        let plaintext = try json(c, wire: true).serialized(sortedKeys: true)
        guard plaintext.count <= maxPlaintextBytes else { throw tooLarge }
        let packed = try SolutionDeflate.deflate(plaintext)
        let sealed = try cipher.seal(packed, keyMaterial: communitySecret, salt: salt, info: keyInfo(solutionID: c.targetSolutionID),
                                     nonce: nonce, aad: aad(solutionID: c.targetSolutionID, correctionID: c.id))
        guard sealed.count == packed.count + tagBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        let out = (Data([payloadVersion]) + salt + nonce + sealed).base64EncodedString()
        guard out.count <= maxPayloadChars else { throw tooLarge }
        return out
    }

    static let tooLarge = CommunityServiceError.service("Die Korrektur ist zu groß. Markiere weniger Seiten oder schicke sie in Teilen.")

    /// Entschluesseln und vollstaendig pruefen; falscher Schluessel, veraendertes oder umgehaengtes Chiffrat werfen
    public static func open(_ payload: String, correctionID: String, solutionID: String, communitySecret: Data,
                            cipher: SolutionCipher) throws -> CommunityCorrection {
        guard payload.count <= maxPayloadChars, let raw = Data(base64Encoded: payload),
              raw.count > 1 + saltBytes + nonceBytes + tagBytes, raw.first == payloadVersion else { throw SolutionError.decryptionFailed }
        let bytes = [UInt8](raw)
        let salt = Data(bytes[1..<(1 + saltBytes)])
        let nonce = Data(bytes[(1 + saltBytes)..<(1 + saltBytes + nonceBytes)])
        let sealed = Data(bytes[(1 + saltBytes + nonceBytes)...])
        let packed: Data
        do {
            packed = try cipher.open(sealed, keyMaterial: communitySecret, salt: salt, info: keyInfo(solutionID: solutionID),
                                     nonce: nonce, aad: aad(solutionID: solutionID, correctionID: correctionID))
        } catch {
            throw SolutionError.decryptionFailed
        }
        let plaintext = try SolutionDeflate.inflate(packed, limit: maxPlaintextBytes)
        guard let json = try? JSONValue.parse(plaintext) else { throw SolutionError.invalidContent("JSON") }
        let c = try correction(json: json, wire: true)
        // Kopf im Chiffrat muss zu den Zusatzdaten passen
        guard c.id == correctionID.lowercased(), c.targetSolutionID == solutionID.lowercased() else {
            throw SolutionError.invalidContent("passt nicht zum Datensatz")
        }
        return c
    }

    // MARK: Liste

    /// Korrekturen fuer die Oberflaeche: ohne gesperrte Nutzer, neueste zuerst; `ignored` = lokal ignorierte IDs,
    /// `seen` = lokal schon geoeffnete (ignoriert geht vor)
    public static func list(_ corrections: [CommunityCorrection], me: String, solutionOwner: String? = nil,
                            blocked: Set<String> = [], ignored: Set<String> = [], seen: Set<String> = []) -> [CommunityCorrection] {
        corrections
            .filter { !blocked.contains($0.author) }
            .map { c in
                var c = c
                c.isMine = !me.isEmpty && c.author == me
                if let solutionOwner { c.isForMe = !me.isEmpty && solutionOwner == me }
                c.status = ignored.contains(c.id) ? .ignored : seen.contains(c.id) ? .seen : .open
                return c
            }
            .sorted { ($0.createdAt, $0.order, $0.id) > ($1.createdAt, $1.order, $1.id) }
    }

    /// Posteingang (an mich, nicht von mir, nicht ignoriert): offene und gesehene Hinweise
    public static func inbox(_ corrections: [CommunityCorrection]) -> [CommunityCorrection] {
        corrections.filter { $0.isForMe && !$0.isMine && $0.status != .ignored }
    }

    /// Offene (noch nicht geoeffnete) Hinweise des Posteingangs: das ist die Zahl am Menuepunkt "Community"
    public static func openInbox(_ corrections: [CommunityCorrection]) -> [CommunityCorrection] {
        inbox(corrections).filter { $0.status == .open }
    }

    /// Schon geoeffnete Hinweise des Posteingangs (Gruppe "Gesehen")
    public static func seenInbox(_ corrections: [CommunityCorrection]) -> [CommunityCorrection] {
        inbox(corrections).filter { $0.status == .seen }
    }
}

// MARK: - Lokal: Entwurf und Zustand

/// Unversendete Korrektur je Ziel-Loesung, bis sie geschickt oder verworfen ist (nur auf dem Geraet, im Container der
/// App wie die eigenen Notizen). Eine Datei je Loesung: `<id>.json` (Klartext Version 1, mit Pruefung beim Lesen).
public struct CommunityCorrectionDraftStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    func url(_ solutionID: String) -> URL {
        let safe = solutionID.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("correction-\(safe.isEmpty ? "leer" : safe).json")
    }

    /// Entwurf sichern; ein leerer Entwurf (nichts markiert, kein Text) loescht die Datei
    public func save(_ c: CommunityCorrection) throws {
        if c.isEmpty { try remove(solutionID: c.targetSolutionID); return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try CommunityCorrections.json(c.content, wire: false).serialized(sortedKeys: true)
        try data.write(to: url(c.targetSolutionID), options: .atomic)
    }

    /// Entwurf zur Loesung; nil = keiner (oder unlesbar)
    public func load(solutionID: String) -> CommunityCorrection? {
        guard let data = try? Data(contentsOf: url(solutionID)), let json = try? JSONValue.parse(data),
              json["format"]?.string == CommunityCorrections.format else { return nil }
        // ohne Pruefung auf "leer" (ein Entwurf darf z. B. eine noch leere Randnotiz haben): nur Grundform
        guard let id = json["correctionID"]?.string, let sid = json["solutionID"]?.string else { return nil }
        let pages: [CommunityCorrection.Page] = (json["pages"]?.array ?? []).compactMap { raw in
            guard let sp = try? SolutionPage(json: raw, pdfPageCount: SolutionLimits.maxPDFPages), let index = sp.pdfIndex else { return nil }
            let notes = (raw["notes"]?.array ?? []).compactMap { n -> CommunityCorrection.Note? in
                guard let nid = n["id"]?.string, let x = n["x"]?.double, let y = n["y"]?.double, let t = n["text"]?.string else { return nil }
                return CommunityCorrection.Note(id: nid, x: x, y: y, text: t)
            }
            return CommunityCorrection.Page(pdfIndex: index, width: sp.width, height: sp.height, rotation: sp.rotation,
                                            strokes: sp.objects.filter { $0["type"]?.string == "stroke" }, notes: notes)
        }
        guard sid.lowercased() == solutionID.lowercased() else { return nil }
        return CommunityCorrection(id: id, targetSolutionID: sid, pseudonym: json["pseudonym"]?.string ?? "",
                                   createdAt: json["createdAt"]?.string ?? SolutionPackage.timestamp(Date()),
                                   note: json["note"]?.string ?? "", pages: pages)
    }

    public func remove(solutionID: String) throws {
        let u = url(solutionID)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }

    /// Ziel-Loesungen mit Entwurf
    public func solutionIDs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasPrefix("correction-") && $0.hasSuffix(".json") }
            .compactMap { load(solutionID: String($0.dropFirst("correction-".count).dropLast(".json".count)))?.targetSolutionID }
            .sorted()
    }
}

/// Zustand der Korrekturen beim Betrachter (Gesehen und Ignorieren gelten nur auf diesem Geraet, der Dienst kennt sie
/// nicht): zwei Mengen von IDs, "ignoriert" und "gesehen". Ohne `defaults` nur im Arbeitsspeicher.
public final class CommunityCorrectionStatusStore: @unchecked Sendable {
    public static let key = "uniflow.community.corrections.ignored"
    public static let seenKey = "uniflow.community.corrections.seen"
    private let defaults: UserDefaults?
    private var memory: [String: Set<String>] = [:]
    private let lock = NSLock()

    public init(defaults: UserDefaults?) { self.defaults = defaults }

    private func read(_ key: String) -> Set<String> {
        defaults.map { Set($0.stringArray(forKey: key) ?? []) } ?? (memory[key] ?? [])
    }

    private func write(_ s: Set<String>, _ key: String) {
        if let defaults { defaults.set(s.sorted(), forKey: key) } else { memory[key] = s }
    }

    public func ignored() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return read(Self.key)
    }

    /// Schon geoeffnete Korrekturen (auch ignorierte koennen darin stehen; `status` gibt ignoriert den Vorrang)
    public func seen() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return read(Self.seenKey)
    }

    /// `.seen` merkt das Oeffnen (ignoriert bleibt davon unberuehrt: wer ignoriert hat, hat gesehen), `.ignored` legt
    /// die Korrektur weg, `.open` macht beides rueckgaengig
    public func set(_ status: CommunityCorrection.Status, id: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = id.lowercased()
        var ignored = read(Self.key), seen = read(Self.seenKey)
        switch status {
        case .ignored: ignored.insert(key)
        case .seen: ignored.remove(key); seen.insert(key)
        case .open: ignored.remove(key); seen.remove(key)
        }
        write(ignored, Self.key)
        write(seen, Self.seenKey)
    }

    public func status(id: String) -> CommunityCorrection.Status {
        let key = id.lowercased()
        if ignored().contains(key) { return .ignored }
        return seen().contains(key) ? .seen : .open
    }
}
