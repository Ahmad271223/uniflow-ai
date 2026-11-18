import Foundation

/// Fortschritt eines Datei-Abgleichs fuer die Anzeige (Auftrag des Inhabers 15.11.2026: "wenn jemand sein uni konto
/// verbindet soll alles direkt klappen", docs/ERST-ABGLEICH-2026-11-15.md). Ein Bild fuer alle Hochschulen (Stud.IP,
/// Learnweb, Moodle): erst die Dateilisten aller Kurse, dann die Downloads. Die Anzeige steht nur, solange geladen
/// wird; die Dauerleiste "Learnweb ok · LSF ok" kommt damit nicht zurueck.
public struct SyncProgress: Sendable, Equatable {
    public enum Step: String, Sendable {
        /// Kursliste wird gelesen
        case courses
        /// Dateilisten der Kurse (`coursesDone` von `coursesTotal`)
        case lists
        /// Downloads (`filesDone` von `filesTotal`)
        case files
    }

    public var step: Step
    public var coursesDone: Int
    public var coursesTotal: Int
    public var filesDone: Int
    public var filesTotal: Int
    /// Kurs, der gerade dran ist
    public var current: String?
    /// nur Kurse frueherer Semester (Stufe d)
    public var older: Bool

    public init(step: Step = .courses, coursesDone: Int = 0, coursesTotal: Int = 0, filesDone: Int = 0, filesTotal: Int = 0,
                current: String? = nil, older: Bool = false) {
        self.step = step
        self.coursesDone = coursesDone
        self.coursesTotal = coursesTotal
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.current = current
        self.older = older
    }

    /// Eine Zeile in einfachem Deutsch: "Deine Kurse werden geladen: 121 von 250 Dateien"
    public var title: String {
        let what = older ? "Frühere Semester werden geladen" : "Deine Kurse werden geladen"
        switch step {
        case .courses:
            return what + " …"
        case .lists:
            guard coursesTotal > 0 else { return what + " …" }
            var text = "\(what): \(coursesDone) von \(coursesTotal) \(coursesTotal == 1 ? "Kurs" : "Kursen")"
            // solange noch Listen fehlen, ist die Zahl der Dateien nur ein Zwischenstand
            if filesTotal > 0 { text += " · bisher \(filesTotal) \(filesTotal == 1 ? "Datei" : "Dateien")" }
            return text
        case .files:
            guard filesTotal > 0 else { return what + " …" }
            return "\(what): \(min(filesDone, filesTotal)) von \(filesTotal) \(filesTotal == 1 ? "Datei" : "Dateien")"
        }
    }

    /// Zweite Zeile: der Kurs, der gerade dran ist
    public var detail: String? { current.flatMap { $0.isEmpty ? nil : "Gerade: \($0)" } }

    /// Anteil fuer den Balken (0 … 1); nil, solange es noch keine Zahl gibt
    public var fraction: Double? {
        switch step {
        case .courses: return nil
        case .lists: return coursesTotal > 0 ? Double(min(coursesDone, coursesTotal)) / Double(coursesTotal) : nil
        case .files: return filesTotal > 0 ? Double(min(filesDone, filesTotal)) / Double(filesTotal) : nil
        }
    }
}

/// Was vom Datei-Abgleich noch aussteht, je Kurs und Modul, aus der Datenbank (nur dieses Geraet): Kurse, deren
/// Dateiliste noch nie gelesen wurde (`course_file_lists`, erst bei Bedarf angelegt wie `file_download_failures`), und
/// gelistete Dateien, die noch nicht auf dem Geraet liegen. Die Module zeigen damit "Dateien werden noch geladen …"
/// statt "keine Dateien", solange ein Abgleich laeuft oder unterbrochen wurde.
public enum SyncPending {
    static let table = """
        CREATE TABLE IF NOT EXISTS course_file_lists (
            course_id TEXT PRIMARY KEY,        -- courses.id
            listed_at TEXT NOT NULL            -- Ortszeit der letzten vollstaendig gelesenen Dateiliste
        )
        """

