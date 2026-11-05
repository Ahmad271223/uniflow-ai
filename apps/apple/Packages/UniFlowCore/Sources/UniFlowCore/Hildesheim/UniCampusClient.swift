import Foundation

/// Campus-System neben dem Moodle einer Hochschule ohne Stud.IP: persoenlicher Stundenplan und Leistungen fuer
/// `HildesheimSync` (Uni Hildesheim: `LSFClient`, Hochschule Hannover: `HISinOneClient`, docs/HSH-2026-11-05.md).
/// Nur lesend.
public protocol UniCampusClient: Actor {
    /// Serien des persoenlichen Stundenplans; nil, wenn der Plan leer ist (kein Export)
    func planEntries() async throws -> [LSFCalendar.Entry]?
    /// Leistungen wie `qis.parse_grade_rows`
    func grades() async throws -> [QISGrade]
}

extension LSFClient: UniCampusClient {}
