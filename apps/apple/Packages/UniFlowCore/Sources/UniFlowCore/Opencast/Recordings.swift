import Foundation

// Ablage und Abruf der Opencast-Aufzeichnungen: Index je Kurs (Application Support/UniFlow/recordings/index.json),
// Abruf im Stud.IP-Abgleich mit Pausen zwischen den Anfragen, Kurse ohne Opencast hoechstens alle 7 Tage erneut
// pruefen. Videos gehoeren den Lehrenden: nur privat ansehen, nie teilen; Dateien nur auf Wunsch laden und nie ins
// Backup (die App setzt isExcludedFromBackup, hier nur die Pfade).

/// Stand der Aufzeichnungen eines Kurses.
public struct RecordingCourse: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        /// Reiter "Aufzeichnungen" vorhanden (Liste darf leer sein)
        case available
        /// Kurs ohne Opencast; erneut pruefen nach `RecordingsRefresh.noOpencastRecheck`
        case noOpencast
    }

    public let courseID: String
    public var courseTitle: String
    public var status: Status
    public var videos: [OpencastVideo]
    public var lastChecked: Date

    public init(courseID: String, courseTitle: String, status: Status, videos: [OpencastVideo] = [], lastChecked: Date) {
        self.courseID = courseID
        self.courseTitle = courseTitle
        self.status = status
        self.videos = videos
        self.lastChecked = lastChecked
    }
}

/// Inhalt von recordings/index.json
public struct RecordingsIndex: Sendable, Equatable, Codable {
    public var version = 1
    public var courses: [RecordingCourse] = []

    public init(courses: [RecordingCourse] = []) { self.courses = courses }

    public func course(_ id: String) -> RecordingCourse? { courses.first { $0.courseID == id } }

    public var videoCount: Int { courses.reduce(0) { $0 + $1.videos.count } }

