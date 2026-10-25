import Foundation

// Learnweb (Moodle) der Uni Hildesheim: Kurse und Dateilisten lesen, Regeln wie app/learnweb.py (Hilfsfunktionen
// ohne Netzwerk). Dieselben Erwartungen wie der PC prueft SharedFixture-Test gegen
// packages/shared-contracts/fixtures/hildesheim/expected.json.
//
// Wichtig aus dem Live-Test 25.10.2026: Dateinamen kommen teils in NFD (u + U+0308). Immer NFC normalisieren,
// auch vor dem Hash der Datei-ID, sonst entstehen andere IDs als auf dem PC.

/// Kurs wie `learnweb._course`: "SoSe 2026: 0406 Titel" -> Semester, Veranstaltungsnummer (wie im LSF), Titel.
public struct LearnwebCourse: Sendable, Equatable, Codable {
    /// "lw-<moodle-id>"
    public let id: String
    public let moodleID: Int
    /// Titel ohne Semester, mit Nummer ("0406 Theorien der Erziehungswissenschaft")
    public let title: String
    public let number: String?
    public let semester: String
    public let hidden: Bool

    public init(id: String, moodleID: Int, title: String, number: String?, semester: String, hidden: Bool) {
        self.id = id
        self.moodleID = moodleID
        self.title = title
        self.number = number
        self.semester = semester
        self.hidden = hidden
    }
}

/// Datei eines Kurses im Format von `studip_sync.store_course_files` (+ Ordner).
public struct LearnwebFile: Sendable, Equatable, Codable {
    /// "lw-<cmid>-<sha1(filepath+filename)[:8]>" nach NFC, identisch zum PC
    public let id: String
    /// NFC
    public let name: String
    public let size: Int
    public let mime: String?
    public let author: String?
    /// Aenderung: `timemodified` (Schluessel/REST) bzw. Revision im Pluginfile-Pfad (Sitzung)
    public let chdate: Int
    /// Download-Adresse ohne `forcedownload` und ohne Token (der Token kommt erst beim Abruf dazu)
    public let downloadURL: String
    /// Ordner im Kurs, z. B. "Woche 1/Literatur/Teil 1" (NFC)
    public let folder: String
    public let moduleName: String?

    public init(id: String, name: String, size: Int, mime: String?, author: String?, chdate: Int, downloadURL: String,
                folder: String, moduleName: String?) {
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
        self.author = author
        self.chdate = chdate
        self.downloadURL = downloadURL
        self.folder = folder
        self.moduleName = moduleName
    }
}

public enum LearnwebParsing {
    // MARK: Kurse

