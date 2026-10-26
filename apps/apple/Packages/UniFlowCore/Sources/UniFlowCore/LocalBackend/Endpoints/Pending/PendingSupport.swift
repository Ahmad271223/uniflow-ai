import Foundation

// Platzhalter bis zur Portierung (docs/IPAD-OHNE-PC.md, Abschnitt 5): Jeder Pfad, den die App aufruft, bekommt eine
// gueltige Antwort in der Form von app/server.py, wie sie der PC-Server bei leerer Datenbank gibt (leere Listen,
// leere Objekte mit denselben Feldern). Viele Seiten laden mehrere Pfade gemeinsam (async let) – ein einziger Fehler
// liesse die ganze Seite scheitern. Seit S6 sind Lernkalender, Stundenplan und Uebersicht echt; uebrig sind
// Hintergrund, Suche, Skriptsuche, Uni & Noten und Karteikarten (Pending*Endpoints).
//
// Regeln:
// - Lesen: leere Antwort in Server-Form; einzelne Eintraege nach ID gibt es noch nicht -> 404 wie auf dem PC.
// - Aendern/Loeschen vorhandener Eintraege: Antwort wie der PC-Server, wenn es den Eintrag nicht gibt.
// - Ein echter Endpunkt mit demselben Pfad ersetzt den Platzhalter (LocalRoute.placeholder), ohne ihn zu aendern.

enum LocalPending {
    /// `_bg_state` ohne laufende Hintergrundaufgabe (auf dem Geraet gibt es keine)
    static let bg: JSONValue = ["running": false, "task": .null, "message": ""]

    /// Leerer Rumpf von `GET /api/files/{id}/annotations`, wenn es noch keine Notizen gibt
    static let emptyAnnotations: JSONValue = ["data": ["version": 2, "pages": [:], "zoom": 1.2], "updated_at": .null, "version": 0]
}
