import Foundation
import UniFlowCore

// Opencast-Aufzeichnungen auf dem iPad (Kern: UniFlowCore/Opencast). Die Listen holt der Stud.IP-Abgleich
// (`refresh`, nur die Seiten media/index, nie ein Video) und legt sie in die lokale Datenbank des Containers
// (`OpencastStore`), geordnet nach Fach (Modul) und Lehrwoche wie die Dateien. Laden nur auf Wunsch (Entscheidung 7:
// ueber 100 MB nur nach ausdruecklicher Bestaetigung, `RecordingDownloadPolicy`), direkt auf die Platte
// (URLSessionDownloadTask, nicht in den Arbeitsspeicher), mit Fortschritt, Abbrechen und Fortsetzen. Geladene Dateien
// liegen im Stud.IP-Ordner unter `Aufzeichnungen/<Kurs>/<Video>-<Qualitaet>.mp4` (wie die Stud.IP-Dateien ohne
// Backup), der Pfad steht relativ zum Container in der Datenbank. Videos gehoeren den Lehrenden: kein Teilen, keine
// Freigabe in der Dateien-App. Anfragen an den Videoserver gehen ohne Stud.IP-Cookies (eigene, fluechtige Sitzung).

@MainActor
final class RecordingLibrary: ObservableObject {
    /// Zustand eines Downloads mit seiner Fassung: "Fortsetzen" und "Erneut" setzen genau diese fort (z. B. 1080p aus
    /// dem Kontextmenue), nicht die Standardfassung
    enum DownloadState: Equatable {
        /// laeuft; Anteil 0…1, nil solange die Groesse unbekannt ist
        case running(Double?, quality: String)
        /// abgebrochen, laesst sich fortsetzen
        case paused(quality: String)
        case failed(String, quality: String)

        var quality: String {
            switch self {
            case .running(_, let q), .paused(let q), .failed(_, let q): return q
            }
        }
    }

    /// Ergebnis einer HEAD-Anfrage an den Videoserver
    struct Probe: Equatable {
        let status: Int?
        let size: Int64?
        var needsLogin: Bool { status == 401 || status == 403 }

        /// Meldung statt der Rueckfrage zur unbekannten Groesse, wenn der Download gar nicht starten koennte: keine
        /// Antwort oder ein Fehlerstatus (z. B. 404, weil Opencast das Video unter neuer Adresse angelegt hat und die
        /// Liste bis zum naechsten Abgleich veraltet ist). nil bei Erfolg, bei Anmeldung (`needsLogin`, eigener Hinweis)
        /// und wenn der Server nur HEAD nicht kennt (405, 501): dann bleibt es bei der Rueckfrage.
        var failure: String? {
            guard let s = status else { return "Der Videoserver ist nicht erreichbar. Prüfe die Internetverbindung." }
            guard !needsLogin, s != 405, s != 501, let m = RecordingDownloadDelegate.failure(status: s, contentType: nil) else { return nil }
            return m + (s == 404 || s == 410 ? " Die Liste ist vermutlich veraltet, der nächste Stud.IP-Abgleich aktualisiert sie."
                                             : " Bitte später erneut versuchen.")
        }
    }

    /// Ergebnis des Abrufs im Stud.IP-Abgleich
    struct Outcome: Equatable {
        var result: OpencastStoreResult?
        var failedCourses = 0
        var sessionExpired = false
        var unreachable = false

        /// Teile fuer die Zusammenfassung des Abgleichs; Kurse ohne Opencast zaehlen nicht als Fehler
        var summary: [String] {
            var parts: [String] = []
            if let r = result {
                if r.newVideos > 0 { parts.append("\(r.newVideos) \(r.newVideos == 1 ? "neue Aufzeichnung" : "neue Aufzeichnungen")") }
            } else {
                parts.append("Aufzeichnungen nicht gespeichert")
            }
            if sessionExpired { parts.append("Aufzeichnungen: Stud.IP-Anmeldung abgelaufen") }
            else if unreachable { parts.append("Aufzeichnungen: Stud.IP nicht erreichbar") }
            else if failedCourses > 0 { parts.append("Aufzeichnungen von \(failedCourses) \(failedCourses == 1 ? "Kurs" : "Kursen") nicht lesbar") }
            return parts
        }
    }

    /// laufende, abgebrochene und gescheiterte Downloads je Aufzeichnung (`OpencastEntry.id`)
    @Published private(set) var states: [String: DownloadState] = [:]
    /// zaehlt hoch, wenn sich Aufzeichnungen oder geladene Dateien aendern (offene Bereiche laden neu)
    @Published private(set) var revision = 0

