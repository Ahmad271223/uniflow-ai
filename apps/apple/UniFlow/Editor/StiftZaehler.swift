import Foundation
import UIKit

/// Zaehler fuer das Schreiben mit dem Stift, auf dem Geraet mitgeschrieben (Meldung des Inhabers 17.11.2026: "ab und zu
/// geht ein Strich ganz weg" - im Simulator nicht in jedem Fall nachzustellen). Nur Zahlen, kein Inhalt: keine Striche,
/// keine Dateinamen, keine Zeiten ausser dem Tag. Die Datei bleibt auf dem Geraet (wird nirgends hochgeladen) und laesst
/// sich beim Test am Kabel aus dem Ordner der App lesen:
///
///     Library/Application Support/StiftZaehler.json
///
/// Format: ein JSON-Objekt, je Zaehler eine Zahl, dazu `tag` (Datum des letzten Schreibens, JJJJ-MM-TT) und `format` 1.
/// Auswertung: `abgesetzt` = so oft hat PencilKit "Stift abgesetzt" gemeldet (ein Strich je Absetzen), `gemeldet` = so
/// oft kam danach "Zeichnung geaendert". `fehltNachAbsetzen` muss 0 bleiben: 2 s nach einem Absetzen lagen weniger
/// Striche in der Zeichenflaeche als erwartet, ohne dass radiert, zurueckgenommen oder neu geladen wurde.
/// `ohneMeldung` = Absetzen, zu dem 1 s lang keine Meldung kam (PencilKit hat den Strich verworfen oder spaeter gemeldet).
enum StiftZaehler {
    enum Key: String, CaseIterable {
        /// Stift (Stift, Fineliner, Textmarker) abgesetzt
        case abgesetzt
        /// PencilKit hat mit einem Stift-Werkzeug eine geaenderte Zeichnung gemeldet
        case gemeldet
        /// Absetzen ohne Meldung innerhalb 1 s
        case ohneMeldung
        /// letzter Strich ersetzt (erkannte Form, Glaettung "Leicht"/"Aus")
        case ersetzt
        /// Strich blieb, wie PencilKit ihn gezeichnet hat (weiterer Strich unterwegs oder Messpunkte passten nicht)
        case nichtNachbearbeitet
        /// Zeichnung einer geladenen Seite aus dem Speicher neu gesetzt (fremde Aenderung, Zusammenfuehrung)
        case neuGeladen
        /// (Neu-)Laden hat auf die Meldung eines abgesetzten Strichs gewartet
        case neuLadenVerschoben
        /// 2 s nach dem Absetzen weniger Striche als erwartet (ohne Radieren, Rueckgaengig, Neuladen): Verlust
        case fehltNachAbsetzen
    }

    /// Zustand hinter einem Schloss (gezaehlt wird vom Hauptthread, geschrieben daneben)
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Int] = [:]
        var loaded = false
        var writePending = false
        var observer: NSObjectProtocol?
    }

    private static let state = State()

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("StiftZaehler.json")
    }

    static func bump(_ key: Key, by n: Int = 1) {
        state.lock.lock()
        loadIfNeeded()
        state.counts[key.rawValue, default: 0] += n
        let schedule = !state.writePending
        state.writePending = true
        state.lock.unlock()
        // hoechstens alle 5 s auf die Platte (unter 300 Byte), nie im Takt der Striche
        if schedule { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { write() } }
    }

    /// Stand eines Zaehlers (Tests)
    static func value(_ key: Key) -> Int {
        state.lock.lock(); defer { state.lock.unlock() }
        loadIfNeeded()
        return state.counts[key.rawValue] ?? 0
    }

    /// Sofort schreiben (Wechsel in den Hintergrund, Tests)
    static func write() {
        state.lock.lock()
        loadIfNeeded()
        state.writePending = false
        var out: [String: Any] = ["format": 1]
        for k in Key.allCases { out[k.rawValue] = state.counts[k.rawValue] ?? 0 }
        state.lock.unlock()
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        out["tag"] = day.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Bisherige Zahlen weiterzaehlen (die Datei uebersteht Neustarts) und beim Wechsel in den Hintergrund schreiben
    private static func loadIfNeeded() {
        guard !state.loaded else { return }
        state.loaded = true
        if let data = try? Data(contentsOf: fileURL), let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for k in Key.allCases { if let n = old[k.rawValue] as? Int { state.counts[k.rawValue] = n } }
        }
        DispatchQueue.main.async {
            guard state.observer == nil else { return }
            state.observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                write()
            }
        }
    }
}
