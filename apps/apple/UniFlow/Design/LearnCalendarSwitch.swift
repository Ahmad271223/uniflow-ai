import Foundation

/// Lernkalender (KI-Lernplanung mit Lernpaketen) ein oder aus.
///
/// Auftrag des Inhabers 17.11.2026: "erstmal komplett Lernkalender rausnehmen, will nur Stundenplan mit den Ansagen da
/// oben haben (Termin, Anmeldung, Kurztest, Klausur) ohne KI-Lernkalender ... und den Punkt 'Heute für dich geplant'
/// und den Punkt 'Diese Woche' auch rausnehmen, das kommt alles nach."
///
/// `false` (Standard): Der Lernkalender ist in der ganzen App nicht zu sehen und nicht erreichbar - kein Menuepunkt,
/// keine Karten auf der Uebersicht, keine Fragen und Einstellungen dazu, kein automatisches Planen. Die Daten und der
/// Code bleiben, damit er spaeter wieder eingeschaltet werden kann ("kommt alles nach").
/// `true`: wie bis Build 44.
enum LearnCalendar {
    static var enabled = false
}

extension LearnCalendar {
    /// Seite, die wirklich gezeigt wird: ohne Lernkalender fuehrt jede Route dorthin (Menue, Links wie `#/plan` und
    /// `#/tasks`, Suchtreffer, wiederhergestellte letzte Seite, Mitteilungen) auf den Stundenplan desselben Tages.
    /// `UFRouter` wendet das bei jedem Seitenwechsel an; mit Schalter an bleibt die Route, wie sie ist.
    static func route(_ r: UFRoute) -> UFRoute {
        guard !enabled, case .plan(_, let date, _) = r else { return r }
        return .timetable(date: date)
    }

    /// Text je nach Schalter: `on` wie bis Build 44, `off` ohne Lernkalender, Lernpakete und Lernplanung
    static func text(_ on: String, off: String) -> String { enabled ? on : off }

    /// Darf die App von selbst planen (nach dem Abgleich, beim Oeffnen, Lernziele)? Ohne Lernkalender nie, sonst nach
    /// Tarif (`UFFeature.autoPlan`). Haengt an `StudyAutoPlan.allowed` und `SmartGoalsEndpoints.autoAllowed`.
    static func autoPlans(tariff: Bool) -> Bool { enabled && tariff }

    /// Nur Debug-Builds: `-UFLearnCalendar YES` schaltet den Lernkalender fuer Bildvergleiche ein (vor dem ersten Bild,
    /// `UniFlowApp.init`); ohne das Argument gilt der ausgelieferte Standard
    static func applyDebugLaunch(defaults d: UserDefaults = .standard) {
        #if DEBUG
        if d.object(forKey: "UFLearnCalendar") != nil { enabled = d.bool(forKey: "UFLearnCalendar") }
        #endif
    }
}