    public static func decode(_ data: Data) throws -> RecordingsIndex {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(RecordingsIndex.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}

public struct RecordingsRefreshResult: Sendable, Equatable {
    public var index: RecordingsIndex
    /// Kurse, deren Seite in diesem Durchgang gelesen wurde
    public var checked = 0
    /// Kurse ohne Opencast, die noch nicht wieder dran waren
    public var skipped = 0
    /// Kurstitel, deren Abruf scheiterte (alter Stand bleibt)
    public var failed: [String] = []
    /// Anfragegrenze erreicht: restliche Kurse beim naechsten Mal
    public var stoppedEarly = false

    public var summary: String {
        var parts = ["\(index.videoCount) Aufzeichnung\(index.videoCount == 1 ? "" : "en")"]
        if !failed.isEmpty { parts.append("\(failed.count) Kurs\(failed.count == 1 ? "" : "e") nicht erreichbar") }
        return parts.joined(separator: ", ")
    }
}

public enum RecordingsRefresh {
    /// Kurs ohne Opencast erst nach 7 Tagen erneut pruefen
    public static let noOpencastRecheck: TimeInterval = 7 * 24 * 3600

    /// Kurs in diesem Durchgang abrufen? Unbekannt oder mit Aufzeichnungen: ja; ohne Opencast erst nach 7 Tagen.
    public static func needsCheck(_ entry: RecordingCourse?, now: Date) -> Bool {
        guard let e = entry, e.status == .noOpencast else { return true }
        return now.timeIntervalSince(e.lastChecked) >= noOpencastRecheck || now < e.lastChecked
    }

}

extension StudIPClient {
    /// Aufzeichnungen eines Kurses frisch von Stud.IP. Wirft `sessionExpired` (Anmeldeseite) und `requestLimit`;
    /// jeder andere Fehler gilt nur fuer diesen Kurs.
    public func recordings(course: StudIPCourse, now: Date) async throws -> RecordingCourse? {
        let r = try await htmlPage(OpencastParser.mediaIndexPath(courseID: course.id))
        let html = String(decoding: r.body, as: UTF8.self)
        let status: RecordingCourse.Status
        var videos: [OpencastVideo] = []
        switch OpencastParser.parse(html: html, status: r.status, pageURL: r.finalURL ?? base) {
        case .videos(let v): status = .available; videos = v
        case .noOpencast: status = .noOpencast
        case .unrecognized:
            // Seite sagt nichts Eindeutiges: ohne Navigationslink "Aufzeichnungen" im Kursueberblick kein Opencast
            let o = try await htmlPage(OpencastParser.overviewPath(courseID: course.id))
            guard (200..<300).contains(o.status) else { throw StudIPError.http(status: o.status, path: "course/overview") }
            if OpencastParser.courseHasRecordings(overviewHTML: String(decoding: o.body, as: UTF8.self)) { return nil }
            status = .noOpencast
        }
        return RecordingCourse(courseID: course.id, courseTitle: course.title, status: status, videos: videos, lastChecked: now)
    }

    /// Alle gewaehlten Kurse nacheinander (Pausen wie bei der JSON:API). Der Index enthaelt danach genau diese
    /// Kurse; gescheiterte und uebersprungene behalten ihren alten Stand.
    public func refreshRecordings(courses: [StudIPCourse], index old: RecordingsIndex, now: Date) async throws -> RecordingsRefreshResult {
        var result = RecordingsRefreshResult(index: RecordingsIndex())
        var stop = false
        for c in courses {
            var previous = old.course(c.id)
            previous?.courseTitle = c.title
            if stop || !RecordingsRefresh.needsCheck(previous, now: now) {
                if let p = previous { result.index.courses.append(p) }
                if !stop { result.skipped += 1 }
                continue
            }
            do {
                if let fresh = try await recordings(course: c, now: now) {
                    result.index.courses.append(fresh)
                    result.checked += 1
                } else {
                    result.failed.append(c.title)
                    if let p = previous { result.index.courses.append(p) }
                }
            } catch StudIPError.sessionExpired {
                throw StudIPError.sessionExpired
            } catch StudIPError.requestLimit {
                stop = true
                result.stoppedEarly = true
                if let p = previous { result.index.courses.append(p) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failed.append(c.title)
                if let p = previous { result.index.courses.append(p) }
            }
        }
        return result
    }
}

// MARK: - Wiedergabe und Dateien

/// Woher ein Video abgespielt wird.
public enum RecordingPlaybackSource: Sendable, Equatable {
    /// geladene Datei (offline)
    case local(quality: String)
    /// direkt vom Videoserver
    case stream(URL, quality: String)
    /// Stud.IP-Player-Seite in der Webansicht (Ersatzweg)
    case webPlayer(URL)
    case unavailable
}

public enum RecordingPlayback {
    public static let preferredQuality = "720p"

    /// Fassung fuer Streaming und Download: gewuenschte, sonst 720p, sonst die beste unter 1080p, sonst die kleinste.
    public static func quality(for video: OpencastVideo, preferred: String? = nil) -> OpencastDownload? {
        let d = video.downloads
        if let p = preferred, let x = d.first(where: { $0.quality == p }) { return x }
        if let x = d.first(where: { $0.quality == preferredQuality }) { return x }
        if let x = d.filter({ $0.height > 0 && $0.height < 1080 }).max(by: { $0.height < $1.height }) { return x }
        return d.min { ($0.height == 0 ? Int.max : $0.height) < ($1.height == 0 ? Int.max : $1.height) }
    }

    /// Geladene Datei vor Stream (gewuenschte Fassung, sonst 720p, sonst irgendeine), Stream vor Webansicht.
    /// Wurde ausdruecklich eine nicht geladene Fassung gewaehlt (Qualitaetsmenue), gilt der Stream dieser Fassung.
    public static func source(for video: OpencastVideo, downloaded: Set<String>, preferred: String? = nil) -> RecordingPlaybackSource {
        if let p = preferred, !downloaded.contains(p), let d = video.download(p) { return .stream(d.url, quality: d.quality) }
        if !downloaded.isEmpty {
            for q in [preferred, preferredQuality].compactMap({ $0 }) where downloaded.contains(q) { return .local(quality: q) }
            if let q = video.downloads.map(\.quality).first(where: downloaded.contains) ?? downloaded.sorted().first { return .local(quality: q) }
        }
        if let d = quality(for: video, preferred: preferred) { return .stream(d.url, quality: d.quality) }
        if let p = video.playerURL { return .webPlayer(p) }
        return .unavailable
    }

    /// Fortsetzen an der gemerkten Stelle: nicht in den ersten 10 s und nicht in den letzten 15 s (dann von vorn).
    public static func resumePosition(saved: Double?, duration: Double?) -> Double? {
        guard let s = saved, s.isFinite, s >= 10 else { return nil }
        if let d = duration, d > 0, s >= d - 15 { return nil }
        return s
    }
}

/// Groessen der Videodateien (HEAD, Content-Length), gemerkt in recordings/sizes.json, damit nicht jeder App-Start
/// jedes Video erneut fragt. Eintraege gelten 7 Tage; -1 = Server nannte keine Groesse.
public struct RecordingSizeCache: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public let size: Int64
        public let checked: Date
    }

    public static let file = "sizes.json"
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    /// so viele Eintraege hoechstens (aelteste fallen weg)
    public static let maxEntries = 2000

    public var entries: [String: Entry] = [:]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    /// gemerkte Groesse (-1 = unbekannt) oder nil, wenn nie gefragt bzw. aelter als 7 Tage
    public func size(for url: URL, now: Date) -> Int64? {
        guard let e = entries[url.absoluteString], now.timeIntervalSince(e.checked) < Self.maxAge, e.checked <= now else { return nil }
        return e.size
    }

    public mutating func set(_ size: Int64?, for url: URL, now: Date) {
        entries[url.absoluteString] = Entry(size: size ?? -1, checked: now)
        if entries.count > Self.maxEntries {
            let keep = entries.sorted { $0.value.checked > $1.value.checked }.prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    /// abgelaufene Eintraege entfernen
    public mutating func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.checked) < Self.maxAge && $0.value.checked <= now }
    }

