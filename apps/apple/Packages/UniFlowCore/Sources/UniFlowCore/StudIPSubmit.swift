import Foundation

// Abgeben aus der App (Entscheidung des Inhabers 05.11.2026, docs/ABGEBEN-STUDIP-2026-11-05.md): die eigene Loesung
// (PDF mit Notizen und eingefuegten Blaettern) in einen Ordner des Stud.IP-Kurses hochladen. Die einzigen schreibenden
// Anfragen der App an Stud.IP; nur auf ausdruecklichen Knopfdruck des Menschen ("Jetzt abgeben"), nie im Abgleich,
// nie wiederholt (ein zweites Hochladen legte eine zweite Datei an).
//
// Routen laut Stud.IP-Entwicklerdoku (docs.gitlab.studip.de/entwicklung/jsonapi/files/, gelesen 05.11.2026):
// - `GET courses/{id}/folders` flache Ordnerliste mit `folder-type`, `is-visible`, `is-readable`, `is-writable`,
//   Beziehung `parent`
// - `POST folders/{id}/file-refs` mit `multipart/form-data`, Feld `file`; Erfolg 201 mit `Location` der neuen Datei
// - `GET terms-of-use`, `PATCH file-refs/{id}/relationships/terms-of-use` (Lizenz; ohne Lizenz zeigt Stud.IP beim
//   Lehrenden "Lizenz fehlt")
// Ob ein Ordner Dateien annimmt, entscheidet laut Doku die Ordner-Implementierung (`is-writable`).

/// Ordner eines Kurses, in den der Mensch hochladen kann (oder der als Abgabeordner gerade geschlossen ist)
public struct StudIPUploadFolder: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let courseID: String
    public let name: String
    /// Pfad im Kurs ohne Wurzelordner ("Übungen/Abgabe Blatt 3"); leer fuer den Hauptordner
    public let path: String
    /// Stud.IP-Ordnertyp (`StandardFolder`, `HomeworkFolder`, `TimedFolder`, `RootFolder`, ...)
    public let folderType: String
    public let isWritable: Bool

    public init(id: String, courseID: String, name: String, path: String, folderType: String, isWritable: Bool) {
        self.id = id
        self.courseID = courseID
        self.name = name
        self.path = path
        self.folderType = folderType
        self.isWritable = isWritable
    }

    /// Hausaufgabenordner: Studierende sehen dort nur ihre eigenen Dateien (Abgabe)
    public var isHomework: Bool { folderType == "HomeworkFolder" }
    /// Zeitgesteuerter Ordner (Abgabezeitraum): ausserhalb des Zeitraums nicht beschreibbar
    public var isTimed: Bool { folderType == "TimedFolder" }
    /// Abgabeordner im weiten Sinn: Hausaufgabenordner, zeitgesteuert oder mit "Abgabe"/"Hausaufgabe" im Namen
    public var looksLikeSubmission: Bool {
        if isHomework || isTimed { return true }
        let n = (path.isEmpty ? name : path).lowercased()
        return ["abgabe", "hausaufgabe", "einreichung", "submission", "homework"].contains { n.contains($0) }
    }

    /// Anzeigename im Blatt
    public var label: String { path.isEmpty ? "Hauptordner" : path }
}

/// Ergebnis der Ordnersuche eines Kurses
public struct StudIPUploadFolders: Sendable, Equatable {
    /// beschreibbare Ordner, Abgabeordner zuerst, dann nach Pfad
    public var writable: [StudIPUploadFolder]
    /// Abgabeordner (Hausaufgaben, zeitgesteuert), die gerade keine Dateien annehmen: Frist vorbei oder noch nicht offen
    public var closedSubmissionFolders: [StudIPUploadFolder]

    public init(writable: [StudIPUploadFolder] = [], closedSubmissionFolders: [StudIPUploadFolder] = []) {
        self.writable = writable
        self.closedSubmissionFolders = closedSubmissionFolders
    }

    /// Vorauswahl: erster Hausaufgabenordner, sonst erster Abgabeordner, sonst nichts (der Mensch waehlt selbst)
    public var suggested: StudIPUploadFolder? {
        writable.first { $0.isHomework } ?? writable.first { $0.looksLikeSubmission }
    }
}

