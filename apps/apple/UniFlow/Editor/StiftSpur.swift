import Foundation
import QuartzCore
import UIKit

/// Ablauf-Protokoll des Editors fuer die Fehlersuche am Geraet (Meldungen des Inhabers 21.11.2026: "der Zurueck-Pfeil
/// geht nach Lasso-Aenderungen nur einmal", "mit dem Lasso Verschobenes geht ab und zu von selber zurueck" - im
/// Simulator nicht nachzustellen, auch nicht mit echter Beruehrung).
///
/// AUS, solange im Ordner der App keine Datei `Library/Application Support/StiftSpur.an` liegt. Diese Datei legt nur
/// jemand mit dem Geraet am Kabel an (`xcrun devicectl device copy to ...`); in der App gibt es dafuer keinen Schalter.
/// Ist sie da, schreibt der Editor die letzten Ereignisse nach `StiftSpur.txt` daneben: Uhrzeit, Art des Ereignisses,
/// Zahlen (Striche, Schritte), Name des Werkzeugs und der Ansicht mit dem Fokus. Kein Inhalt: keine Striche, keine
/// Dateinamen, keine Seitenschluessel. Die Datei bleibt auf dem Geraet und wird nirgends hochgeladen.
enum StiftSpur {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var checked = false
        var on = false
        var lines: [String] = []
        var writePending = false
        var observer: NSObjectProtocol?
    }

    private static let state = State()
    /// hoechstens so viele Zeilen (die aeltesten fallen weg)
    static let limit = 800

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }
    static var switchURL: URL { directory.appendingPathComponent("StiftSpur.an") }
    static var fileURL: URL { directory.appendingPathComponent("StiftSpur.txt") }

    /// Eingeschaltet? Einmal je App-Start geprueft.
    static var isOn: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        if !state.checked {
            state.checked = true
            state.on = FileManager.default.fileExists(atPath: switchURL.path)
        }
        return state.on
    }

    /// Nur Tests: ein- oder ausschalten, ohne Datei
    static func setOnForTesting(_ on: Bool) {
        state.lock.lock()
        state.checked = true
        state.on = on
        state.lines = []
        state.lock.unlock()
    }

    /// letzte Zeile (Haenger-Waechter: was lief, bevor der Hauptthread stehen blieb)
    static var lastLine: String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.lines.last
    }

    /// Zeilen im Speicher (Tests)
    static var linesForTesting: [String] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.lines
    }

    /// Ereignis merken; der Text wird nur gebaut, wenn das Protokoll an ist
    static func log(_ text: @autoclosure () -> String) {
        guard isOn else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        let line = f.string(from: Date()) + " " + text()
        state.lock.lock()
        state.lines.append(line)
        if state.lines.count > limit { state.lines.removeFirst(state.lines.count - limit) }
        let schedule = !state.writePending
        state.writePending = true
        let needsObserver = state.observer == nil
        state.lock.unlock()
        if schedule { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { write() } }
        if needsObserver {
            DispatchQueue.main.async {
                state.lock.lock()
                let missing = state.observer == nil
                state.lock.unlock()
                guard missing else { return }
                let o = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in write() }
                state.lock.lock()
                state.observer = o
                state.lock.unlock()
            }
        }
    }

    /// Name der Ansicht mit dem Fokus (nur der Typ)
    @MainActor
    static var focus: String {
        UIResponder.uf_current.map { String(describing: type(of: $0)) } ?? "-"
    }

    static func write() {
        state.lock.lock()
        state.writePending = false
        let text = state.lines.joined(separator: "\n") + "\n"
        state.lock.unlock()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
