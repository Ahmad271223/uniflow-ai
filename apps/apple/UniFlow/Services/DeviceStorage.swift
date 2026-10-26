import Foundation
import UniFlowCore

/// Freier Speicher auf dem iPad und Fehler "Speicher voll" fuer die Abgleiche (Stud.IP-Dateien, Aufzeichnungen).
/// Vorher prueften nur die Aufzeichnungen den Platz; ein voller Speicher galt beim Stud.IP-Abgleich als Fehler einer
/// Datei, wurde dreimal wiederholt und endete in "n nicht geladen (Fehler)" bzw. "…SQLiteError-Fehler 1".
enum DeviceStorage {
    /// Mindestens so viel bleibt frei (Datenbank, Notizen, System)
    static let reserve: Int64 = 200 * 1024 * 1024

    static let fullMessage = "Der Speicher dieses iPads ist voll. Gib Platz frei und gleiche danach erneut ab."

    /// Speicher voll: Abgleich anhalten (nicht wiederholen, nicht als Fehler einer Datei zaehlen)
    struct Full: LocalizedError, Equatable {
        var errorDescription: String? { DeviceStorage.fullMessage }
    }

    /// Freier Platz fuer wichtige Daten auf dem Datentraeger von `url` (fehlt der Ordner noch: sein naechster vorhandener)
    static func availableBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Passt eine Datei dieser Groesse noch, mit `reserve` Rest? Unbekannter Platz (`free` nil) zaehlt als passend.
    static func fits(_ bytes: Int64, free: Int64?) -> Bool {
        guard let free else { return true }
        return free - max(0, bytes) >= reserve
    }

    /// Fehler, die einen vollen Speicher melden (Schreiben einer Datei, Datenbank SQLITE_FULL)
    static func isFull(_ error: Error) -> Bool {
        if error is Full { return true }
        if let e = error as? URLError, [.cannotWriteToFile, .cannotCreateFile].contains(e.code) { return true }
        if let e = error as? CocoaError, e.code == .fileWriteOutOfSpace { return true }
        if let e = error as? SQLiteError, e.code == 13 { return true }                      // SQLITE_FULL
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isFull(underlying) }
        return false
    }
}