    public static func decode(_ data: Data) throws -> RecordingSizeCache {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(RecordingSizeCache.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}

/// Eine Datei unter recordings/files: geladene Fassung oder Fortsetzungsdaten eines abgebrochenen Downloads.
public struct RecordingStoredFile: Sendable, Equatable, Hashable {
    /// Ordnername des Kurses und Video-Kennung, wie sie im Dateinamen stehen
    public let course: String
    public let video: String
    public let quality: String
    public let partial: Bool

    public init(course: String, video: String, quality: String, partial: Bool) {
        self.course = course
        self.video = video
        self.quality = quality
        self.partial = partial
    }
}

public enum RecordingFilesLayout {
    /// Ordner unter Application Support/UniFlow
    public static let folder = "recordings"
    public static let indexFile = "index.json"

    /// "files/<Kurs>/<Video>-<Qualitaet>.mp4", relativ zum Ordner recordings
    public static func relativePath(courseID: String, videoID: String, quality: String) -> String {
        "files/\(StudIPImport.safeFileName(courseID))/\(StudIPImport.safeFileName("\(videoID)-\(quality)")).mp4"
    }

    /// Fortsetzungsdaten eines abgebrochenen Downloads neben der Zieldatei
    public static func resumeDataPath(courseID: String, videoID: String, quality: String) -> String {
        relativePath(courseID: courseID, videoID: videoID, quality: quality) + ".resume"
    }

    /// Dateiname unter files/<Kurs>/ lesen: "<Video>-<Qualitaet>.mp4" bzw. ".mp4.resume" (Qualitaet ohne Bindestrich)
    public static func storedFile(course: String, name: String) -> RecordingStoredFile? {
        let partial = name.hasSuffix(".mp4.resume")
        guard partial || name.hasSuffix(".mp4") else { return nil }
        let stem = String(name.dropLast(partial ? 11 : 4))
        guard let dash = stem.lastIndex(of: "-"), dash != stem.startIndex else { return nil }
        let quality = String(stem[stem.index(after: dash)...])
        guard !quality.isEmpty else { return nil }
        return RecordingStoredFile(course: course, video: String(stem[..<dash]), quality: quality, partial: partial)
    }

    /// Dateien ohne Eintrag im Index: Kurs abgewaehlt (nicht mehr im Index) oder Video aus Opencast entfernt.
    /// Verglichen wird ueber die Datei-Namen (`safeFileName`), wie `relativePath` sie bildet.
    public static func orphans(_ files: [RecordingStoredFile], index: RecordingsIndex) -> [RecordingStoredFile] {
        var known: [String: Set<String>] = [:]
        for c in index.courses {
            known[StudIPImport.safeFileName(c.courseID), default: []].formUnion(c.videos.map { StudIPImport.safeFileName($0.id) })
        }
        return files.filter { f in
            guard let videos = known[f.course] else { return true }
            return !videos.contains(f.video)
        }
    }

    /// Hinweis vor dem Laden: zu wenig Platz (Datei passt nicht) oder danach weniger als 1 GB frei.
    public static func storageWarning(fileSize: Int64?, freeBytes: Int64?) -> String? {
        guard let free = freeBytes else { return nil }
        let size = max(fileSize ?? 0, 0)
        if size > 0, size >= free { return "Nicht genug Speicherplatz: Die Aufzeichnung braucht \(megabytes(size)), frei sind \(megabytes(free))." }
        if free - size < 1_000_000_000 { return "Wenig Speicherplatz: Nach dem Laden sind nur noch \(megabytes(max(free - size, 0))) frei." }
        return nil
    }

    /// "412 MB", "1,2 GB"
    public static func megabytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            let gb = Double(bytes) / 1_000_000_000
            return String(format: "%.1f GB", gb).replacingOccurrences(of: ".", with: ",")
        }
        return "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }
}

// MARK: - Nach Lehrwoche

/// Ein Video mit Kurs und Lehrwoche, wie es die Oberflaeche zeigt.
public struct RecordingEntry: Sendable, Equatable, Identifiable {
    public let courseID: String
    public let courseTitle: String
    public let video: OpencastVideo
    public let week: LectureWeekGuess

