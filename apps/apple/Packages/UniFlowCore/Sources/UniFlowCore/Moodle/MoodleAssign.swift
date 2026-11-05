import Foundation

// Abgeben in einer Moodle-Aufgabe (Hochschule Hannover, Learnweb der Uni Hildesheim) mit der Sitzung, so wie die
// Moodle-Oberflaeche es tut: Abgabe-Formular oeffnen (action=editsubmission), PDF in den Entwurfsbereich laden
// (/repository/repository_ajax.php?action=upload mit sesskey und itemid), Formular speichern (action=savesubmission)
// -> "Entwurf gespeichert"; erst auf "Jetzt abgeben" des Menschen die Bestaetigung (action=submit -> confirmsubmit)
// -> "Abgegeben". Jeder Schritt genau ein Versuch, nie im Abgleich. NICHT MIT EINEM ECHTEN KONTO GEPRUEFT
// (docs/HSH-2026-11-05.md, Testliste): Feldnamen und Texte stammen aus dem Standard-Moodle.

public enum MoodleAssign {

    /// Aufgabe aus den gespeicherten Fristen (Moodle-Kalender, Art "abgabe")
    public struct Assignment: Sendable, Equatable, Identifiable {
        public let cmid: Int
        public let title: String
        public let dueAt: String
        public let course: String?
        public var id: Int { cmid }

        public init(cmid: Int, title: String, dueAt: String, course: String?) {
            self.cmid = cmid
            self.title = title
            self.dueAt = dueAt
            self.course = course
        }
    }

    public enum State: String, Sendable, Equatable {
        case none = "keine Abgabe"
        case draft = "Entwurf gespeichert"
        case submitted = "Abgegeben"
        case unknown = "unbekannt"
    }

    /// Stand einer Aufgabe auf ihrer Seite (Tabelle generaltable: Nummer, Abgabestatus, Bewertungsstatus, Zuletzt
    /// geändert, Dateiabgabe, Abgabekommentare; Strukturnotizen "Nachtrag 3"). Dateinamen der Abgabe (enthalten Name und
    /// Matrikelnummer) werden nie gelesen oder gespeichert.
    public struct Status: Sendable, Equatable {
        public var state: State
        /// Knopf "Abgabe bearbeiten/hinzufuegen" vorhanden
        public var canEdit: Bool
        /// Knopf "Abgabe abschliessen" vorhanden (Entwuerfe muessen abgegeben werden)
        public var canSubmit: Bool
        /// "Nicht bewertet", "Bewertet" ...
        public var grading: String? = nil
        /// "Dies ist Versuch 1."
        public var attempt: String? = nil
        /// Feedback der Lehrenden vorhanden (Abschnitt "Feedback")
        public var hasFeedback: Bool = false

        public init(state: State, canEdit: Bool, canSubmit: Bool, grading: String? = nil, attempt: String? = nil, hasFeedback: Bool = false) {
            self.state = state
            self.canEdit = canEdit
            self.canSubmit = canSubmit
            self.grading = grading
            self.attempt = attempt
            self.hasFeedback = hasFeedback
        }
    }

    /// Zeilen der Statustabelle (Kopfzelle -> Wert), ohne "Dateiabgabe" (Dateinamen mit Personendaten)
    public static func statusRows(html: String) -> [String: String] {
        var out: [String: String] = [:]
        for t in HTMLScanner.scan(html).tables {
            for row in t.rows where row.count >= 2 {
                let key = HText.collapse(row[0].text)
                guard !key.isEmpty, !key.lowercased().hasPrefix("dateiabgabe"), !key.lowercased().hasPrefix("file submissions") else { continue }
                if out[key] == nil { out[key] = HText.collapse(row[1].text) }
            }
        }
        return out
    }

    /// Daten des Abgabe-Formulars
    public struct EditForm: Sendable, Equatable {
        public var fields: [String: String]
        public var draftItemID: String
        public var repositoryID: String
        public var contextID: String
    }

    /// Bestaetigungs-Formular (mit Erklaerung zur Eigenstaendigkeit, falls die Aufgabe eine verlangt)
    public struct ConfirmForm: Sendable, Equatable {
        public var fields: [String: String]
        public var statement: String?
    }

    // MARK: Regeln (rein)

