import SwiftUI
import UniFlowCore

// Aufgeraeumte Uebersicht (Auftrag des Inhabers 13.11.2026: "Startseite zu ueberfuellt"). Element fuer Element geprueft,
// Bilder vorher/nachher in ~/Studora-Builds/startseite; eingeschaltet, was der Inhaber am 13.11.2026 freigegeben hat.
// Nichts geht verloren, alles bleibt ueber einen anderen Weg erreichbar:
// - drei Kennzahl-Kacheln -> eine Zeile unter der Begruessung ("25 min geplant · 3 nachzuholen – neu planen");
//   "Aufgaben erledigt" stand doppelt (Kachel und Karte "Diese Woche") und steht jetzt nur noch in "Diese Woche"
// - "Nächste Termine" entfaellt: Abgaben, Fristen und Klausuren stehen in "Abgaben & Prüfungen" (dieselben Eintraege),
//   Lernpakete in "Diese Woche" und im Lernkalender
// - "Heute in der Mensa" von ganz oben ans Ende (Menue "Mensa" unveraendert); "Diese Woche" in die breite Spalte
// - Knopf "Tagesansicht" oben -> Link in der Karte "Heute für dich geplant" (und Lernkalender in der Leiste)
// Nicht freigegeben und darum unveraendert: die Hinweise oben (Probe und Pro-AI-Anmeldung koennen zugleich stehen).

enum DashboardTidy {
    /// interne Adresse des Links "neu planen" in der Zeile unter der Begruessung
    static let rescueURL = URL(string: "studinow-intern://dashboard/neu-planen")!

    /// "Freitag, 13. November · heute 1 Lernpaket · 25 min geplant, 13 h frei · 3 nachzuholen – neu planen"
    static func summary(date: String, packages: Int, events: Int, minutes: Double?, free: Double?, backlog: Int) -> AttributedString {
        var s = AttributedString(date + " · ")
        s += AttributedString(packages == 0 ? "heute ist nichts geplant" : "heute \(packages) Lernpaket\(packages > 1 ? "e" : "")")
        if packages > 0, let m = minutes, m > 0 {
            s += AttributedString(" · \(UFFmt.min(m)) geplant")
            if let f = free, f > 0 { s += AttributedString(", \(UFFmt.min(f)) frei") }
        }
        if events > 0 { s += AttributedString(" · \(events) Uni-Termin\(events == 1 ? "" : "e")") }
        if backlog > 0 {
            s += AttributedString(" · ")
            var n = AttributedString("\(backlog) nachzuholen")
            n.foregroundColor = UF.bad
            s += n
            s += AttributedString(" – ")
            var link = AttributedString("neu planen")
            link.link = rescueURL
            link.foregroundColor = UF.accentText
            link.font = .uf(14.5, 600)
            s += link
        }
        return s
    }
}