    /// Ordner der geladenen Aufzeichnungen (im Stud.IP-Ordner des Containers)
    let root: URL
    private let host: LocalBackendHost
    private let session: URLSession
    let delegate: RecordingDownloadDelegate
    private var tasks: [String: URLSessionDownloadTask] = [:]

    init(root: URL, host: LocalBackendHost) {
        self.root = root
        self.host = host
        let d = RecordingDownloadDelegate()
        delegate = d
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil                                           // Videos nie im URL-Zwischenspeicher
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        d.owner = self
    }

    /// Die Sitzung haelt ihren Delegaten; ohne Aufloesen blieben beide nach einem Containerwechsel liegen
    deinit { session.invalidateAndCancel() }

    var partialFolder: URL { root.appendingPathComponent(RecordingFiles.partialFolder, isDirectory: true) }

    func target(_ e: OpencastEntry, quality: String) -> URL {
        root.appendingPathComponent(RecordingFiles.relativePath(courseID: e.courseID, videoID: e.video.id, quality: quality))
    }

    func resumeURL(_ e: OpencastEntry, quality: String) -> URL {
        partialFolder.appendingPathComponent(RecordingFiles.resumeName(courseID: e.courseID, videoID: e.video.id, quality: quality))
    }

    /// geladene Datei einer Aufzeichnung, wenn sie (noch) da ist
    func localFile(_ e: OpencastEntry) -> (url: URL, quality: String)? {
        guard let path = e.localPath, let q = e.localQuality, let files = host.files, files.exists(stored: path),
              let url = files.url(stored: path) else { return nil }
        return (url, q)
    }

    func state(_ e: OpencastEntry) -> DownloadState? { states[e.id] }

    func isLoading(_ e: OpencastEntry) -> Bool { tasks[e.id] != nil }

    // MARK: Datenbank

    private func read<T: Sendable>(_ body: @escaping @Sendable (SQLiteConnection, UniFlowClock) throws -> T) async -> T? {
        guard let backend = try? await host.backend() else { return nil }
        let clock = backend.context.clock
        return try? await backend.context.database.withConnection { try body($0, clock) }
    }

    private func write(_ body: @escaping @Sendable (SQLiteConnection) throws -> Void) async -> Bool {
        guard let backend = try? await host.backend() else { return false }
        return (try? await backend.context.database.transaction(body)) != nil
    }

    func blocks(moduleID: Int) async -> [OpencastWeekBlock] {
        await read { try OpencastStore.moduleBlocks($0, moduleID: moduleID, clock: $1) } ?? []
    }

    func weekCounts(moduleID: Int) async -> [Int: Int] {
        await read { try OpencastStore.weekCounts($0, moduleID: moduleID, clock: $1) } ?? [:]
    }

    func unassigned() async -> [OpencastCourseGroup] {
        await read { try OpencastStore.unassigned($0, clock: $1) } ?? []
    }

    func match(fileID: String, text: String) async -> OpencastMatch? {
        await read { try OpencastStore.match($0, fileID: fileID, text: text, clock: $1) } ?? nil
    }

    func packageMatches(packageID: Int) async -> [OpencastTaskMatch] {
        await read { try OpencastStore.packageMatches($0, packageID: packageID, clock: $1) } ?? []
    }

    func reload(_ e: OpencastEntry) async -> OpencastEntry? {
        let course = e.courseID, video = e.video.id
        return await read { try OpencastStore.entry($0, courseID: course, videoID: video, clock: $1) } ?? nil
    }

    /// gemerkte Stelle (nach dem Abspielen, alle 10 s und beim Schliessen)
    func savePosition(_ e: OpencastEntry, seconds: Double) async {
        guard seconds.isFinite, seconds >= 0 else { return }
        let course = e.courseID, video = e.video.id
        _ = await write { try OpencastStore.savePosition($0, courseID: course, videoID: video, seconds: seconds) }
    }

    // MARK: Abruf im Stud.IP-Abgleich

    /// Aufzeichnungslisten der Kurse laden und speichern. Wirft nie: Fehler je Kurs ueberspringen nur diesen Kurs,
    /// Kurse ohne Opencast sind kein Fehler (und werden erst nach 7 Tagen erneut geprueft).
    func refresh(client: StudIPClient, courses: [StudIPCourse], progress: (String) -> Void = { _ in }) async -> Outcome {
        progress("Aufzeichnungen werden geprüft …")
        guard let backend = try? await host.backend() else { return Outcome(result: nil) }
        let db = backend.context.database, clock = backend.context.clock
        let known = (try? await db.withConnection { try OpencastStore.courseStates($0) }) ?? [:]
        let now = Int(clock.now.timeIntervalSince1970.rounded(.down))
        let fetched = await OpencastStore.fetch(client: client, courses: courses, known: known, now: now)
        var out = Outcome(failedCourses: fetched.failed.count, sessionExpired: fetched.sessionExpired, unreachable: fetched.unreachable)
        out.result = try? await db.transaction { try OpencastStore.store(fetched, in: $0, clock: clock) }
        revision += 1
        return out
    }