    /// Wie `parse_course_title`.
    public static func parseCourseTitle(_ fullname: String) -> (semester: String, number: String?, title: String) {
        var t = collapse(fullname)
        var semester = ""
        if let m = firstMatch(#"^\s*((?:SoSe|SS|WiSe|WS)\s*\d{2,4}(?:/\d{2,4})?)\s*:\s*"#, in: t, caseless: true) {
            semester = collapse(m.groups[0] ?? "")
            t = String(t[m.range.upperBound...])
        }
        let number = firstMatch(#"^(\d{3,5})\s+"#, in: t)?.groups[0]
        return (semester, number, t)
    }

    /// Wie `learnweb._course`: Eintrag aus core_enrol_get_users_courses bzw. der Timeline-Klassifikation.
    public static func course(_ c: JSONValue) -> LearnwebCourse? {
        guard let mid = c["id"]?.int ?? c["id"]?.string.flatMap({ Int($0) }) else { return nil }
        let full = nonEmpty(c["fullname"]?.string) ?? nonEmpty(c["displayname"]?.string) ?? ""
        let p = parseCourseTitle(full)
        return LearnwebCourse(id: "lw-\(mid)", moodleID: mid, title: p.title, number: p.number, semester: p.semester,
                              hidden: truthy(c["hidden"]))
    }

    // MARK: Namen, Ordner, IDs

    public static func nfc(_ s: String?) -> String { (s ?? "").precomposedStringWithCanonicalMapping }

    /// Wie `file_id`: sha1 ueber "<filepath oder '/'><filename>" nach NFC, erste 8 Hex-Zeichen.
    public static func fileID(cmid: String, filepath: String, filename: String) -> String {
        let fp = nfc(filepath), fn = nfc(filename)
        let h = InsecureHash.sha1Hex((fp.isEmpty ? "/" : fp) + fn)
        return "lw-\(cmid)-\(h.prefix(8))"
    }

    /// Wie `section_label`: reine Zahlen (1-2 Ziffern) werden zu "Woche N", leere Namen zu "Abschnitt N".
    public static func sectionLabel(_ title: String?, number: Int? = nil) -> String {
        let t = collapse(title ?? "")
        if t.count <= 2, !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(t) { return "Woche \(n)" }
        if t.isEmpty, let number, number != 0 { return "Abschnitt \(number)" }
        return t
    }

    /// Wie `join_folder`: Teile ohne fuehrende/abschliessende "/" und Leerzeichen, leere Teile entfallen.
    public static func joinFolder(_ parts: String?...) -> String { joinFolder(parts) }

    public static func joinFolder(_ parts: [String?]) -> String {
        parts.compactMap { p -> String? in
            guard let p else { return nil }
            let s = p.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return s.isEmpty ? nil : s
        }.joined(separator: "/")
    }

    /// Wie `strip_forcedownload` (re.sub(r"[?&]forcedownload=1", "", url)).
    public static func stripForcedownload(_ url: String) -> String {
        url.replacingOccurrences(of: #"[?&]forcedownload=1"#, with: "", options: .regularExpression)
    }

    /// Wie mimetypes.guess_type fuer die ueblichen Dateien in Lernplattformen; sonst nil.
    public static func guessMime(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return mimeTypes[name[name.index(after: dot)...].lowercased()]
    }

    static let mimeTypes: [String: String] = [
        "pdf": "application/pdf", "txt": "text/plain", "csv": "text/csv", "html": "text/html", "htm": "text/html",
        "json": "application/json", "xml": "text/xml", "zip": "application/zip",
        "doc": "application/msword", "dot": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
        "mp3": "audio/mpeg", "mp4": "video/mp4",
    ]

    // MARK: Pluginfile

    /// Pluginfile-Link -> Bereich, Revision, Pfad und Name (NFC). Die Revision steigt, wenn Lehrende die Datei ersetzen.
    public struct Pluginfile: Equatable, Sendable {
        public let area: String
        public let revision: Int
        public let filepath: String
        public let filename: String
    }

    /// Wie `parse_pluginfile`.
    public static func parsePluginfile(_ url: String) -> Pluginfile? {
        let path = urlPath(url)
        guard let m = firstMatch(#"/pluginfile\.php/\d+/mod_(resource|folder)/content/(\d+)/(.+)$"#, in: path),
              let area = m.groups[0], let rev = m.groups[1].flatMap({ Int($0) }), let rest = m.groups[2] else { return nil }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map { nfc(unquote(String($0))) }
        guard let filename = parts.last else { return nil }
        let filepath = "/" + parts.dropLast().joined(separator: "/") + (parts.count > 1 ? "/" : "")
        return Pluginfile(area: area, revision: rev, filepath: filepath, filename: filename)
    }

    /// Pfad wie urllib.parse.urlparse(url).path (prozentkodiert, ohne Abfrage und Anker).
    static func urlPath(_ url: String) -> String {
        var s = Substring(url)
        if let r = s.range(of: "://") {
            s = s[r.upperBound...]
            guard let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) else { return "" }
            s = s[slash...]
        }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = s[..<cut] }
        return String(s)
    }

    /// Wie urllib.parse.unquote (UTF-8, ungueltige Folgen als U+FFFD).
    static func unquote(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var out: [UInt8] = []
        let b = Array(s.utf8)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        while i < b.count {
            if b[i] == 0x25, i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Dateilisten

    /// Wie `files_from_contents`: core_course_get_contents (REST mit Schluessel) -> Dateien (resource, folder).
    public static func filesFromContents(_ sections: JSONValue) -> [LearnwebFile] {
        var out: [LearnwebFile] = []
        for sec in sections.array ?? [] {
            let secName = sectionLabel(sec["name"]?.string, number: sec["section"]?.int)
            for mod in sec["modules"]?.array ?? [] {
                let modname = mod["modname"]?.string
                guard modname == "resource" || modname == "folder", let cmid = pyStr(mod["id"]) else { continue }
                let modName = mod["name"]?.string
                let baseFolder = modname == "resource" ? secName : joinFolder(secName, modName ?? "")
                for c in mod["contents"]?.array ?? [] {
                    guard c["type"]?.string == "file", let fileurl = nonEmpty(c["fileurl"]?.string) else { continue }
                    let fp = nonEmpty(c["filepath"]?.string) ?? "/"
                    let name = nonEmpty(nfc(c["filename"]?.string)) ?? "datei"
                    out.append(LearnwebFile(
                        id: fileID(cmid: cmid, filepath: fp, filename: name), name: name,
                        size: c["filesize"]?.int ?? 0, mime: nonEmpty(c["mimetype"]?.string) ?? guessMime(name),
                        author: c["author"]?.string, chdate: c["timemodified"]?.int ?? 0,
                        downloadURL: stripForcedownload(fileurl), folder: nfc(joinFolder(baseFolder, fp)), moduleName: modName))
                }
            }
        }
        return out
    }

    /// Wie `files_from_state`: core_courseformat_get_state (AJAX mit Sitzung) -> Dateien; die Links je cmid kommen
    /// von aussen (Weiterleitung von mod/resource/view.php bzw. Ordnerseite).
    public static func filesFromState(_ state: JSONValue, resourceLinks: (String) async throws -> [String],
                                      folderLinks: (String) async throws -> [String]) async rethrows -> [LearnwebFile] {
        var sections: [String: JSONValue] = [:]
        for s in state["section"]?.array ?? [] { if let id = pyStr(s["id"]) { sections[id] = s } }
        var out: [LearnwebFile] = []
        for cm in state["cm"]?.array ?? [] {
            let module = cm["module"]?.string
            guard module == "resource" || module == "folder", cm["uservisible"] != .bool(false),
                  let cmid = pyStr(cm["id"]) else { continue }
            let sec = sections[pyStr(cm["sectionid"]) ?? "None"] ?? .object([:])
            let secName = sectionLabel(sec["title"]?.string, number: sec["number"]?.int)
            let links: [String]
            let baseFolder: String
            if module == "resource" {
                links = try await resourceLinks(cmid)
                baseFolder = secName
            } else {
                links = try await folderLinks(cmid)
                baseFolder = joinFolder(secName, cm["name"]?.string ?? "")
            }
            for url in links {
                guard let p = parsePluginfile(url) else { continue }
                out.append(LearnwebFile(id: fileID(cmid: cmid, filepath: p.filepath, filename: p.filename), name: p.filename,
                                        size: 0, mime: guessMime(p.filename), author: nil, chdate: p.revision,
                                        downloadURL: stripForcedownload(url), folder: joinFolder(baseFolder, p.filepath),
                                        moduleName: cm["name"]?.string))
            }
        }
        return out
    }

    /// Wie `folder_links`: Pluginfile-Links einer Ordnerseite, ohne Doppelte (mit/ohne forcedownload).
    public static func folderLinks(html: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for m in allMatches(#"href="([^"]*/pluginfile\.php/\d+/mod_folder/content/\d+/[^"]+)""#, in: html) {
            guard let raw = m.groups[0] else { continue }
            let link = raw.replacingOccurrences(of: "&amp;", with: "&")
            if seen.insert(stripForcedownload(link)).inserted { out.append(link) }
        }
        return out
    }

    /// Anzeigeart "eingebettet": der Pluginfile-Link steht in der Seite von mod/resource/view.php (EMBEDDED_RE).
    public static func embeddedResourceLink(html: String) -> String? {
        firstMatch(#"(https?://[^"'<>\s]+/pluginfile\.php/\d+/mod_resource/content/\d+/[^"'<>\s]+)"#, in: html)?
            .groups[0]?.replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Aenderungen

    /// Neue oder geaenderte Dateien: unbekannte ID oder hoeheres `chdate` (timemodified bzw. Revision) als bekannt.
    /// Gleiche oder niedrigere Werte laden nichts neu.
    public static func needsDownload(_ files: [LearnwebFile], known: [String: Int]) -> [LearnwebFile] {
        files.filter { f in known[f.id].map { f.chdate > $0 } ?? true }
    }

    // MARK: Hilfen

    /// Leerraum zusammenfassen wie re.sub(r"\s+", " ", s).strip()
    static func collapse(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    /// bool(x) in Python fuer JSON-Werte
    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0
        case .string(let s)?: return !s.isEmpty
        case .array(let a)?: return !a.isEmpty
        case .object(let o)?: return !o.isEmpty
        default: return false
        }
    }

    /// str(x) in Python fuer IDs (Zahl oder Text); nil fuer fehlende Werte.
    static func pyStr(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s)?: return s
        case .number(let n)?: return n.rounded() == n && abs(n) < 9e15 ? String(Int(n)) : JSONValue.format(n)
        case .bool(let b)?: return b ? "True" : "False"
        default: return nil
        }
    }

    struct Match { let range: Range<String.Index>; let groups: [String?] }

    static func firstMatch(_ pattern: String, in s: String, caseless: Bool = false) -> Match? {
        allMatches(pattern, in: s, caseless: caseless, limit: 1).first
    }

    static func allMatches(_ pattern: String, in s: String, caseless: Bool = false, limit: Int = .max) -> [Match] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : []) else { return [] }
        var out: [Match] = []
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            let groups = (1..<max(m.numberOfRanges, 1)).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
            out.append(Match(range: r, groups: groups))
            if out.count >= limit { break }
        }
        return out
    }
}