    private static let cmidRE = HText.regex(#"/mod/assign/view\.php\?id=(\d+)"#)

    public static func cmid(fromURL url: String?) -> Int? {
        (HText.match(cmidRE, url ?? "")?.groups[1] ?? nil).flatMap { Int($0) }
    }

    /// Offene und vergangene Abgaben aus den Fristen der Quelle "learnweb" (Moodle; HsH und Hildesheim)
    public static func assignments(_ c: SQLiteConnection) throws -> [Assignment] {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='deadlines'") != nil else { return [] }
        var seen = Set<Int>(), out: [Assignment] = []
        for r in try c.rows("""
            SELECT d.title, d.due_at, d.url, c.title AS course FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id
            WHERE d.source='learnweb' AND d.kind='abgabe' ORDER BY d.due_at DESC
            """) {
            guard let id = cmid(fromURL: r["url"]?.string), seen.insert(id).inserted else { continue }
            out.append(Assignment(cmid: id, title: r["title"]?.string ?? "Aufgabe", dueAt: r["due_at"]?.string ?? "",
                                  course: r["course"]?.string))
        }
        return out
    }

    private static let draftRE = HText.regex("(Entwurf \\(nicht abgegeben\\)|Draft \\(not submitted\\))", [.caseInsensitive])
    private static let submittedRE = HText.regex("(Zur Bewertung abgegeben|Submitted for grading|Abgegeben zur Bewertung)", [.caseInsensitive])
    private static let noneRE = HText.regex("(Keine Abgabe|Keine Einreichung|Kein Versuch|No attempt|Nothing has been submitted)", [.caseInsensitive])

    /// Stand von der Seite der Aufgabe (view.php?id=…)
    public static func status(html: String) -> Status {
        let state: State = HText.match(submittedRE, html) != nil ? .submitted
            : HText.match(draftRE, html) != nil ? .draft
            : HText.match(noneRE, html) != nil ? .none : .unknown
        let rows = statusRows(html: html)
        return Status(state: state, canEdit: html.contains("action=editsubmission"), canSubmit: html.contains("action=submit\"") || html.contains("action=submit&"),
                      grading: rows["Bewertungsstatus"] ?? rows["Grading status"], attempt: rows["Nummer"] ?? rows["Attempt number"],
                      hasFeedback: html.range(of: ">Feedback<", options: .caseInsensitive) != nil)
    }

    private static let formRE = HText.regex("<form\\b[^>]*>(.*?)</form>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let inputRE = HText.regex("<input\\b[^>]*>", [.caseInsensitive])
    private static let attrRE = HText.regex("([a-zA-Z_:-]+)\\s*=\\s*\"([^\"]*)\"")

    static func attributes(_ tag: String) -> [String: String] {
        var a: [String: String] = [:]
        let ns = tag as NSString
        for m in attrRE.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            a[ns.substring(with: m.range(at: 1)).lowercased()] = QISParser.decodeEntities(ns.substring(with: m.range(at: 2)))
        }
        return a
    }

    /// Versteckte Felder (und angehakte Kontrollkaestchen) des Formulars, das `marker` enthaelt
    static func hiddenFields(html: String, marker: String) -> [String: String]? {
        guard let form = HText.allMatches(formRE, html).first(where: { $0.contains(marker) }) else { return nil }
        var out: [String: String] = [:]
        let ns = form as NSString
        for m in inputRE.matches(in: form, range: NSRange(location: 0, length: ns.length)) {
            let a = attributes(ns.substring(with: m.range))
            guard let name = a["name"], (a["type"] ?? "").lowercased() == "hidden" else { continue }
            out[name] = a["value"] ?? ""
        }
        return out
    }

    private static let uploadRepoRE = HText.regex(#""id"\s*:\s*"?(\d+)"?\s*,[^{}]*?"type"\s*:\s*"upload""#)
    private static let uploadRepoRE2 = HText.regex(#""type"\s*:\s*"upload"[^{}]*?"id"\s*:\s*"?(\d+)"?"#)
    private static let contextRE = HText.regex(#""context"\s*:\s*\{\s*"id"\s*:\s*"?(\d+)"#)
    private static let contextRE2 = HText.regex(#""contextid"\s*:\s*"?(\d+)"#)

    /// Abgabe-Formular (mod_assign_submission_form): versteckte Felder, Entwurfsbereich (files_filemanager),
    /// Upload-Repository und Kontext aus den Optionen der Dateiauswahl
    public static func editForm(html: String) -> EditForm? {
        guard let f = hiddenFields(html: html, marker: "_qf__mod_assign_submission_form"),
              let item = f["files_filemanager"], !item.isEmpty,
              let repo = (HText.match(uploadRepoRE, html)?.groups[1] ?? nil) ?? (HText.match(uploadRepoRE2, html)?.groups[1] ?? nil),
              let ctx = (HText.match(contextRE, html)?.groups[1] ?? nil) ?? (HText.match(contextRE2, html)?.groups[1] ?? nil) else { return nil }
        return EditForm(fields: f, draftItemID: item, repositoryID: repo, contextID: ctx)
    }

    private static let statementRE = HText.regex("<input\\b[^>]*name=\"submissionstatement\"[^>]*>(?:.*?<label[^>]*>)?(.*?)</label>",
                                                 [.caseInsensitive, .dotMatchesLineSeparators])

    /// Bestaetigungs-Formular (mod_assign_confirm_submission_form); `statement`: Text der Erklaerung, falls verlangt
    public static func confirmForm(html: String) -> ConfirmForm? {
        guard let f = hiddenFields(html: html, marker: "_qf__mod_assign_confirm_submission_form") else { return nil }
        let st = (HText.match(statementRE, html)?.groups[1] ?? nil).map { HText.collapse(Announcements.htmlToText($0)) }
        return ConfirmForm(fields: f, statement: html.contains("name=\"submissionstatement\"") ? (st?.isEmpty == false ? st : "Erklärung zur Abgabe") : nil)
    }

    /// Felder fuer das Speichern des Entwurfs (wie der Knopf "Änderungen sichern")
    public static func saveFields(_ form: EditForm) -> [(String, String)] {
        var f = form.fields
        f["files_filemanager"] = form.draftItemID
        f["submitbutton"] = "Änderungen sichern"
        return f.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Felder fuer "Abgabe abschliessen"; die Erklaerung nur, wenn der Mensch sie bestaetigt hat
    public static func confirmFields(_ form: ConfirmForm, statementAccepted: Bool) -> [(String, String)] {
        var f = form.fields
        if form.statement != nil, statementAccepted { f["submissionstatement"] = "1" }
        f["submitbutton"] = "Weiter"
        return f.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: Ablauf mit der Sitzung

    /// Stand einer Aufgabe lesen
    public static func fetchStatus(web: MoodleWeb, cmid: Int) async throws -> Status {
        status(html: try await web.page("/mod/assign/view.php?id=\(cmid)").html)
    }

    /// PDF als Entwurf hochladen und speichern (noch nicht abgegeben, wenn die Aufgabe Entwuerfe kennt).
    /// Rueckgabe: Stand danach und der Dateiname, unter dem Moodle die Datei ablegte.
    public static func saveDraft(web: MoodleWeb, cmid: Int, pdf: Data, fileName: String) async throws -> (status: Status, savedName: String) {
        let page = try await web.page("/mod/assign/view.php?id=\(cmid)&action=editsubmission").html
        guard let form = editForm(html: page) else { throw MoodleError.unexpectedPage("Abgabe-Formular ohne Datei-Upload") }
        let sesskey = try await web.current().sesskey
        let upload = try await web.postMultipart("/repository/repository_ajax.php?action=upload",
                                                 fields: [("sesskey", sesskey), ("repo_id", form.repositoryID), ("itemid", form.draftItemID),
                                                          ("author", ""), ("savepath", "/"), ("title", fileName), ("ctx_id", form.contextID),
                                                          ("env", "filemanager"), ("maxbytes", "-1"), ("areamaxbytes", "-1")],
                                                 file: ("repo_upload_file", fileName, "application/pdf", pdf))
        // gleicher Name schon im Entwurf: Moodle legt die Datei unter neuem Namen ab ("fileexists")
        let saved = upload["newfile"]?["filename"]?.string ?? upload["file"]?.string ?? fileName
        let result = try await web.postForm("/mod/assign/view.php", saveFields(form))
        return (status(html: result.html), saved)
    }

    /// Bestaetigungs-Seite lesen (zeigt, ob eine Erklaerung verlangt ist), ohne etwas abzusenden
    public static func fetchConfirm(web: MoodleWeb, cmid: Int) async throws -> ConfirmForm {
        let page = try await web.page("/mod/assign/view.php?id=\(cmid)&action=submit").html
        guard let form = confirmForm(html: page) else { throw MoodleError.unexpectedPage("Bestätigung der Abgabe") }
        return form
    }

    /// "Jetzt abgeben": Bestaetigung absenden. Nur auf ausdruecklichen Knopfdruck aufrufen.
    public static func submit(web: MoodleWeb, cmid: Int, statementAccepted: Bool) async throws -> Status {
        let page = try await web.page("/mod/assign/view.php?id=\(cmid)&action=submit").html
        guard let form = confirmForm(html: page) else { throw MoodleError.unexpectedPage("Bestätigung der Abgabe") }
        if form.statement != nil, !statementAccepted { throw MoodleError.refused("Erklärung nicht bestätigt") }
        return status(html: try await web.postForm("/mod/assign/view.php", confirmFields(form, statementAccepted: statementAccepted)).html)
    }
}
