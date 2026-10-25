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

    let root: URL
    private let session: URLSession
    private let delegate: DownloadDelegate
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var pendingSizes: [URL] = []
    private var sizeTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private static let positionsKey = "uniflow.recordings.positions"

    init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? StudIPSync.recordingsFolder(support: support)
        let d = DownloadDelegate()
        delegate = d
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil                                           // Videos nie im URL-Zwischenspeicher
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        d.owner = self
        rescan()
        observer = NotificationCenter.default.addObserver(forName: .uniflowRecordingFilesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    static func key(course: String, video: String, quality: String) -> String { "\(course)|\(video)|\(quality)" }
    static func videoKey(course: String, video: String) -> String { "\(course)|\(video)" }

    func fileURL(course: String, video: String, quality: String) -> URL {
        root.appendingPathComponent(RecordingFilesLayout.relativePath(courseID: course, videoID: video, quality: quality))
    }

    private func resumeURL(course: String, video: String, quality: String) -> URL {
        root.appendingPathComponent(RecordingFilesLayout.resumeDataPath(courseID: course, videoID: video, quality: quality))
    }

    func qualities(course: String, video: String) -> Set<String> { downloaded[Self.videoKey(course: course, video: video)] ?? [] }

    func state(course: String, video: String, quality: String) -> DownloadState? { states[Self.key(course: course, video: video, quality: quality)] }

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
        let files = root.appendingPathComponent("files")
        let fm = FileManager.default
        for course in (try? fm.contentsOfDirectory(atPath: files.path)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: files.appendingPathComponent(course).path)) ?? [] {
                // "<Video>-<Qualitaet>.mp4" bzw. ".mp4.resume"; die Qualitaet enthaelt keinen Bindestrich
                let isResume = name.hasSuffix(".mp4.resume")
                guard isResume || name.hasSuffix(".mp4") else { continue }
                let stem = String(name.dropLast(isResume ? 11 : 4))
                guard let dash = stem.lastIndex(of: "-") else { continue }
                let video = String(stem[..<dash]), quality = String(stem[stem.index(after: dash)...])
                if isResume { partial.insert(Self.key(course: course, video: video, quality: quality)) }
                else { found[Self.videoKey(course: course, video: video), default: []].insert(quality) }
            }
        }
        downloaded = found
        resumable = partial
    }

    // MARK: Groesse und Erreichbarkeit

    /// Groesse in die Warteschlange (HEAD nacheinander, nicht alle auf einmal)
    func requestSize(_ url: URL) {
        guard sizes[url] == nil, !pendingSizes.contains(url) else { return }
        pendingSizes.append(url)
        if sizeTask == nil {
            sizeTask = Task { [weak self] in
                while let self, let u = self.pendingSizes.first {
                    self.pendingSizes.removeFirst()
                    let p = await self.probe(u)
                    self.sizes[u] = p.size ?? -1
                }
                self?.sizeTask = nil
            }
        }
    }

    func size(_ url: URL) -> Int64? { sizes[url].flatMap { $0 >= 0 ? $0 : nil } }

    /// HEAD an den Videoserver: Status (401/403 = Anmeldung noetig) und Content-Length
    func probe(_ url: URL) async -> Probe {
        var r = URLRequest(url: url)
        r.httpMethod = "HEAD"
        r.timeoutInterval = 20
        guard let (_, response) = try? await session.data(for: r), let http = response as? HTTPURLResponse else { return Probe(status: nil, size: nil) }
        let len = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? (http.expectedContentLength > 0 ? http.expectedContentLength : nil)
        if (200..<300).contains(http.statusCode), let len { sizes[url] = len }
        return Probe(status: http.statusCode, size: (200..<300).contains(http.statusCode) ? len : nil)
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
        guard tasks[key] == nil else { return }
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
            Task { @MainActor in self?.rescan() }
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

    fileprivate func progress(_ key: String, _ fraction: Double?) {
        guard tasks[key] != nil else { return }
        states[key] = .running(fraction)
    }

    fileprivate func finished(_ key: String, error: String?, resumable: Bool) {
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
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Job { let key: String; let target: URL; let resume: URL }
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    weak var owner: RecordingLibrary?

    func register(_ id: Int, key: String, target: URL, resume: URL) { lock.lock(); jobs[id] = Job(key: key, target: target, resume: resume); lock.unlock() }
    func forget(_ id: Int) { lock.lock(); jobs[id] = nil; lock.unlock() }
    private func job(_ id: Int) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let j = job(downloadTask.taskIdentifier) else { return }
        let f = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        Task { @MainActor [weak owner] in owner?.progress(j.key, f) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let j = job(downloadTask.taskIdentifier) else { return }
        forget(downloadTask.taskIdentifier)
        let http = downloadTask.response as? HTTPURLResponse
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var error: String?
        if let s = http?.statusCode, !(200..<300).contains(s) {
            error = s == 401 || s == 403 ? "Der Videoserver verlangt eine Anmeldung (HTTP \(s))." : "Der Videoserver antwortet mit HTTP \(s)."
        } else if type.contains("text/html") {
            error = "Statt des Videos kam eine Webseite (vermutlich Anmeldung)."
        } else {
            do {
                let fm = FileManager.default
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
        }
        let message = (error as? URLError)?.code == .notConnectedToInternet ? "Keine Internetverbindung." : "Download unterbrochen."
        Task { @MainActor [weak owner] in owner?.finished(j.key, error: message, resumable: resumable) }
    }
}