    static func exists(_ c: SQLiteConnection, _ name: String = "course_file_lists") throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(name)]) != nil
    }

    /// Dateiliste dieses Kurses ist vollstaendig gelesen und gespeichert. Beim ersten Mal merkt sich der Kurs den
    /// Zeitpunkt (`UniStore.markFirstListing`): "Neu" ist nur, was danach dazukommt.
    public static func markListed(_ c: SQLiteConnection, courseID: String, now: String) throws {
        try UniStore.markFirstListing(c, courseID: courseID, now: now)
        try c.executeScript(table)
        try c.execute("""
            INSERT INTO course_file_lists(course_id, listed_at) VALUES (?,?)
            ON CONFLICT(course_id) DO UPDATE SET listed_at=excluded.listed_at
            """, [.text(courseID), .text(now)])
    }

    public struct Course: Sendable, Equatable {
        public let id: String
        public let moduleID: Int?
        /// Dateiliste schon einmal gelesen
        public let listed: Bool
        /// gelistete Dateien, die noch nicht auf dem Geraet liegen (ohne Links, Videos und Absagen 403/404)
        public let waiting: Int
    }

    public struct Overview: Sendable, Equatable {
        public var courses: [Course] = []

        public init(courses: [Course] = []) { self.courses = courses }

        /// Kurse ohne gelesene Dateiliste
        public var unlisted: Int { courses.filter { !$0.listed }.count }
        /// Dateien, die noch geladen werden
        public var waiting: Int { courses.reduce(0) { $0 + $1.waiting } }
        public var isEmpty: Bool { unlisted == 0 && waiting == 0 }

        /// Steht fuer dieses Modul noch etwas aus? (`unlisted`: mindestens ein Kurs ohne Liste, `waiting`: Dateien)
        public func module(_ id: Int) -> (unlisted: Int, waiting: Int) {
            let mine = courses.filter { $0.moduleID == id }
            return (mine.filter { !$0.listed }.count, mine.reduce(0) { $0 + $1.waiting })
        }

        public func course(_ id: String) -> Course? { courses.first { $0.id == id } }
    }

    /// Stand der aktiven Kurse einer Hochschul-Quelle (ohne eigene Dateien `__user__`). Ohne die Tabelle
    /// `course_file_lists` (vor dieser Fassung abgeglichen) gilt ein Kurs mit Dateien als gelistet.
    public static func overview(_ c: SQLiteConnection) throws -> Overview {
        let lists = try exists(c)
        let failures = try exists(c, "file_download_failures")
        let refused = failures ? "AND f.id NOT IN (SELECT id FROM file_download_failures WHERE status IN (403, 404))" : ""
        let listed = lists ? "EXISTS (SELECT 1 FROM course_file_lists l WHERE l.course_id = c.id)" : "0"
        let rows = try c.rows("""
            SELECT c.id AS id, c.module_id AS module_id, \(listed) AS listed,
                   (SELECT COUNT(*) FROM files f WHERE f.course_id = c.id) AS files,
                   (SELECT COUNT(*) FROM files f WHERE f.course_id = c.id AND (f.local_path IS NULL OR f.local_path = '')
                        AND f.deleted_at IS NULL AND COALESCE(f.kind, '') NOT IN ('link', 'video') \(refused)) AS waiting
            FROM courses c WHERE COALESCE(c.active, 1) = 1 AND c.id <> '__user__' ORDER BY c.id
            """)
        return Overview(courses: rows.compactMap { r in
            guard let id = r["id"]?.string else { return nil }
            let files = r["files"]?.int ?? 0
            return Course(id: id, moduleID: r["module_id"]?.int, listed: r["listed"]?.int == 1 || (!lists && files > 0),
                          waiting: r["waiting"]?.int ?? 0)
        })
    }

    /// Hinweis im Modul bzw. Kurs, solange geladen wird; nil, wenn nichts aussteht
    public static func hint(unlisted: Int, waiting: Int) -> String? {
        if waiting > 0 { return "\(waiting) \(waiting == 1 ? "Datei wird" : "Dateien werden") noch geladen …" }
        if unlisted > 0 { return "Dateien werden noch geladen …" }
        return nil
    }
}

/// Reihenfolge und Gleichzeitigkeit der Downloads (15.11.2026): das Wichtige zuerst und massvoll nebeneinander.
public enum DownloadPlan {
    /// Downloads zugleich, solange die Hochschule nicht bremst
    public static let lanes = 3
    /// Dateilisten zugleich (Learnweb/Moodle; Stud.IP hat seine eigene Grenze, `StudIPClient.defaultConcurrency`)
    public static let listLanes = 3