/// Fehler beim Abgeben (Anzeige im Blatt)
public enum StudIPUploadError: Error, Equatable, LocalizedError {
    /// Ordner nimmt keine Dateien an (403): keine Berechtigung, Abgabezeitraum vorbei oder noch nicht offen
    case notWritable
    /// Datei zu gross (413 oder Meldung von Stud.IP)
    case tooLarge
    /// Stud.IP verlangt fuer schreibende Anfragen mit Sitzungs-Cookie ein Sicherheits-Token (CSRF), das die App nicht hat
    case securityToken
    /// Transport kann nicht schreiben (Nachbildung ohne Schreibweg)
    case unsupported
    case http(Int)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notWritable:
            return "Dieser Ordner nimmt gerade keine Dateien an. Vielleicht ist die Abgabefrist vorbei oder der Ordner noch nicht geöffnet."
        case .tooLarge:
            return "Die Datei ist zu groß für Stud.IP. Schicke sie ohne Notizen oder verkleinere eingefügte Bilder."
        case .securityToken:
            return "Stud.IP hat das Hochladen aus der App abgelehnt (Sicherheitsprüfung). Öffne den Ordner in Stud.IP und lade die Datei dort hoch."
        case .unsupported:
            return "Abgeben ist hier nicht möglich."
        case .http(let s):
            return "Stud.IP antwortet mit HTTP \(s). Die Datei wurde nicht abgegeben."
        case .badResponse(let r):
            return "Unerwartete Antwort von Stud.IP: \(r)"
        }
    }
}

/// Eigene Angaben aus `users/me` fuer den Dateinamen
public struct StudIPOwnName: Sendable, Equatable {
    public let id: String
    public let familyName: String
    public let givenName: String

    public init(id: String, familyName: String, givenName: String) {
        self.id = id
        self.familyName = familyName
        self.givenName = givenName
    }
}

/// Ergebnis eines Hochladens
public struct StudIPUploadResult: Sendable, Equatable {
    /// Kennung der neuen Datei (aus `Location` oder dem Koerper), nil wenn Stud.IP keine nennt
    public let fileRefID: String?
    /// Lizenz "selbst verfasst, nicht veroeffentlicht" gesetzt
    public let licenseSet: Bool
    /// Seite in Stud.IP zum Nachsehen (Ordner im Kurs)
    public let webURL: URL

    public init(fileRefID: String?, licenseSet: Bool, webURL: URL) {
        self.fileRefID = fileRefID
        self.licenseSet = licenseSet
        self.webURL = webURL
    }
}

/// Regeln ohne Netz: Dateiname, Multipart-Koerper, Ordnerliste, Fehlerzuordnung
public enum StudIPSubmit {
    /// Stud.IP-Grundeinstellung fuer Studierende (`UPLOAD_TYPES`, Rolle autor) nach unserer Kenntnis 7 MB je Datei; die
    /// Hochschule kann mehr oder weniger erlauben (an der LUH unbekannt). Darueber zeigt das Blatt nur einen Hinweis.
    public static let typicalLimitBytes = 7 * 1024 * 1024

    /// Hinweis zur Groesse (nil = unauffaellig)
    public static func sizeNotice(bytes: Int) -> String? {
        guard bytes > typicalLimitBytes else { return nil }
        return "Die Datei ist \(megabytes(bytes)) groß. Manche Stud.IP-Ordner nehmen nur bis 7 MB an."
    }

