import Foundation

/// Injizierbare Uhr fuer die lokale Logik (Lernplan, Stundenplan, Zeitstempel in der Datenbank).
///
/// Der PC-Server rechnet mit `datetime.now()`/`date.today()` in seiner Ortszeit, also Europe/Berlin. Die Uhr liefert
/// dieselben Werte unabhaengig von der Zeitzone des Geraets, mit den Sommerzeit-Regeln aus `BerlinClock`
/// (StudIPSchedule). Tests frieren sie ein, ebenso kuenftig die Logik-Fixtures aus Python (IPAD-OHNE-PC.md, 4.3).
public struct UniFlowClock: Sendable {
    private let source: @Sendable () -> Date

    public init(_ source: @escaping @Sendable () -> Date) {
        self.source = source
    }

    /// Systemzeit
    public static let system = UniFlowClock { Date() }

    /// Immer derselbe Zeitpunkt
    public static func fixed(_ date: Date) -> UniFlowClock {
        UniFlowClock { date }
    }

    /// Eingefroren auf eine Ortszeit in Berlin: "YYYY-MM-DD", "YYYY-MM-DDTHH:MM" oder "YYYY-MM-DDTHH:MM:SS"
    /// (auch mit Leerzeichen statt "T"). In der doppelten Stunde im Oktober gilt die erste (Sommerzeit).
    public static func fixed(berlin local: String) -> UniFlowClock? {
        guard let s = BerlinClock.utcSeconds(localISO: local) else { return nil }
        return fixed(Date(timeIntervalSince1970: TimeInterval(s)))
    }

    public var now: Date { source() }

    /// Ganze UTC-Sekunden (abgerundet)
    var utcSeconds: Int { Int(now.timeIntervalSince1970.rounded(.down)) }

    /// Wie `app.db.now_iso()`: Ortszeit ohne Zone und ohne Sekundenbruchteile, "2026-10-25T14:30:05".
    public var nowISO: String { BerlinClock.localISO(utc: utcSeconds) }

    /// Wie `date.today().isoformat()`: "2026-10-25"
    public var today: String { BerlinClock.isoDate(BerlinClock.local(utc: utcSeconds).day) }

    /// Wochentag von heute, 0 = Montag (wie Pythons `weekday()`)
    public var weekday: Int { BerlinClock.weekday(BerlinClock.local(utc: utcSeconds).day) }

    /// Montag der laufenden Woche ("YYYY-MM-DD", wie `plans.week_start`)
    public var weekStart: String {
        let day = BerlinClock.local(utc: utcSeconds).day
        return BerlinClock.isoDate(day - BerlinClock.weekday(day))
    }

    /// Minuten seit Mitternacht (Ortszeit)
    public var minutesOfDay: Int { BerlinClock.local(utc: utcSeconds).minutes }
}

// Bruecke zu den Kalenderfunktionen aus StudIPSchedule (dort bleibt alles unveraendert)
extension BerlinClock {
    /// Zahl mit fuehrenden Nullen auf `w` Stellen (Datum, Uhrzeit)
    static func pad(_ v: Int, _ w: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, w - s.count)) + s
    }

    /// UTC-Sekunden -> Ortszeit "YYYY-MM-DDTHH:MM:SS"
    static func localISO(utc s: Int) -> String {
        let t = s + offset(utc: s)
        let day = floorDiv(t, 86400)
        let sec = t - day * 86400
        return isoDate(day) + "T" + pad(sec / 3600, 2) + ":" + pad(sec / 60 % 60, 2) + ":" + pad(sec % 60, 2)
    }

    /// Ortszeit "YYYY-MM-DD[THH:MM[:SS]]" -> UTC-Sekunden (Regeln wie `utcSeconds(day:minutes:)`).
    static func utcSeconds(localISO text: String) -> Int? {
        let parts = text.split(omittingEmptySubsequences: false) { $0 == "T" || $0 == " " }
        guard (1...2).contains(parts.count), let day = parseISODate(String(parts[0])) else { return nil }
        var minutes = 0, seconds = 0
        if parts.count == 2 {
            let hms = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(hms.count), hms.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }),
                  let h = Int(hms[0]), let m = Int(hms[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
            if hms.count == 3 {
                guard let s = Int(hms[2]), (0...59).contains(s) else { return nil }
                seconds = s
            }
            minutes = h * 60 + m
        }
        return utcSeconds(day: day, minutes: minutes) + seconds
    }
}
