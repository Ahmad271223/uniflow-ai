import Foundation

/// Platzhalter: Lernslots nach Stundenplan-Aenderungen neu legen (Lernlogik, S6). Der uebrige Stundenplan ist echt
/// (TimetableEndpoints, S5).
enum PendingTimetableEndpoints: LocalEndpointModule {
    static let name = "Stundenplan (Platzhalter)"

    static func register(on router: LocalRouter) {
        // Lernslots der Tage neu legen: ohne Pakete gibt es nichts zu verschieben; Antwort wie Python
        router.post("/api/timetable/reslot", placeholder: true) { req, _ in
            let dates = try req.objectBody(orEmpty: true)["dates"]
            return .json(["reslotted": LocalTimetable.or(dates, [])])
        }
    }
}
