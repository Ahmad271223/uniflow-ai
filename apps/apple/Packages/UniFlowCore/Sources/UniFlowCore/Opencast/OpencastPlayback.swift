import Foundation

// Abspielen und Laden der Opencast-Aufzeichnungen ohne UI: welche Quelle der Player nimmt (geladene Datei, Stream,
// Stud.IP-Player-Seite), wo geladene Dateien liegen, wann Fortsetzungsdaten noch taugen und wann ein Download eine
// ausdrueckliche Bestaetigung braucht. Videos gehoeren den Lehrenden: nur privat ansehen, nie teilen; geladen wird
// nur auf Wunsch (Entscheidung 7 in docs/IPAD-OHNE-PC.md: grosse Dateien, z. B. Videos ueber 100 MB, nur auf Wunsch).

/// Woher ein Video abgespielt wird.
public enum RecordingPlaybackSource: Sendable, Equatable {
    /// geladene Datei (offline)
    case local(URL, quality: String)
    /// direkt vom Videoserver
    case stream(URL, quality: String)
    /// Stud.IP-Player-Seite in der Webansicht (Ersatzweg)
    case webPlayer(URL)
    case unavailable
}

public enum RecordingPlayback {
    public static let preferredQuality = "720p"

    /// Fassung fuer Streaming und Download: gewuenschte, sonst 720p, sonst die beste unter 1080p, sonst die kleinste.
    public static func quality(for video: OpencastVideo, preferred: String? = nil) -> OpencastMedia? {
        let d = video.media
        if let p = preferred, let x = d.first(where: { $0.quality == p }) { return x }
        if let x = d.first(where: { $0.quality == preferredQuality }) { return x }
        if let x = d.filter({ $0.height > 0 && $0.height < 1080 }).max(by: { $0.height < $1.height }) { return x }
        return d.min { ($0.height == 0 ? Int.max : $0.height) < ($1.height == 0 ? Int.max : $1.height) }
    }

    /// Geladene Datei vor Stream, Stream vor Webansicht. Wurde ausdruecklich eine andere als die geladene Fassung
    /// gewaehlt (Qualitaetsmenue), gilt der Stream dieser Fassung.
    public static func source(for video: OpencastVideo, local: (url: URL, quality: String)?, preferred: String? = nil) -> RecordingPlaybackSource {
        if let l = local, preferred == nil || preferred == l.quality { return .local(l.url, quality: l.quality) }
        if let d = quality(for: video, preferred: preferred) { return .stream(d.url, quality: d.quality) }
        if let l = local { return .local(l.url, quality: l.quality) }
        if let p = video.playerURL { return .webPlayer(p) }
        return .unavailable
    }

    /// Fortsetzen an der gemerkten Stelle: nicht in den ersten 10 s und nicht in den letzten 15 s (dann von vorn).
    public static func resumePosition(saved: Double?, duration: Double?) -> Double? {
        guard let s = saved, s.isFinite, s >= 10 else { return nil }
        if let d = duration, d.isFinite, d > 0, s >= d - 15 { return nil }
        return s
    }
}

/// Laden nur auf Wunsch: der Abgleich laedt nie ein Video. Tippt der Nutzer "Laden", startet ein kleines Video sofort;
/// ueber 100 MB oder mit unbekannter Groesse (der Videoserver nennt keine) erst nach ausdruecklicher Bestaetigung mit
/// Groesse, bei wenig Platz mit Warnung; passt die Datei nicht, gar nicht.
public enum RecordingDownloadPolicy {
    /// ab dieser Groesse nur mit ausdruecklicher Bestaetigung (Entscheidung 7)
    public static let confirmAbove: Int64 = 100_000_000
    /// danach sollen mindestens so viele Bytes frei bleiben, sonst Warnung
    public static let keepFree: Int64 = 1_000_000_000

    public enum Decision: Sendable, Equatable {
        /// sofort laden (der Tipp auf "Laden" ist der Wunsch)
        case start
        /// erst nach ausdruecklicher Bestaetigung mit diesem Text
        case confirm(String)
        /// nicht laden, Meldung
        case refuse(String)
    }

    public static func decide(title: String, quality: String, size: Int64?, freeBytes: Int64?) -> Decision {
        if let s = size, let free = freeBytes, s >= free {
            return .refuse("Nicht genug Speicherplatz: Die Aufzeichnung braucht \(RecordingFiles.megabytes(s)), frei sind \(RecordingFiles.megabytes(free)).")
        }
        let private_ = "Nur zum privaten Ansehen auf diesem Gerät."
        var warning = ""
        if let free = freeBytes, free - max(size ?? 0, 0) < keepFree {
            warning = "Wenig Speicherplatz: Danach sind nur noch \(RecordingFiles.megabytes(max(free - max(size ?? 0, 0), 0))) frei. "
        }
        guard let s = size else {
            return .confirm(warning + "Die Größe von „\(title)“ (\(quality)) ist unbekannt – Aufzeichnungen sind oft mehrere hundert MB groß. Trotzdem laden? " + private_)
        }
        if s > confirmAbove {
            return .confirm(warning + "„\(title)“ (\(quality)) ist \(RecordingFiles.megabytes(s)) groß. Wirklich laden? " + private_)
        }
        return warning.isEmpty ? .start : .confirm(warning + "„\(title)“ (\(quality), \(RecordingFiles.megabytes(s))) laden? " + private_)
    }
}

/// Ablage geladener Aufzeichnungen im Stud.IP-Ordner des Containers (neben den Stud.IP-Dateien, ohne Backup).
public enum RecordingFiles {
    /// Ordner unter dem Stud.IP-Ordner
    public static let folder = "Aufzeichnungen"
    /// Zwischenordner fuer Fortsetzungsdaten abgebrochener Downloads
    public static let partialFolder = ".laden"

    /// "<Kurs>/<Video>-<Qualitaet>.mp4", relativ zum Ordner `folder`
    public static func relativePath(courseID: String, videoID: String, quality: String) -> String {
        "\(StudIPImport.safeFileName(courseID))/\(StudIPImport.safeFileName("\(videoID)-\(quality)")).mp4"
    }

    /// Name der Fortsetzungsdaten (und ihrer Begleitdatei) eines Downloads im Zwischenordner
    public static func resumeName(courseID: String, videoID: String, quality: String) -> String {
        StudIPImport.safeFileName("\(courseID)-\(videoID)-\(quality)") + ".resume"
    }

    /// "412 MB", "1,2 GB"
    public static func megabytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            let tenths = Int((Double(bytes) / 100_000_000).rounded())
            return "\(tenths / 10),\(tenths % 10) GB"
        }
        return "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }
}

/// Fortsetzungsdaten eines abgebrochenen Downloads taugen nur fuer dieselbe Adresse und hoechstens 3 Tage: der
/// Videoserver legt Dateien neu an (andere Adresse), und das System raeumt die halbe Datei irgendwann weg. Veraltete
/// Daten werden verworfen und der Download startet frisch, statt bei jedem "Fortsetzen" erneut zu scheitern.
public enum RecordingResume {
    public static let maxAge: TimeInterval = 3 * 24 * 3600

    public static func usable(savedURL: String?, savedAt: Date?, currentURL: URL, now: Date) -> Bool {
        guard let u = savedURL, u == currentURL.absoluteString, let at = savedAt else { return false }
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < maxAge
    }
}