    public static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        let f = mb < 10 ? String(format: "%.1f", mb) : String(format: "%.0f", mb)
        return f.replacingOccurrences(of: ".", with: ",") + " MB"
    }

    // MARK: Dateiname

    /// Vorschlag "Nachname_Blatt3.pdf": Nummer des Blatts aus dem Titel ("Übungsblatt 3", "Blatt_03", "Sheet 3",
    /// "Aufgabenblatt 3", "Übung 3", "Hausaufgabe 3"), sonst "Nachname_<Titel>.pdf". Ohne Nachnamen nur der Teil danach.
    public static func proposedFileName(familyName: String?, title: String) -> String {
        let name = safeComponent(familyName ?? "")
        let base: String
        if let n = sheetNumber(in: title) {
            base = "Blatt\(n)"
        } else {
            var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased().hasSuffix(".pdf") { t = String(t.dropLast(4)) }
            let c = safeComponent(t)
            base = c.isEmpty ? "Abgabe" : String(c.prefix(60))
        }
        return (name.isEmpty ? base : "\(name)_\(base)") + ".pdf"
    }

    /// Nummer eines Uebungsblatts im Titel (ohne fuehrende Nullen), nil ohne erkennbare Nummer
    public static func sheetNumber(in title: String) -> Int? {
        let t = title.lowercased()
        let pattern = #"(?<![a-zäöüß])(?:übungsblatt|uebungsblatt|aufgabenblatt|hausaufgabe|übung|uebung|blatt|sheet|exercise|assignment|ha|ü|ue|u)[\s_\-\.:#]*(?:nr\.?\s*)?0*(\d{1,3})(?!\d)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range(at: 1), in: t), let n = Int(t[r]) else { return nil }
        return n
    }

    /// Teil eines Dateinamens: Umlaute umschreiben, nur Buchstaben, Ziffern, "-", "_" und "."; Leerzeichen werden "_"
    public static func safeComponent(_ s: String) -> String {
        let map: [Character: String] = ["ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss"]
        var out = ""
        for ch in s.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let m = map[ch] { out += m; continue }
            if ch.isWhitespace || ch == "/" || ch == "\\" { out += "_"; continue }
            let folded = String(ch).folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
            for u in folded.unicodeScalars where u.isASCII && (CharacterSet.alphanumerics.contains(u) || "-_.".unicodeScalars.contains(u)) {
                out.unicodeScalars.append(u)
            }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
    }

    /// Vom Menschen geaenderter Name: sicher machen, ".pdf" anhaengen; nil, wenn nichts uebrig bleibt
    public static func finalFileName(_ input: String) -> String? {
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasSuffix(".pdf") { t = String(t.dropLast(4)) }
        let c = safeComponent(t)
        guard !c.isEmpty else { return nil }
        return String(c.prefix(120)) + ".pdf"
    }

    // MARK: Multipart

    /// `multipart/form-data` mit genau einer Datei im Feld `file` (wie `curl -F 'file=@…'` in der Stud.IP-Doku)
    public static func multipartBody(boundary: String, field: String = "file", fileName: String, mimeType: String, data: Data) -> Data {
        var body = Data()
        let safeName = fileName.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    public static func makeBoundary() -> String { "StudiNow-" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    // MARK: Ordner

    /// Ordnerliste aus `courses/{id}/folders` (flach, mit `parent`): beschreibbare und sichtbare Ordner, Abgabeordner
    /// zuerst; geschlossene Abgabeordner getrennt. Ohne Attribut `is-writable` (aeltere Stud.IP-Fassung) gilt ein Ordner
    /// als nicht beschreibbar: lieber kein Angebot als ein sicherer Fehler.
    public static func folders(from data: [JSONValue], courseID: String) -> StudIPUploadFolders {
        var names: [String: String] = [:], parents: [String: String] = [:], types: [String: String] = [:]
        for f in data {
            guard let id = f["id"]?.string else { continue }
            names[id] = (f["attributes"]?["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            types[id] = f["attributes"]?["folder-type"]?.string ?? ""
            if let p = f["relationships"]?["parent"]?["data"]?["id"]?.string { parents[id] = p }
        }
        // Pfad ohne Wurzelordner; ein unbekannter Elternordner (nicht in der Liste) beendet den Pfad
        func path(_ id: String) -> String {
            var parts: [String] = []
            var cur: String? = id
            var seen = Set<String>()
            while let c = cur, !seen.contains(c), types[c] != "RootFolder", let name = names[c] {
                seen.insert(c)
                parts.append(name)
                cur = parents[c]
            }
            return parts.reversed().filter { !$0.isEmpty }.joined(separator: "/")
        }
        var writable: [StudIPUploadFolder] = [], closed: [StudIPUploadFolder] = []
        for f in data {
            guard let id = f["id"]?.string else { continue }
            let a = f["attributes"]
            if a?["is-visible"]?.bool == false { continue }
            let type = types[id] ?? ""
            let folder = StudIPUploadFolder(id: id, courseID: courseID, name: names[id] ?? "", path: type == "RootFolder" ? "" : path(id),
                                            folderType: type, isWritable: a?["is-writable"]?.bool == true)
            if folder.isWritable { writable.append(folder) } else if folder.isHomework || folder.isTimed { closed.append(folder) }
        }
        let order: (StudIPUploadFolder, StudIPUploadFolder) -> Bool = { a, b in
            let ra = a.isHomework ? 0 : (a.looksLikeSubmission ? 1 : (a.path.isEmpty ? 3 : 2))
            let rb = b.isHomework ? 0 : (b.looksLikeSubmission ? 1 : (b.path.isEmpty ? 3 : 2))
            return ra != rb ? ra < rb : a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
        return StudIPUploadFolders(writable: writable.sorted(by: order), closedSubmissionFolders: closed.sorted(by: order))
    }

    /// Ordner im Browser (Dateibereich des Kurses an dieser Stelle)
    public static func folderWebURL(base: URL, courseID: String, folderID: String) -> URL {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: "\(b)/dispatch.php/course/files/index/\(folderID)?cid=\(courseID)")!
    }

    // MARK: Antworten

    /// Fehler aus einer Antwort auf das Hochladen (nil = Erfolg 2xx)
    public static func uploadError(status: Int, body: Data) -> StudIPUploadError? {
        if (200..<300).contains(status) { return nil }
        let text = String(decoding: body.prefix(4000), as: UTF8.self).lowercased()
        switch status {
        case 413: return .tooLarge
        case 403:
            if text.contains("csrf") || text.contains("security token") || text.contains("sicherheits") || text.contains("security_token") {
                return .securityToken
            }
            if isSizeMessage(text) { return .tooLarge }
            return .notWritable
        case 400, 422:
            return isSizeMessage(text) ? .tooLarge : .http(status)
        default:
            return .http(status)
        }
    }

    static func isSizeMessage(_ lower: String) -> Bool {
        ["zu groß", "zu gross", "too large", "too big", "maximal", "upload_max", "filesize", "dateigröße", "dateigroesse"].contains { lower.contains($0) }
    }

    /// Kennung der neuen Datei: letzter Teil von `Location` (…/file-refs/{id}) oder `data.id` im Koerper
    public static func fileRefID(location: String?, body: Data) -> String? {
        if let loc = location, let r = loc.range(of: "file-refs/") {
            let rest = loc[r.upperBound...].split(whereSeparator: { "/?#".contains($0) }).first.map(String.init)
            if let rest, !rest.isEmpty { return rest }
        }
        if let j = try? JSONValue.parse(body), let id = j["data"]?["id"]?.string { return id }
        return nil
    }

    /// Lizenz fuer eine eigene Abgabe: "Selbst verfasstes, nicht publiziertes Werk" (Stud.IP-Kennung `SELFMADE_NONPUB`),
    /// sonst ein Eintrag mit "selbst verfasst" und "nicht" im Namen
    public static func ownWorkLicenseID(_ list: [JSONValue]) -> String? {
        let ids = list.compactMap { $0["id"]?.string }
        if let exact = ids.first(where: { $0.uppercased() == "SELFMADE_NONPUB" }) { return exact }
        for t in list {
            let n = (t["attributes"]?["name"]?.string ?? "").lowercased()
            if (n.contains("selbst verfasst") || n.contains("selbstverfasst") || n.contains("self-made") || n.contains("selfmade")),
               n.contains("nicht") || n.contains("non") || n.contains("not") {
                return t["id"]?.string
            }
        }
        return nil
    }
}

extension StudIPClient {
    /// Eigene Angaben (`users/me`: `family-name`, `given-name`) fuer den Dateinamen
    public func ownName() async throws -> StudIPOwnName {
        let j = try await json("jsonapi.php/v1/users/me")
        guard let id = j["data"]?["id"]?.string else { throw StudIPError.badResponse("users/me ohne ID") }
        let a = j["data"]?["attributes"]
        return StudIPOwnName(id: id, familyName: a?["family-name"]?.string ?? "", givenName: a?["given-name"]?.string ?? "")
    }

    /// Ordner eines Kurses fuer das Abgeben (alle Seiten der flachen Liste). Nur lesend.
    public func uploadFolders(courseID: String) async throws -> StudIPUploadFolders {
        let (data, _) = try await list("jsonapi.php/v1/courses/\(courseID)/folders?page[limit]=200")
        return StudIPSubmit.folders(from: data, courseID: courseID)
    }

    /// Datei in einen Ordner hochladen (`POST folders/{id}/file-refs`, multipart, Feld `file`). Genau ein Versuch, keine
    /// Wiederholung (sonst laege die Abgabe doppelt da). Danach, ohne Einfluss auf den Erfolg, die Lizenz "selbst
    /// verfasst, nicht veroeffentlicht" setzen. Abgelaufene Sitzung: `StudIPError.sessionExpired`.
    public func upload(_ data: Data, fileName: String, mimeType: String = "application/pdf",
                       folder: StudIPUploadFolder, setLicense: Bool = true) async throws -> StudIPUploadResult {
        guard let writer = transport as? StudIPWritingTransport else { throw StudIPUploadError.unsupported }
        let boundary = StudIPSubmit.makeBoundary()
        let body = StudIPSubmit.multipartBody(boundary: boundary, fileName: fileName, mimeType: mimeType, data: data)
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)",
                       "Accept": StudIPClient.jsonAPI,
                       // fuer den Fall, dass Stud.IP Anfragen aus Skripten von der Formular-Pruefung ausnimmt; unbekannt
                       "X-Requested-With": "XMLHttpRequest"]
        let path = "jsonapi.php/v1/folders/\(folder.id)/file-refs"
        let reply = try await perform(path, anyStatus: true, retry: .none) {
            try await writer.send($0, method: "POST", headers: headers, body: body)
        }
        if reply.contentType.lowercased().contains("text/html"), (200..<300).contains(reply.status),
           OpencastParser.looksLikeLoginPage(String(decoding: reply.body.prefix(200_000), as: UTF8.self)) {
            throw StudIPError.sessionExpired
        }
        if let e = StudIPSubmit.uploadError(status: reply.status, body: reply.body) { throw e }
        let id = StudIPSubmit.fileRefID(location: reply.location, body: reply.body)
        var licensed = false
        if setLicense, let id { licensed = (try? await setOwnWorkLicense(fileRefID: id, writer: writer)) ?? false }
        return StudIPUploadResult(fileRefID: id, licenseSet: licensed,
                                  webURL: StudIPSubmit.folderWebURL(base: base, courseID: folder.courseID, folderID: folder.id))
    }

    /// Lizenz der neuen Datei setzen (bester Versuch: ein Fehler laesst die Abgabe stehen)
    func setOwnWorkLicense(fileRefID: String, writer: StudIPWritingTransport) async throws -> Bool {
        let list = try await self.list("jsonapi.php/v1/terms-of-use").data
        guard let license = StudIPSubmit.ownWorkLicenseID(list) else { return false }
        let payload: JSONValue = .object(["data": .object(["type": .string("terms-of-use"), "id": .string(license)])])
        let body = payload.serialized()
        let headers = ["Content-Type": StudIPClient.jsonAPI, "Accept": StudIPClient.jsonAPI, "X-Requested-With": "XMLHttpRequest"]
        let r = try await perform("jsonapi.php/v1/file-refs/\(fileRefID)/relationships/terms-of-use", anyStatus: true, retry: .none) {
            try await writer.send($0, method: "PATCH", headers: headers, body: body)
        }
        return (200..<300).contains(r.status)
    }
}

// MARK: Verlauf

/// Eine Abgabe im Verlauf eines Dokuments ("Abgegeben am … in …"); nur auf dem Geraet, je Container
public struct StudIPSubmissionRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(documentID)|\(at.timeIntervalSince1970)|\(folderID)" }
    public let documentID: String
    public let at: Date
    public let courseID: String
    public let courseTitle: String
    public let folderID: String
    public let folderLabel: String
    public let fileName: String
    public let url: String
    public let withNotes: Bool
    public let pages: Int

    public init(documentID: String, at: Date, courseID: String, courseTitle: String, folderID: String, folderLabel: String,
                fileName: String, url: String, withNotes: Bool, pages: Int) {
        self.documentID = documentID
        self.at = at
        self.courseID = courseID
        self.courseTitle = courseTitle
        self.folderID = folderID
        self.folderLabel = folderLabel
        self.fileName = fileName
        self.url = url
        self.withNotes = withNotes
        self.pages = pages
    }

    /// "Abgegeben am 05.11.2026, 14:30 in Analysis I › Abgabe Blatt 3"
    public func line(timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = timeZone
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return "Abgegeben am \(f.string(from: at)) in \(courseTitle) › \(folderLabel)"
    }
}

/// Verlauf aller Abgaben eines Containers (JSON in dessen Einstellungen), neueste zuerst, hoechstens `limit` Eintraege
public struct StudIPSubmissionLog: Codable, Sendable, Equatable {
    public static let defaultsKey = "uniflow.studip.submissions"
    public static let limit = 300
    public private(set) var records: [StudIPSubmissionRecord] = []

    public init(records: [StudIPSubmissionRecord] = []) { self.records = records }

    public static func decode(_ data: Data?) -> StudIPSubmissionLog {
        guard let data, let log = try? JSONDecoder().decode(StudIPSubmissionLog.self, from: data) else { return StudIPSubmissionLog() }
        return log
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public mutating func add(_ r: StudIPSubmissionRecord) {
        records.insert(r, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
    }

    public func records(for documentID: String) -> [StudIPSubmissionRecord] { records.filter { $0.documentID == documentID } }
}
