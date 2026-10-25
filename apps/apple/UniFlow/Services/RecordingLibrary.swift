import Foundation
import UniFlowCore

// Geladene Opencast-Aufzeichnungen auf dem iPad: nur auf Wunsch (Entscheidung des Inhabers: grosse Dateien nur auf
// Wunsch), direkt auf die Platte (URLSessionDownloadTask, nicht in den Arbeitsspeicher), mit Fortschritt, Abbrechen
// und Fortsetzen. Ablage Application Support/UniFlow/recordings/files/<Kurs>/<Video>-<Qualitaet>.mp4, ausgenommen
// vom Backup. Videos gehoeren den Lehrenden: kein Teilen, keine Freigabe in der Dateien-App.
// Anfragen gehen an den Opencast-Host ohne Stud.IP-Cookies (eigene, fluechtige URLSession).

extension Notification.Name {
    /// Geladene Aufzeichnungen wurden ausserhalb der Bibliothek geloescht (Stud.IP: "Dateien löschen")
    static let uniflowRecordingFilesChanged = Notification.Name("uniflow.recordingFilesChanged")
}

@MainActor
final class RecordingLibrary: ObservableObject {
    enum DownloadState: Equatable {
        /// laeuft; Anteil 0…1, nil solange die Groesse unbekannt ist
        case running(Double?)
        /// abgebrochen, laesst sich fortsetzen
        case paused
        case failed(String)
    }

    /// Ergebnis einer HEAD-Anfrage an den Videoserver
    struct Probe: Equatable {
        let status: Int?
        let size: Int64?
        var needsLogin: Bool { status == 401 || status == 403 }
    }

    /// laufende und abgebrochene Downloads, Schluessel `key(course:video:quality:)`
    @Published private(set) var states: [String: DownloadState] = [:]
    /// geladene Fassungen je Video ("<Kurs>|<Video>" -> ["720p"])
    @Published private(set) var downloaded: [String: Set<String>] = [:]
    /// abgebrochene Downloads mit Fortsetzungsdaten auf der Platte (Schluessel wie `states`)
    @Published private(set) var resumable: Set<String> = []
    /// Groesse per HEAD (nil = noch nicht gefragt, -1 = unbekannt)
    @Published private(set) var sizes: [URL: Int64] = [:]
    /// alle Dateien unter files/ (geladen oder angefangen), fuer verwaiste Dateien
    @Published private(set) var stored: [RecordingStoredFile] = []

    let root: URL
    private let session: URLSession
    let delegate: RecordingDownloadDelegate
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var pendingSizes: [URL] = []
    private var sizeTask: Task<Void, Never>?
    /// gemerkte Groessen (recordings/sizes.json, 7 Tage), damit nicht jeder Start jedes Video neu fragt
    private var sizeCache = RecordingSizeCache()
    private var observer: NSObjectProtocol?
    private static let positionsKey = "uniflow.recordings.positions"
    /// Pause zwischen zwei HEAD-Anfragen an den Videoserver (wie die Pausen im StudIPClient)
    static let headPauseNanos: UInt64 = 300_000_000

