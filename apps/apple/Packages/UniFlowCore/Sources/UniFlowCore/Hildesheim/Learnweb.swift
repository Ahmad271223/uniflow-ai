import Foundation

/// Learnweb (Moodle) der Uni Hildesheim: Kurstitel, Dateilisten, Pluginfile-Links und die Instanz des Semesters.
/// Uebertragen aus `app/learnweb.py`; Erwartungswerte in `packages/shared-contracts/fixtures/hildesheim/expected.json`.
public enum Learnweb {

    public struct CourseTitle: Sendable, Equatable {
        public let semester: String
        public let number: String?
        public let title: String
    }

    /// Eine Datei im Format, das der Sync speichert. `chdate`: Aenderungszeit (REST); ueber die Sitzung nil, wie auch
    /// `size`: dort gibt es nur die Pluginfile-Revision (`revision`, steigt beim Ersetzen), den Zeitpunkt bestimmt
    /// `UniStore.versionStamp`. Frueher stand die Revision in `chdate`, das alle als Unix-Zeit lesen (Lehrwoche 1970).
    /// `author` nur mit Schluessel (REST), wie `files_from_contents`; `moduleName` wie `module_name` (Name der
    /// Ressource bzw. des Ordners im Kurs). `downloadURL` nie mit Schluessel (der kommt erst beim Abruf dazu).
    public struct File: Sendable, Equatable {
        public let id: String
        public let name: String
        public let size: Int?
        public let mime: String?
        public var author: String? = nil
        public let chdate: Int?
        public var revision: Int? = nil
        public let downloadURL: String
        public let folder: String
        public var moduleName: String? = nil

        /// Zeile fuer `UniStore.storeFiles`; Ordner nur, wenn vorhanden (wie `folders` in hildesheim.sync_learnweb)
        public var row: UniStore.FileRow {
            UniStore.FileRow(id: id, name: name, size: size, mime: mime, author: author, chdate: chdate, revision: revision,
                             downloadURL: downloadURL, folder: folder.isEmpty ? nil : folder)
        }
    }

    public struct Pluginfile: Sendable, Equatable {
        public let area: String
        public let revision: Int
        public let filepath: String
        public let filename: String
    }

    public static let root = "https://www.uni-hildesheim.de"

    private static let semRE = HText.regex("^\\s*((?:SoSe|SS|WiSe|WS)\\s*\\d{2,4}(?:/\\d{2,4})?)\\s*:\\s*", [.caseInsensitive])
    private static let numRE = HText.regex("^(\\d{3,5})\\s+")
    private static let pluginRE = HText.regex("/pluginfile\\.php/\\d+/mod_(resource|folder)/content/(\\d+)/(.+)$")
    private static let folderLinkRE = HText.regex("href=\"([^\"]*/pluginfile\\.php/\\d+/mod_folder/content/\\d+/[^\"]+)\"")
    private static let forceDownloadRE = HText.regex("[?&]forcedownload=1")
    private static let twoDigitsRE = HText.regex("^\\d{1,2}$")

    /// "SoSe 2026: 9406 Theorien ..." -> Semester, Veranstaltungsnummer (wie im LSF), Titel (mit Nummer)
    public static func parseCourseTitle(_ fullname: String) -> CourseTitle {
        var t = HText.collapse(fullname)
        var sem = ""
        if let m = HText.match(semRE, t) {
            sem = HText.collapse(m.groups[1] ?? "")
            t = String(t[m.range.upperBound...])
        }
        let num = HText.match(numRE, t)?.groups[1] ?? nil
        return CourseTitle(semester: sem, number: num, title: t)
    }

    /// Abschnittsname als Ordner; reine Zahlen werden "Woche N", leere Abschnitte "Abschnitt N" (ausser 0).
    public static func sectionLabel(_ title: String?, number: Int?) -> String {
        let t = HText.collapse(title ?? "")
        if HText.match(twoDigitsRE, t) != nil, let n = Int(t) { return "Woche \(n)" }
        if t.isEmpty, let n = number, n != 0 { return "Abschnitt \(n)" }
        return t
    }

    /// Datei-ID wie am PC: "lw-<cmid>-" + die ersten 8 Hexzeichen von SHA-256(filepath + filename), beides NFC.
    public static func fileID(cmid: String, filepath: String, filename: String) -> String {
        let fp = HText.nfc(filepath.isEmpty ? "/" : filepath), fn = HText.nfc(filename)
        return "lw-\(cmid)-" + String(HText.sha256Hex(fp + fn).prefix(8))
    }