    // MARK: Groesse und Erreichbarkeit

    /// HEAD an den Videoserver: Status (401/403 = Anmeldung noetig) und Content-Length
    func probe(_ url: URL) async -> Probe {
        var r = URLRequest(url: url)
        r.httpMethod = "HEAD"
        r.timeoutInterval = 20
        guard let (_, response) = try? await session.data(for: r), let http = response as? HTTPURLResponse else { return Probe(status: nil, size: nil) }
        let len = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? (http.expectedContentLength > 0 ? http.expectedContentLength : nil)
        return Probe(status: http.statusCode, size: (200..<300).contains(http.statusCode) ? len : nil)
    }

    /// freier Platz fuer wichtige Daten auf dem Datentraeger der App
    func freeBytes() -> Int64? {
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Ordner

    /// Ordner anlegen und vom Backup ausnehmen (Aufzeichnungen lassen sich jederzeit neu laden).
    nonisolated static func prepareFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try excludeFromBackup(url)
    }

    nonisolated static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try u.setResourceValues(values)
    }

    // MARK: Laden (nur auf Wunsch)

    /// Download starten bzw. fortsetzen. Fortsetzungsdaten nur fuer dieselbe Adresse und hoechstens 3 Tage alt
    /// (`RecordingResume`); veraltete werden verworfen, der Download startet frisch.
    func start(_ e: OpencastEntry, media d: OpencastMedia) {
        guard !isLoading(e) else { return }                                  // je Aufzeichnung ein Download
        let target = target(e, quality: d.quality), resume = resumeURL(e, quality: d.quality)
        do {
            try Self.prepareFolder(root)
            try Self.prepareFolder(target.deletingLastPathComponent())
            try Self.prepareFolder(partialFolder)
        } catch {
            states[e.id] = .failed("Ordner nicht anlegbar: \(error.localizedDescription)", quality: d.quality)
            return
        }
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resume), Self.resumeUsable(resume, url: d.url) {
            task = session.downloadTask(withResumeData: data)
        } else {
            Self.discardResume(resume)
            task = session.downloadTask(with: d.url)
        }
        delegate.register(task.taskIdentifier, job: .init(key: e.id, courseID: e.courseID, videoID: e.video.id, quality: d.quality,
                                                          url: d.url, target: target, resume: resume, previous: localFile(e)?.url))
        tasks[e.id] = task
        states[e.id] = .running(nil, quality: d.quality)
        task.resume()
    }

    /// Abbrechen; was schon geladen ist, bleibt fuer "Fortsetzen" liegen
    func cancel(_ e: OpencastEntry) {
        guard let task = tasks.removeValue(forKey: e.id), let job = delegate.forget(task.taskIdentifier) else { states[e.id] = nil; return }
        let paused = DownloadState.paused(quality: job.quality)
        states[e.id] = paused
        let key = e.id
        task.cancel { [weak self] data in
            if let data { Self.saveResume(data, job: job) } else { Self.discardResume(job.resume) }
            Task { @MainActor in
                if data == nil, self?.states[key] == paused { self?.states[key] = nil }
            }
        }
    }

    /// Hat dieser Download Fortsetzungsdaten (abgebrochen)?
    func hasResumeData(_ e: OpencastEntry, quality: String) -> Bool {
        FileManager.default.fileExists(atPath: resumeURL(e, quality: quality).path)
    }

    /// Fassung fuer "Fortsetzen" und "Erneut": die des laufenden, abgebrochenen oder gescheiterten Downloads, sonst
    /// (z. B. nach einem Neustart der App) die Fassung mit Fortsetzungsdaten; nil, wenn es keine gibt.
    func resumeMedia(_ e: OpencastEntry) -> OpencastMedia? {
        if let q = states[e.id]?.quality, let m = e.video.media(q) { return m }
        return pausedMedia(e)
    }

    /// Fassung mit Fortsetzungsdaten; gibt es mehrere, die zuletzt abgebrochene
    func pausedMedia(_ e: OpencastEntry) -> OpencastMedia? {
        let paused = e.video.media.filter { hasResumeData(e, quality: $0.quality) }
        return paused.max { Self.resumeSavedAt(resumeURL(e, quality: $0.quality)) < Self.resumeSavedAt(resumeURL(e, quality: $1.quality)) }
    }

    /// Geladene Datei und Reste eines Downloads entfernen
    func remove(_ e: OpencastEntry) async {
        if let task = tasks.removeValue(forKey: e.id) {
            delegate.forget(task.taskIdentifier)
            task.cancel()
        }
        if let f = localFile(e) { try? FileManager.default.removeItem(at: f.url) }
        for m in e.video.media { Self.discardResume(resumeURL(e, quality: m.quality)) }
        states[e.id] = nil
        let course = e.courseID, video = e.video.id
        _ = await write { try OpencastStore.setLocal($0, courseID: course, videoID: video, path: nil, quality: nil) }
        revision += 1
    }

    /// Alle geladenen Aufzeichnungen entfernen ("Dateien loeschen" in Stud.IP); die Listen bleiben
    func removeAll() async {
        for (_, task) in tasks {
            delegate.forget(task.taskIdentifier)
            task.cancel()
        }
        tasks = [:]
        states = [:]
        try? FileManager.default.removeItem(at: root)
        _ = await write { try OpencastStore.forgetLocalFiles($0) }
        revision += 1
    }

    // MARK: Rueckmeldungen des Delegaten

    func progress(_ key: String, _ fraction: Double?, quality: String) {
        guard tasks[key] != nil else { return }
        states[key] = .running(fraction, quality: quality)
    }

    /// Download beendet: Datei liegt am Ziel (`stored` = nil bei Fehler). Pfad in die Datenbank, alte Fassung weg.
    func finished(_ job: RecordingDownloadDelegate.Job, error: String?) async {
        tasks[job.key] = nil
        if let error {
            states[job.key] = .failed(error, quality: job.quality)
            return
        }
        guard let stored = host.files?.stored(job.target) else {
            try? FileManager.default.removeItem(at: job.target)
            states[job.key] = .failed("Auf diesem Gerät gibt es keinen Speicherort für Aufzeichnungen.", quality: job.quality)
            return
        }
        let ok = await write { try OpencastStore.setLocal($0, courseID: job.courseID, videoID: job.videoID, path: stored, quality: job.quality) }
        guard ok else {
            try? FileManager.default.removeItem(at: job.target)
            states[job.key] = .failed("Die Aufzeichnung ließ sich nicht eintragen.", quality: job.quality)
            return
        }
        if let old = job.previous, old.standardizedFileURL != job.target.standardizedFileURL { try? FileManager.default.removeItem(at: old) }
        states[job.key] = nil
        revision += 1
    }

    func failed(_ key: String, message: String, quality: String) {
        tasks[key] = nil
        states[key] = .failed(message, quality: quality)
    }

    // MARK: Fortsetzungsdaten

    /// Begleitdatei mit Adresse und Zeitpunkt der Fortsetzungsdaten
    nonisolated static func resumeInfoURL(_ resume: URL) -> URL { resume.appendingPathExtension("json") }

    nonisolated static func saveResume(_ data: Data, job: RecordingDownloadDelegate.Job, now: Date = Date()) {
        try? data.write(to: job.resume, options: .atomic)
        let info: JSONValue = ["url": .string(job.url.absoluteString), "saved_at": .number(now.timeIntervalSince1970)]
        try? Data(info.jsonString(sortedKeys: true).utf8).write(to: resumeInfoURL(job.resume), options: .atomic)
        try? excludeFromBackup(job.resume)
    }

    /// Zeitpunkt der Fortsetzungsdaten aus der Begleitdatei (0, wenn sie fehlt)
    nonisolated static func resumeSavedAt(_ resume: URL) -> Double { resumeInfo(resume).savedAt?.timeIntervalSince1970 ?? 0 }

    /// Adresse und Zeitpunkt aus der Begleitdatei der Fortsetzungsdaten (nil, wenn sie fehlt oder unlesbar ist)
    nonisolated static func resumeInfo(_ resume: URL) -> (url: String?, savedAt: Date?) {
        guard let data = try? Data(contentsOf: resumeInfoURL(resume)), let info = try? JSONValue.parse(data) else { return (nil, nil) }
        return (info["url"]?.string, info["saved_at"]?.double.map { Date(timeIntervalSince1970: $0) })
    }

    nonisolated static func discardResume(_ resume: URL) {
        try? FileManager.default.removeItem(at: resume)
        try? FileManager.default.removeItem(at: resumeInfoURL(resume))
    }

    nonisolated static func resumeUsable(_ resume: URL, url: URL, now: Date = Date()) -> Bool {
        let info = resumeInfo(resume)
        return RecordingResume.usable(savedURL: info.url, savedAt: info.savedAt, currentURL: url, now: now)
    }
}