    init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? StudIPSync.recordingsFolder(support: support)
        let d = RecordingDownloadDelegate()
        delegate = d
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil                                           // Videos nie im URL-Zwischenspeicher
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        d.owner = self
        if let data = try? Data(contentsOf: sizesURL), var cache = try? RecordingSizeCache.decode(data) {
            cache.prune(now: Date())
            sizeCache = cache
        }
        rescan()
        // "Dateien löschen" in Stud.IP: laufende Downloads abbrechen (sie scheiterten sonst spaeter beim Verschieben)
        observer = NotificationCenter.default.addObserver(forName: .uniflowRecordingFilesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelAll()
                self?.rescan()
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    static func key(course: String, video: String, quality: String) -> String { "\(course)|\(video)|\(quality)" }
    static func videoKey(course: String, video: String) -> String { "\(course)|\(video)" }

    func fileURL(course: String, video: String, quality: String) -> URL {
        root.appendingPathComponent(RecordingFilesLayout.relativePath(courseID: course, videoID: video, quality: quality))
    }

    private var sizesURL: URL { root.appendingPathComponent(RecordingSizeCache.file) }

    /// Ort einer Datei aus `stored`
    func url(of f: RecordingStoredFile) -> URL {
        root.appendingPathComponent("files").appendingPathComponent(f.course)
            .appendingPathComponent("\(f.video)-\(f.quality).mp4" + (f.partial ? ".resume" : ""))
    }

    private func resumeURL(course: String, video: String, quality: String) -> URL {
        root.appendingPathComponent(RecordingFilesLayout.resumeDataPath(courseID: course, videoID: video, quality: quality))
    }

    func qualities(course: String, video: String) -> Set<String> { downloaded[Self.videoKey(course: course, video: video)] ?? [] }

    func state(course: String, video: String, quality: String) -> DownloadState? { states[Self.key(course: course, video: video, quality: quality)] }

    func isResumable(course: String, video: String, quality: String) -> Bool {
        resumable.contains(Self.key(course: course, video: video, quality: quality))
    }

    /// Laeuft fuer dieses Video gerade ein Download (gleich welche Fassung)?
    func isLoading(course: String, video: String) -> Bool {
        let prefix = Self.videoKey(course: course, video: video) + "|"
        return tasks.keys.contains { $0.hasPrefix(prefix) }
    }

    /// Fassung, die die Zeile zeigen soll: laufender Download zuerst, dann abgebrochene oder gescheiterte
    /// (Reihenfolge der Fassungen), sonst nil. Fuer alle Fassungen, nicht nur die Standardfassung.
    static func pendingQuality(course: String, video: String, qualities: [String], states: [String: DownloadState],
                               resumable: Set<String>) -> String? {
        let keys = qualities.map { (quality: $0, key: key(course: course, video: video, quality: $0)) }
        if let r = keys.first(where: { if case .running = states[$0.key] { return true }; return false }) { return r.quality }
        return keys.first { states[$0.key] != nil || resumable.contains($0.key) }?.quality
    }

    func pendingQuality(course: String, video: String, qualities: [String]) -> String? {
        Self.pendingQuality(course: course, video: video, qualities: qualities, states: states, resumable: resumable)
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

    /// geladene Dateien neu einlesen (nach Start, nach "Dateien löschen")
    func rescan() {
        var found: [String: Set<String>] = [:]
        var partial = Set<String>()
        var all: [RecordingStoredFile] = []
        let files = root.appendingPathComponent("files")
        let fm = FileManager.default
        for course in ((try? fm.contentsOfDirectory(atPath: files.path)) ?? []).sorted() {
            for name in ((try? fm.contentsOfDirectory(atPath: files.appendingPathComponent(course).path)) ?? []).sorted() {
                // "<Video>-<Qualitaet>.mp4" bzw. ".mp4.resume"; die Qualitaet enthaelt keinen Bindestrich
                guard let f = RecordingFilesLayout.storedFile(course: course, name: name) else { continue }
                all.append(f)
                if f.partial { partial.insert(Self.key(course: course, video: f.video, quality: f.quality)) }
                else { found[Self.videoKey(course: course, video: f.video), default: []].insert(f.quality) }
            }
        }
        downloaded = found
        resumable = partial
        stored = all
    }

    // MARK: Verwaiste Dateien

    /// Dateien ohne Video im Index (Kurs abgewaehlt oder Video aus Opencast entfernt)
    func orphans(in index: RecordingsIndex) -> [RecordingStoredFile] { RecordingFilesLayout.orphans(stored, index: index) }

    func bytes(_ files: [RecordingStoredFile]) -> Int64 {
        files.reduce(0) { acc, f in
            acc + Int64((try? url(of: f).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Verwaiste Dateien entfernen (auf Wunsch, in den Stud.IP-Einstellungen)
    func removeOrphans(in index: RecordingsIndex) {
        for f in orphans(in: index) {
            let key = Self.key(course: f.course, video: f.video, quality: f.quality)
            if let task = tasks.removeValue(forKey: key) { delegate.forget(task.taskIdentifier); task.cancel() }
            states[key] = nil
            try? FileManager.default.removeItem(at: url(of: f))
        }
        rescan()
    }

    /// Alle laufenden Downloads ohne Fortsetzungsdaten abbrechen (nach "Dateien löschen")
    func cancelAll() {
        for (key, task) in tasks {
            delegate.forget(task.taskIdentifier)
            task.cancel()
            states[key] = nil
        }
        tasks = [:]
    }

    // MARK: Groesse und Erreichbarkeit

    /// Groesse in die Warteschlange: zuerst die gemerkte (7 Tage), sonst HEAD nacheinander mit Pause dazwischen
    func requestSize(_ url: URL) {
        guard sizes[url] == nil, !pendingSizes.contains(url), !StudIPSync.isUnderTest() else { return }    // Tests: nie ans Netz
        if let cached = sizeCache.size(for: url, now: Date()) { sizes[url] = cached; return }
        pendingSizes.append(url)
        if sizeTask == nil {
            sizeTask = Task { [weak self] in
                var first = true
                while let self, let u = self.pendingSizes.first {
                    self.pendingSizes.removeFirst()
                    if !first { try? await Task.sleep(nanoseconds: Self.headPauseNanos) }
                    first = false
                    let p = await self.probe(u)
                    self.sizes[u] = p.size ?? -1
                }
                self?.sizeTask = nil
            }
        }
    }

    /// gemerkte Groesse ohne Anfrage (nil = nicht gemerkt oder aelter als 7 Tage)
    func cachedSize(_ url: URL, now: Date = Date()) -> Int64? { sizeCache.size(for: url, now: now) }

    func size(_ url: URL) -> Int64? { sizes[url].flatMap { $0 >= 0 ? $0 : nil } }

    /// HEAD an den Videoserver: Status (401/403 = Anmeldung noetig) und Content-Length
    func probe(_ url: URL) async -> Probe {
        var r = URLRequest(url: url)
        r.httpMethod = "HEAD"
        r.timeoutInterval = 20
        guard let (_, response) = try? await session.data(for: r), let http = response as? HTTPURLResponse else { return Probe(status: nil, size: nil) }
        let len = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? (http.expectedContentLength > 0 ? http.expectedContentLength : nil)
        let ok = (200..<300).contains(http.statusCode)
        if ok, let len { sizes[url] = len }
        if ok { rememberSize(len, for: url) }
        return Probe(status: http.statusCode, size: ok ? len : nil)
    }

    private func rememberSize(_ size: Int64?, for url: URL) {
        sizeCache.set(size, for: url, now: Date())
        guard let data = try? sizeCache.encoded() else { return }
        try? Self.prepareFolder(root)
        try? data.write(to: sizesURL, options: .atomic)
    }

    /// freier Platz fuer wichtige Daten auf dem Datentraeger der App
    func freeBytes() -> Int64? {
        let probe = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Laden

    /// Download starten bzw. fortsetzen (nur auf Wunsch des Nutzers).
    func start(course: String, video: String, download d: OpencastDownload) {
        let key = Self.key(course: course, video: video, quality: d.quality)
        guard !isLoading(course: course, video: video) else { return }       // je Video nur ein Download
        let target = fileURL(course: course, video: video, quality: d.quality)
        let resume = resumeURL(course: course, video: video, quality: d.quality)
        do { try Self.prepareFolder(target.deletingLastPathComponent()) } catch {
            states[key] = .failed("Ordner nicht anlegbar: \(error.localizedDescription)")
            return
        }
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resume) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: d.url)
        }
        delegate.register(task.taskIdentifier, key: key, target: target, resume: resume)
        tasks[key] = task
        states[key] = .running(nil)
        task.resume()
    }

    /// Abbrechen; was schon geladen ist, bleibt fuer "Fortsetzen" liegen
    func cancel(course: String, video: String, quality: String) {
        let key = Self.key(course: course, video: video, quality: quality)
        guard let task = tasks.removeValue(forKey: key) else { states[key] = nil; return }
        let resume = resumeURL(course: course, video: video, quality: quality)
        delegate.forget(task.taskIdentifier)
        states[key] = .paused
        task.cancel { [weak self] data in
            if let data { try? data.write(to: resume, options: .atomic); try? RecordingLibrary.excludeFromBackup(resume) }
            else { try? FileManager.default.removeItem(at: resume) }          // alte Daten passen nicht mehr
            Task { @MainActor in
                if data == nil, self?.states[key] == .paused { self?.states[key] = nil }
                self?.rescan()
            }
        }
    }

    /// Geladene Datei und Reste eines Downloads entfernen
    func remove(course: String, video: String, quality: String) {
        let key = Self.key(course: course, video: video, quality: quality)
        if let task = tasks.removeValue(forKey: key) {          // ohne Fortsetzungsdaten abbrechen
            delegate.forget(task.taskIdentifier)
            task.cancel()
        }
        try? FileManager.default.removeItem(at: fileURL(course: course, video: video, quality: quality))
        try? FileManager.default.removeItem(at: resumeURL(course: course, video: video, quality: quality))
        states[key] = nil
        rescan()
    }

    func progress(_ key: String, _ fraction: Double?) {
        guard tasks[key] != nil else { return }
        states[key] = .running(fraction)
    }

    func finished(_ key: String, error: String?, resumable: Bool) {
        tasks[key] = nil
        if let error { states[key] = resumable ? .failed(error + " – „Fortsetzen“ lädt weiter.") : .failed(error) } else { states[key] = nil }
        rescan()
    }

    // MARK: Wiedergabe

    func position(video: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double])?[video]
    }

    func savePosition(_ seconds: Double, video: String) {
        guard seconds.isFinite else { return }
        var all = (UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double]) ?? [:]
        all[video] = seconds
        if all.count > 500 { all = Dictionary(uniqueKeysWithValues: all.sorted { $0.key < $1.key }.suffix(400)) }
        UserDefaults.standard.set(all, forKey: Self.positionsKey)
    }
}

/// Delegat der Download-Sitzung. Die fertige Datei muss noch im Rueckruf verschoben werden (danach loescht das
/// System sie), deshalb liegen Ziel und Schluessel hier unter einer Sperre statt auf dem MainActor.
final class RecordingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Job {
        let key: String
        let target: URL
        let resume: URL
        /// zuletzt gemeldeter Anteil und Zeitpunkt (Fortschritt gedrosselt)
        var reported: Double?
        var reportedAt: Date?
    }
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    weak var owner: RecordingLibrary?