    /// Python `join_folder`: Teile ohne fuehrende/abschliessende "/" und Leerzeichen, leere weglassen.
    public static func joinFolder(_ parts: String...) -> String {
        parts.map { PyText.strip($0, chars: "/ ") }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    public static func stripForceDownload(_ url: String) -> String { HText.replace(forceDownloadRE, in: url, with: "") }

    // Den Schluessel haengt der Abruf nicht an die Adresse (`with_token` am PC), sondern schickt ihn im Koerper
    // (`LearnwebAPI.downloadRequest`): Schluessel nie in Adressen.

    /// `mimetypes.guess_type(name)[0]`: die eine Tabelle des Kerns (`LocalFileResponse.guess`); sonst nil
    public static func guessMime(_ name: String) -> String? { LocalFileResponse.guess(name) }

    /// Pluginfile-Link -> Bereich, Revision (steigt beim Ersetzen), Pfad und Dateiname (dekodiert wie
    /// `urllib.parse.unquote`, NFC). Pfad wie `urlparse(url).path`, auch bei Adressen, die `URLComponents` ablehnt.
    public static func parsePluginfile(_ url: String) -> Pluginfile? {
        let path = HText.urlPath(url)
        guard let m = HText.match(pluginRE, path), let area = m.groups[1], let revText = m.groups[2], let rev = Int(revText),
              let rest = m.groups[3] else { return nil }
        let parts = rest.split(separator: "/").map { HText.nfc(HText.unquote(String($0))) }
        guard let filename = parts.last else { return nil }
        let filepath = "/" + parts.dropLast().joined(separator: "/") + (parts.count > 1 ? "/" : "")
        return Pluginfile(area: area, revision: rev, filepath: filepath, filename: filename)
    }

    /// `core_course_get_contents` (REST mit Schluessel) -> Dateien
    public static func filesFromContents(_ sections: JSONValue) -> [File] {
        var out: [File] = []
        for sec in sections.array ?? [] {
            let secName = sectionLabel(sec["name"]?.string, number: sec["section"]?.int)
            for mod in sec["modules"]?.array ?? [] {
                let modname = mod["modname"]?.string ?? ""
                guard modname == "resource" || modname == "folder" else { continue }
                let base = modname == "resource" ? secName : joinFolder(secName, mod["name"]?.string ?? "")
                let cmid = mod["id"].map(idString) ?? ""
                for c in mod["contents"]?.array ?? [] {
                    guard c["type"]?.string == "file", let fileurl = c["fileurl"]?.string, !fileurl.isEmpty else { continue }
                    let fp = (c["filepath"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
                    let raw = HText.nfc(c["filename"]?.string ?? "")
                    let name = raw.isEmpty ? "datei" : raw
                    // Revision mitspeichern: wechselt der Abgleich zur Sitzung, vergleicht er sie (`UniStore.versionStamp`)
                    out.append(File(id: fileID(cmid: cmid, filepath: fp, filename: name), name: name,
                                    size: c["filesize"]?.int ?? 0, mime: (c["mimetype"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? guessMime(name),
                                    author: c["author"]?.string, chdate: c["timemodified"]?.int ?? 0,
                                    revision: parsePluginfile(fileurl)?.revision, downloadURL: stripForceDownload(fileurl),
                                    folder: HText.nfc(joinFolder(base, fp)), moduleName: mod["name"]?.string))
                }
            }
        }
        return out
    }

    /// `core_courseformat_get_state` (Sitzung) -> Dateien; Links liefern die Callbacks je cmid. Ohne Aenderungszeit
    /// und Groesse, mit der Revision (siehe `File`).
    public static func filesFromState(_ state: JSONValue, resourceLinks: (String) -> [String], folderLinks: (String) -> [String]) -> [File] {
        var sections: [String: JSONValue] = [:]
        for s in state["section"]?.array ?? [] { sections[s["id"].map(idString) ?? ""] = s }
        var out: [File] = []
        for cm in state["cm"]?.array ?? [] {
            let module = cm["module"]?.string ?? ""
            guard module == "resource" || module == "folder", cm["uservisible"]?.bool != false else { continue }
            let cmid = cm["id"].map(idString) ?? ""
            let sec = sections[cm["sectionid"].map(idString) ?? ""]
            let secName = sectionLabel(sec?["title"]?.string, number: sec?["number"]?.int)
            let links = module == "resource" ? resourceLinks(cmid) : folderLinks(cmid)
            let base = module == "resource" ? secName : joinFolder(secName, cm["name"]?.string ?? "")
            for url in links {
                guard let p = parsePluginfile(url) else { continue }
                out.append(File(id: fileID(cmid: cmid, filepath: p.filepath, filename: p.filename), name: p.filename, size: nil,
                                mime: guessMime(p.filename), chdate: nil, revision: p.revision, downloadURL: stripForceDownload(url),
                                folder: joinFolder(base, p.filepath), moduleName: cm["name"]?.string))
            }
        }
        return out
    }

    /// Dateilinks einer Ordnerseite, ohne Doppelte (mit/ohne forcedownload)
    public static func folderLinks(html: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in HText.allMatches(folderLinkRE, html) {
            let link = raw.replacingOccurrences(of: "&amp;", with: "&")
            if seen.insert(stripForceDownload(link)).inserted { out.append(link) }
        }
        return out
    }

    /// Aktuelles Semester wie in den Learnweb-Namen: April bis September SoSe, sonst WiSe.
    public static func semesterLabel(year: Int, month: Int) -> String {
        if (4...9).contains(month) { return "SoSe \(year)" }
        let start = month >= 10 ? year : year - 1
        return "WiSe \(start)/\(String(String(start + 1).suffix(2)))"
    }

    /// Instanz des aktuellen Semesters: Vorjahr, aktuelles und naechstes Jahr pruefen; die Instanz, deren Name das
    /// Semester nennt, sonst die neueste erreichbare. `sitename(base)` liefert den Namen oder nil (nicht erreichbar).
    /// Den Namen liefert die oeffentliche Moodle-Schnittstelle `tool_mobile_get_public_config` ohne Anmeldung.
    public static func discoverBase(year: Int, month: Int, override: String? = nil, sitename: (String) -> String?) -> String? {
        if var o = override, !o.isEmpty {
            while o.hasSuffix("/") { o.removeLast() }
            return o
        }
        let want = semesterLabel(year: year, month: month).lowercased().replacingOccurrences(of: " ", with: "")
        var alive: [String] = []
        for y in [year + 1, year, year - 1] {
            let base = "\(root)/learnweb\(y)"
            guard let name = sitename(base) else { continue }
            if name.lowercased().replacingOccurrences(of: " ", with: "").contains(want) { return base }
            alive.append(base)
        }
        return alive.first
    }

    static func idString(_ v: JSONValue) -> String {
        if let s = v.string { return s }
        if let i = v.int { return String(i) }
        return ""
    }
}
