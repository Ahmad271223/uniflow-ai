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