/// Delegat der Download-Sitzung. Die fertige Datei muss noch im Rueckruf verschoben werden (danach loescht das
/// System sie), deshalb liegen Ziel und Schluessel hier unter einer Sperre statt auf dem MainActor.
final class RecordingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Job: Sendable, Equatable {
        let key: String
        let courseID: String
        let videoID: String
        let quality: String
        let url: URL
        let target: URL
        let resume: URL
        /// bisher geladene Fassung (wird nach Erfolg entfernt)
        let previous: URL?
        /// zuletzt gemeldeter Anteil und Zeitpunkt (Fortschritt gedrosselt)
        var reported: Double?
        var reportedAt: Date?
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    weak var owner: RecordingLibrary?

    func register(_ id: Int, job: Job) { lock.lock(); jobs[id] = job; lock.unlock() }

    @discardableResult
    func forget(_ id: Int) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs.removeValue(forKey: id) }

    /// Fortschritt melden? Erster Rueckruf immer; danach nur bei mindestens 1 % Aenderung, am Ende oder alle 0,5 s
    /// (bei Dateien mit mehreren hundert MB sonst tausende Neuzeichnungen).
    static func shouldReport(last: Double?, lastAt: Date?, fraction: Double?, now: Date) -> Bool {
        guard let lastAt else { return true }
        guard let f = fraction else { return false }                     // Groesse unbekannt: Anzeige bleibt gleich
        guard let l = last else { return true }
        return f >= 1 || abs(f - l) >= 0.01 - 1e-9 || now.timeIntervalSince(lastAt) >= 0.5      // 1e-9: Rundung
    }

    /// Fehlermeldung zur Antwort des Videoservers oder nil, wenn die Datei ein Video sein kann
    static func failure(status: Int?, contentType: String?) -> String? {
        if let s = status, !(200..<300).contains(s) {
            return s == 401 || s == 403 ? "Der Videoserver verlangt eine Anmeldung (HTTP \(s))." : "Der Videoserver antwortet mit HTTP \(s)."
        }
        if (contentType ?? "").lowercased().contains("text/html") { return "Statt des Videos kam eine Webseite (vermutlich Anmeldung)." }
        return nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let f = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        let now = Date()
        lock.lock()
        guard var j = jobs[downloadTask.taskIdentifier], Self.shouldReport(last: j.reported, lastAt: j.reportedAt, fraction: f, now: now) else {
            lock.unlock()
            return
        }
        j.reported = f
        j.reportedAt = now
        jobs[downloadTask.taskIdentifier] = j
        lock.unlock()
        let key = j.key, quality = j.quality
        Task { @MainActor [weak owner] in owner?.progress(key, f, quality: quality) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let http = downloadTask.response as? HTTPURLResponse
        finish(downloadTask.taskIdentifier, location: location, status: http?.statusCode, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Fertige Datei an ihren Platz (oder verwerfen, wenn statt des Videos etwas anderes kam)
    func finish(_ id: Int, location: URL, status: Int?, contentType: String?) {
        guard let j = forget(id) else { return }
        let fm = FileManager.default
        var error = Self.failure(status: status, contentType: contentType)
        RecordingLibrary.discardResume(j.resume)                // verbraucht bzw. fuehrte zu dieser Antwort
        if error == nil {
            do {
                try? fm.removeItem(at: j.target)
                try fm.moveItem(at: location, to: j.target)
                try RecordingLibrary.excludeFromBackup(j.target)
                try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: j.target.path)
            } catch let e {
                error = "Datei nicht gespeichert: \(e.localizedDescription)"
            }
        }
        Task { @MainActor [weak owner] in await owner?.finished(j, error: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let j = forget(task.taskIdentifier) else { return }       // Erfolg meldet didFinishDownloadingTo
        let ns = error as NSError
        var message = (error as? URLError)?.code == .notConnectedToInternet ? "Keine Internetverbindung." : "Download unterbrochen."
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            RecordingLibrary.saveResume(data, job: j)
            message += " „Fortsetzen“ lädt weiter."
        } else {
            // ohne neue Fortsetzungsdaten sind die alten verbraucht oder ungueltig (Temp-Datei weg, Server ohne
            // Range, neue Adresse): verwerfen, sonst scheitert jedes "Fortsetzen" erneut an denselben Daten
            RecordingLibrary.discardResume(j.resume)
        }
        let key = j.key, quality = j.quality
        Task { @MainActor [weak owner] in owner?.failed(key, message: message, quality: quality) }
    }
}
