import SwiftUI
import UniFlowCore

/// Sprung aus Lernkalender und Stundenplan in ein Modul (Auftrag 12.11.2026: "Zeig bitte immer die richtigen Module an,
/// wenn man auf ein Fach klickt im Planer; es sollen nicht alle VL-Wochen rein angezeigt werden").
///
/// Vorher oeffnete "Zum Modul" (Termin, Einzeltermin) das Moduldetail mit allen Lehrwochen aufgeklappt, ganz oben
/// Woche 1; die Woche des Termins lag irgendwo darunter. Jetzt merkt sich der Sprung Tag (Termin, Lernpaket) bzw. Datei
/// (Aufgabe des Lernpakets); `ModulePage` holt das einmal ab, laedt `/api/modules/{id}?date=…&file=…` (`focus_week`,
/// dieselbe Wochenregel wie die Bloecke) und klappt nur diese Woche auf. Die anderen bleiben antippbar, dazu
/// "Alle Wochen aufklappen". Welches Modul: das des Kurses (`LocalTimetable.eventModuleSQL`).
/// Die Route selbst bleibt `.module(id)` (Adresse, Zurueck, Weitermachen unveraendert).
@MainActor
enum ModuleFocus {
    struct Request: Equatable {
        let module: Int
        /// Tag des Termins bzw. Lernpakets (ISO)
        let date: String?
        /// Datei einer Aufgabe des Lernpakets (geht vor dem Tag)
        var file: String?
        /// fuer den Hinweis: "Termin am Do., 05.11."
        var label: String
    }

    /// noch nicht von `ModulePage` abgeholt
    static var pending: Request?

    /// Modul oeffnen, aufgeklappt nur die Woche zu `date` bzw. `file`. Steht das Modul schon da: neu laden (holt ab)
    static func open(module: Int, date: String?, file: String? = nil, label: String, router: UFRouter) {
        pending = Request(module: module, date: date, file: file, label: label)
        if router.route == .module(module) { router.reload() } else { router.go(.module(module)) }
    }

    /// Einmal abholen, nur fuer dieses Modul
    static func take(for module: Int) -> Request? {
        guard let p = pending, p.module == module else { return nil }
        pending = nil
        return p
    }

    /// Abfrage fuer `/api/modules/{id}` ("" ohne Sprung)
    static func query(_ r: Request?) -> String {
        guard let r else { return "" }
        var items: [String] = []
        if let d = r.date, !d.isEmpty { items.append("date=\(d)") }
        if let f = r.file?.addingPercentEncoding(withAllowedCharacters: .alphanumerics), !f.isEmpty { items.append("file=\(f)") }
        return items.isEmpty ? "" : "?" + items.joined(separator: "&")
    }

    /// Welche Woche aufklappen: `focus` (aus `focus_week`), wenn es den Block gibt; sonst die letzte Lehrwoche davor
    /// mit Unterlagen (Termin der laufenden Woche, Folien noch nicht da), sonst die erste Lehrwoche. Ohne `focus`
    /// (PC-Server ohne das Feld): die aktuelle Lehrwoche wie die Kennzahl "Aktuelle Lehrwoche".
    static func openWeek(_ weeks: [Int], focus: Int?) -> Int? {
        let lecture = weeks.filter { $0 >= 1 }
        guard let f = focus else { return lecture.max() ?? weeks.first }
        if weeks.contains(f) { return f }
        return lecture.filter { $0 <= f }.max() ?? lecture.min() ?? weeks.first
    }

    /// Zugeklappt: alle Bloecke ausser `open`
    static func collapsed(_ weeks: [Int], open: Int?) -> Set<Int> {
        Set(weeks.filter { $0 != open })
    }

    /// Hinweistext ueber den Wochen
    static func hint(_ label: String) -> String { "Aufgeklappt: die Woche zum \(label) – andere Wochen sind zugeklappt." }
    static let expandAll = "Alle Wochen aufklappen"
}

/// Hinweis ueber den Wochenbloecken nach einem Sprung aus dem Lernkalender/Stundenplan (eigene Ansicht, flacher Typ)
struct ModuleFocusBar: View {
    let label: String
    let expandAll: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9.6) {
            UFIcon("calendar", size: 14).foregroundStyle(UF.accentText)
            Text(ModuleFocus.hint(label)).ufFont(13.12).foregroundStyle(UF.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            UFButton(ModuleFocus.expandAll, kind: .ghost, size: .small, action: expandAll)
                .accessibilityIdentifier("module.focus.expandAll")
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.accentSoft.opacity(0.5)))
        .padding(.bottom, 12)
        .accessibilityIdentifier("module.focus")
    }
}