    /// Groessenklasse: 0 = klein (bis 2 MB), 1 = mittel oder unbekannt (bis 20 MB), 2 = gross
    public static func sizeClass(_ size: Int?) -> Int {
        guard let size, size > 0 else { return 1 }
        if size <= 2 * 1024 * 1024 { return 0 }
        return size <= 20 * 1024 * 1024 ? 1 : 2
    }

    /// Reihenfolge der Downloads (`download_order` in app/sync_order.py): laufendes Semester vor dem naechsten und vor
    /// frueheren (`stage`: 0, 1, 2), darin kleine vor grossen (`sizeClass`), darin neue vor alten (`changed`,
    /// Unix-Zeit), sonst wie geliefert.
    public static func order<T>(_ items: [T], stage: (T) -> Int, size: (T) -> Int?, changed: (T) -> Int?) -> [T] {
        items.enumerated().sorted { a, b in
            let ka = (stage(a.element), sizeClass(size(a.element)), -(changed(a.element) ?? 0), a.offset)
            let kb = (stage(b.element), sizeClass(size(b.element)), -(changed(b.element) ?? 0), b.offset)
            return ka < kb
        }.map(\.element)
    }

    /// Die Hochschule bremst oder ist gestoert (429, 5xx): danach nur noch einzeln
    public static func isOverload(_ error: Error) -> Bool {
        if case .http(let s, _)? = error as? HildesheimError { return s == 429 || s >= 500 }
        if case .http(let s, _)? = error as? StudIPError { return s == 429 || s >= 500 }
        return false
    }

    /// `items` nebeneinander abarbeiten, hoechstens `lanes.limit` zugleich (die Grenze kann waehrend des Laufs sinken).
    /// `work` liefert false, wenn nichts Neues mehr beginnen soll (Abbruch, Anmeldung abgelaufen); Laufendes endet noch.
    public static func forEach<T: Sendable>(_ items: [T], lanes: DownloadLanes,
                                            _ work: @escaping @Sendable (Int, T) async -> Bool) async {
        await withTaskGroup(of: Bool.self) { group in
            var next = 0, running = 0, stopped = false
            while true {
                let limit = await lanes.limit
                while !stopped, !Task.isCancelled, running < limit, next < items.count {
                    let i = next
                    next += 1
                    running += 1
                    group.addTask {
                        await lanes.enter()
                        let goOn = await work(i, items[i])
                        await lanes.leave()
                        return goOn
                    }
                }
                guard running > 0, let goOn = await group.next() else { break }
                running -= 1
                if !goOn { stopped = true }
            }
        }
    }
}

/// Wie viele Downloads zugleich laufen duerfen. Beginnt bei `DownloadPlan.lanes`; nach der ersten Bremse der
/// Hochschule (429, 5xx) fuer den Rest des Laufs eins. Zaehlt mit, wie viele wirklich zugleich liefen (Tests, Bericht).
public actor DownloadLanes {
    public private(set) var limit: Int
    /// die Hochschule hat gebremst
    public private(set) var slowed = false
    /// hoechste Zahl gleichzeitiger Arbeiten in diesem Lauf
    public private(set) var peak = 0
    /// hoechste Zahl gleichzeitiger Arbeiten nach der Bremse
    public private(set) var peakAfterSlowdown = 0
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ limit: Int = DownloadPlan.lanes) { self.limit = max(1, limit) }

    /// 429 oder Serverfehler: ab jetzt einzeln
    public func slowDown() {
        slowed = true
        limit = 1
    }

    /// Platz belegen (wartet, solange nach einer Bremse noch mehr als erlaubt laufen)
    public func enter() async {
        while active >= limit {
            await withCheckedContinuation { waiters.append($0) }
        }
        active += 1
        peak = max(peak, active)
        if slowed { peakAfterSlowdown = max(peakAfterSlowdown, active) }
    }

    public func leave() {
        active = max(0, active - 1)
        let waiting = waiters
        waiters = []
        for w in waiting { w.resume() }
    }
}