    public var id: String { "\(courseID)|\(video.id)" }

    public init(courseID: String, courseTitle: String, video: OpencastVideo, week: LectureWeekGuess) {
        self.courseID = courseID
        self.courseTitle = courseTitle
        self.video = video
        self.week = week
    }
}

public enum RecordingWeeks {
    /// Videos der Kurse mit ihrer Lehrwoche
    public static func entries(_ courses: [RecordingCourse], semesterStart: Date?) -> [RecordingEntry] {
        courses.flatMap { c in
            c.videos.map { v in
                RecordingEntry(courseID: c.courseID, courseTitle: c.courseTitle, video: v,
                               week: LectureWeek.guess(title: v.title, description: v.description, created: v.created, semesterStart: semesterStart))
            }
        }
    }

    /// Bloecke wie die Wochenbloecke im Moduldetail: Woche aufsteigend, darin nach Erstelldatum und Titel;
    /// Videos ohne Woche zuletzt ("Ohne Woche", `week == nil`).
    public static func grouped(_ entries: [RecordingEntry]) -> [(week: Int?, entries: [RecordingEntry])] {
        var by: [Int: [RecordingEntry]] = [:]
        var none: [RecordingEntry] = []
        for e in entries { if let w = e.week.week { by[w, default: []].append(e) } else { none.append(e) } }
        func sort(_ l: [RecordingEntry]) -> [RecordingEntry] {
            l.sorted { ($0.video.created ?? .distantPast, $0.video.title, $0.id) < ($1.video.created ?? .distantPast, $1.video.title, $1.id) }
        }
        var out: [(week: Int?, entries: [RecordingEntry])] = by.keys.sorted().map { (week: $0, entries: sort(by[$0] ?? [])) }
        if !none.isEmpty { out.append((week: nil, entries: sort(none))) }
        return out
    }

    /// Anzahl je Lehrwoche (Hinweis "N Aufzeichnungen" in den Wochenbloecken der Uebersicht)
    public static func counts(_ entries: [RecordingEntry]) -> [Int: Int] {
        entries.reduce(into: [:]) { acc, e in if let w = e.week.week { acc[w, default: 0] += 1 } }
    }
}