    func register(_ id: Int, key: String, target: URL, resume: URL) { lock.lock(); jobs[id] = Job(key: key, target: target, resume: resume); lock.unlock() }
    func forget(_ id: Int) { lock.lock(); jobs[id] = nil; lock.unlock() }
    private func job(_ id: Int) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }

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
        let key = j.key
        Task { @MainActor [weak owner] in owner?.progress(key, f) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let j = job(downloadTask.taskIdentifier) else { return }
        forget(downloadTask.taskIdentifier)
        let http = downloadTask.response as? HTTPURLResponse
        let fm = FileManager.default
        var error = Self.failure(status: http?.statusCode, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
        if error != nil {
            try? fm.removeItem(at: j.resume)                     // Fortsetzungsdaten fuehrten zu dieser Antwort: verwerfen
        } else {
            do {
                try? fm.removeItem(at: j.target)
                try fm.moveItem(at: location, to: j.target)
                try RecordingLibrary.excludeFromBackup(j.target)
                try? fm.removeItem(at: j.resume)
            } catch let e {
                error = "Datei nicht gespeichert: \(e.localizedDescription)"
            }
        }
        Task { @MainActor [weak owner] in owner?.finished(j.key, error: error, resumable: false) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let j = job(task.taskIdentifier) else { return }       // Erfolg meldet didFinishDownloadingTo
        forget(task.taskIdentifier)
        let ns = error as NSError
        var resumable = false
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: j.resume, options: .atomic)
            try? RecordingLibrary.excludeFromBackup(j.resume)
            resumable = true
        } else {
            // ohne neue Fortsetzungsdaten sind die alten verbraucht oder ungueltig (Temp-Datei weg, Server ohne
            // Range, neue URL): verwerfen, sonst scheitert jedes "Fortsetzen" erneut an denselben Daten
            try? FileManager.default.removeItem(at: j.resume)
        }
        let message = (error as? URLError)?.code == .notConnectedToInternet ? "Keine Internetverbindung." : "Download unterbrochen."
        Task { @MainActor [weak owner] in owner?.finished(j.key, error: message, resumable: resumable) }
    }
}
