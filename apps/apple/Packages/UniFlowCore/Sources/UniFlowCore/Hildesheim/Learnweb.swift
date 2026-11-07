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
        /// Name des Moodle-Abschnitts (`sectionLabel`), fuer die Lehrwoche (`LectureWeeks`, Regel 1)
        public var section: String? = nil

        /// Eingabe fuer die Lehrwoche (`LectureWeeks`); `date` und `final` setzt der Abgleich
        public func weekInput(date: Int?, final: Bool) -> LectureWeeks.Input {
            LectureWeeks.Input(id: id, name: name, folder: folder, section: section, moduleName: moduleName,
                               date: date ?? chdate.flatMap { $0 > 0 ? $0 : nil }, final: final)
        }

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
    private static let commaSemRE = HText.regex("^(.+?),\\s*((?:SoSe|SS|WiSe|WS)\\s*\\d{2,4}(?:/\\d{2,4})?)\\s*(?:,.*)?$", [.caseInsensitive])
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
        } else if let m = HText.match(commaSemRE, t) {
            // Moodle der Hochschule Hannover: "<Titel>, WiSe 2026/27, <Lehrende>" (docs/HSH-2026-11-05.md)
            sem = HText.collapse(m.groups[2] ?? "")
            t = HText.collapse(m.groups[1] ?? t)
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

    private static let fileQueryRE = HText.regex("[?&]file=([^&#]+)")

    /// Pluginfile-Link -> Bereich, Revision (steigt beim Ersetzen), Pfad und Dateiname (dekodiert wie
    /// `urllib.parse.unquote`, NFC). Pfad wie `urlparse(url).path`, auch bei Adressen, die `URLComponents` ablehnt.
    /// Ein Moodle ohne `slasharguments` schreibt `pluginfile.php?file=/<ctx>/mod_resource/content/<rev>/<Datei>`:
    /// dann zaehlt der Wert von `file` als Pfad (vorher fiel jede solche Datei still aus der Liste).
    public static func parsePluginfile(_ url: String) -> Pluginfile? {
        var path = HText.urlPath(url)
        if path.hasSuffix("/pluginfile.php"), let q = HText.match(fileQueryRE, url)?.groups[1] ?? nil {
            let file = PyText.unquote(q.replacingOccurrences(of: "+", with: " "))
            path += file.hasPrefix("/") ? file : "/" + file
        }
        guard let m = HText.match(pluginRE, path), let area = m.groups[1], let revText = m.groups[2], let rev = Int(revText),
              let rest = m.groups[3] else { return nil }
        let parts = rest.split(separator: "/").map { HText.nfc(PyText.unquote(String($0))) }
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
                                    folder: HText.nfc(joinFolder(base, fp)), moduleName: mod["name"]?.string, section: secName))
                }
            }
        }
        return out
    }

    /// Ein Eintrag "Datei" (mod_resource) oder "Ordner" (mod_folder) eines Kurses mit seinem Abschnitt, aus dem
    /// Kurszustand (`core_courseformat_get_state`) oder von der Kursseite (`coursePageModules`)
    public struct ModuleRef: Sendable, Equatable {
        public let cmid: String
        /// "resource" oder "folder"
        public let module: String
        public let name: String
        /// Abschnitt als Ordnername (`sectionLabel`)
        public let section: String
        public init(cmid: String, module: String, name: String, section: String) {
            self.cmid = cmid
            self.module = module
            self.name = name
            self.section = section
        }
    }

    /// Datei- und Ordner-Eintraege aus `core_courseformat_get_state` (nur sichtbare, in der Reihenfolge des Zustands)
    public static func stateModules(_ state: JSONValue) -> [ModuleRef] {
        var sections: [String: JSONValue] = [:]
        for s in state["section"]?.array ?? [] { sections[s["id"].map(idString) ?? ""] = s }
        var out: [ModuleRef] = []
        for cm in state["cm"]?.array ?? [] {
            let module = cm["module"]?.string ?? ""
            guard module == "resource" || module == "folder", cm["uservisible"]?.bool != false else { continue }
            let sec = sections[cm["sectionid"].map(idString) ?? ""]
            out.append(ModuleRef(cmid: cm["id"].map(idString) ?? "", module: module, name: cm["name"]?.string ?? "",
                                 section: sectionLabel(sec?["title"]?.string, number: sec?["number"]?.int)))
        }
        return out
    }

    /// `core_courseformat_get_state` (Sitzung) -> Dateien; Links liefern die Callbacks je cmid. Ohne Aenderungszeit
    /// und Groesse, mit der Revision (siehe `File`).
    public static func filesFromState(_ state: JSONValue, resourceLinks: (String) -> [String], folderLinks: (String) -> [String]) -> [File] {
        filesFromModules(stateModules(state)) { $0.module == "resource" ? resourceLinks($0.cmid) : folderLinks($0.cmid) }
    }

    /// Eintraege -> Dateien; `links` liefert die Pluginfile-Links je Eintrag (Datei: Weiterleitung von
    /// mod/resource/view.php, Ordner: seine Seite)
    public static func filesFromModules(_ modules: [ModuleRef], links: (ModuleRef) -> [String]) -> [File] {
        var out: [File] = []
        for m in modules {
            let base = m.module == "resource" ? m.section : joinFolder(m.section, m.name)
            for url in links(m) {
                guard let p = parsePluginfile(url) else { continue }
                out.append(File(id: fileID(cmid: m.cmid, filepath: p.filepath, filename: p.filename), name: p.filename, size: nil,
                                mime: guessMime(p.filename), chdate: nil, revision: p.revision, downloadURL: stripForceDownload(url),
                                folder: joinFolder(base, p.filepath), moduleName: m.name.isEmpty ? nil : m.name, section: m.section))
            }
        }
        return out
    }

    // MARK: Kursseite (course/view.php) als zweiter Weg

    private static let sectionAnchorRE = HText.regex(#"<li\b[^>]*\bid\s*=\s*["']section-(\d+)["'][^>]*>"#, [.caseInsensitive])
    private static let sectionNameAttrRE = HText.regex(#"\bdata-sectionname\s*=\s*["']([^"']*)["']"#, [.caseInsensitive])
    private static let sectionHeadingRE = HText.regex(#"<h[1-6]\b[^>]*\bclass\s*=\s*["'][^"']*\bsectionname\b[^"']*["'][^>]*>(.*?)</h[1-6]>"#,
                                                      [.caseInsensitive, .dotMatchesLineSeparators])
    private static let moduleLinkRE = HText.regex(#"/mod/(resource|folder)/view\.php\?id=(\d+)"#, [.caseInsensitive])
    private static let instanceNameRE = HText.regex(#"<span\b[^>]*\bclass\s*=\s*["'][^"']*\binstancename\b[^"']*["'][^>]*>(.*?)</span>\s*</a>"#,
                                                    [.caseInsensitive, .dotMatchesLineSeparators])
    private static let accessHideRE = HText.regex(#"<span\b[^>]*\baccesshide\b[^>]*>.*?</span>"#, [.caseInsensitive, .dotMatchesLineSeparators])
    private static let tagRE = HText.regex("<[^>]+>")

    /// Sichtbarer Text eines HTML-Stuecks (Tags weg, Entitaeten dekodiert, Leerraum zusammengefasst)
    static func plainText(_ html: String) -> String {
        HText.collapse(QISParser.decodeEntities(HText.replace(tagRE, in: html, with: " ")))
    }

    /// Datei- und Ordner-Eintraege von der Kursseite (Moodle 4/5, Theme boost/boost_union: `<li id="section-N"
    /// data-sectionname="…">` mit `<h3 class="sectionname">`, Eintraege `<li id="module-<cmid>">` mit dem Link
    /// `mod/resource/view.php?id=` bzw. `mod/folder/view.php?id=` und dem Namen in `span.instancename`). Zweiter Weg,
    /// wenn `core_courseformat_get_state` keinen Eintrag liefert oder nicht erlaubt ist (Befund HsH 07.11.2026:
    /// alle Kurse "0 Dateien"); die Reihenfolge ist die der Seite, versteckte Eintraege stehen dort nicht.
    public static func coursePageModules(html: String) -> [ModuleRef] {
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let sections = sectionAnchorRE.matches(in: html, range: full)
        var out: [ModuleRef] = []
        var seen = Set<String>()
        func scan(_ chunk: String, section: String) {
            let cns = chunk as NSString
            let anchors = moduleAnchorRE.matches(in: chunk, range: NSRange(location: 0, length: cns.length))
            for (i, a) in anchors.enumerated() {
                let from = a.range.location
                let to = i + 1 < anchors.count ? anchors[i + 1].range.location : cns.length
                let item = cns.substring(with: NSRange(location: from, length: to - from))
                let cmid = cns.substring(with: a.range(at: 1))
                guard !seen.contains(cmid), let link = HText.match(moduleLinkRE, item), let module = link.groups[1]?.lowercased(),
                      link.groups[2] == cmid else { continue }
                seen.insert(cmid)
                let name = (HText.match(instanceNameRE, item)?.groups[1] ?? nil).map { plainText(HText.replace(accessHideRE, in: $0, with: "")) } ?? ""
                out.append(ModuleRef(cmid: cmid, module: module, name: name, section: section))
            }
        }
        guard !sections.isEmpty else {
            scan(html, section: "")
            return out
        }
        for (i, s) in sections.enumerated() {
            let from = s.range.location
            let to = i + 1 < sections.count ? sections[i + 1].range.location : ns.length
            let chunk = ns.substring(with: NSRange(location: from, length: to - from))
            let tag = ns.substring(with: s.range)
            let number = Int(ns.substring(with: s.range(at: 1)))
            var title = (HText.match(sectionNameAttrRE, tag)?.groups[1] ?? nil).map { QISParser.decodeEntities($0) }
            if title == nil, let h = HText.match(sectionHeadingRE, chunk)?.groups[1] ?? nil { title = plainText(h) }
            scan(chunk, section: sectionLabel(title, number: number))
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

    /// Anfang eines Eintrags der Kursseite: `<li ... id="module-<cmid>">` (Moodle cmitem.mustache, `anchor`)
    private static let moduleAnchorRE = HText.regex(#"\bid\s*=\s*["']module-(\d+)["']"#)

    /// Ordner mit der Anzeige "auf der Kursseite" (FOLDER_DISPLAY_INLINE): `mod/folder/view.php` leitet dann auf die
    /// Kursseite weiter, und dort stehen die Dateien aller solchen Ordner der Seite. Zu diesem Ordner gehoeren nur die
    /// Links in seinem Eintrag, vom Anker `id="module-<cmid>"` bis zum naechsten Eintrag. Ohne Anker: keine Links (nie
    /// die Links fremder Ordner). Am PC (`_folder_links`) nimmt die Sitzung die ganze Kursseite: jede Datei jedes
    /// eingebetteten Ordners zaehlt dort einmal je eingebettetem Ordner (Befund 28.10.2026).
    public static func inlineFolderLinks(coursePage html: String, cmid: String) -> [String] {
        guard !cmid.isEmpty, cmid.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return [] }
        let ns = html as NSString
        let anchors = moduleAnchorRE.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard let i = anchors.firstIndex(where: { ns.substring(with: $0.range(at: 1)) == cmid }) else { return [] }
        let from = anchors[i].range.location
        let to = i + 1 < anchors.count ? anchors[i + 1].range.location : ns.length
        return folderLinks(html: ns.substring(with: NSRange(location: from, length: to - from)))
    }

    /// Kursseite dieses Learnweb (`course/view.php`, seit Moodle 4.4 auch `course/section.php`): Ziel der Weiterleitung
    /// eines Ordners mit der Anzeige "auf der Kursseite"
    static func isCoursePage(_ url: URL, base: String) -> Bool {
        guard let b = URL(string: base), let host = url.host?.lowercased(), host == b.host?.lowercased() else { return false }
        var root = b.path
        while root.hasSuffix("/") { root.removeLast() }
        return url.path == root + "/course/view.php" || url.path == root + "/course/section.php"
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
