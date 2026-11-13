import SwiftUI
import UniFlowCore

/// Jetzt-Linie im Zeitraster (Lernkalender Woche/3 Tage/Tag, Stundenplan; Auftrag 12.11.2026): Strich 2 pt mit Punkt
/// in der Akzentfarbe, nur in der Spalte von heute und nur im sichtbaren Zeitbereich `lo`…`hi` (Minuten ab 0:00).
/// Laeuft im Minutentakt mit (`TimelineView(.everyMinute)`), auch ueber Mitternacht: dann wechselt sie den Tag.
/// VoiceOver liest "Jetzt, 10:30". Ein Baustein fuer alle Raster statt je einer Kopie.
struct UFNowLine: View {
    /// Tag der Spalte (ISO, "2026-11-12")
    let date: String
    /// sichtbarer Zeitbereich in Minuten
    let lo: Int
    let hi: Int
    /// Breite des Strichs (Spaltenbreite)
    let width: CGFloat
    /// y-Position einer Minute im Raster
    let y: (Int) -> CGFloat
    /// Abstand von links (Tagesansicht: hinter der Zeitachse)
    var x: CGFloat = 0

    #if DEBUG
    /// Nur Tests und Bildschirmfotos: feste Uhrzeit statt jetzt (nil = jetzt)
    static var nowOverride: Date?
    #endif

    /// Jetzt (in Tests die feste Uhrzeit)
    static func now(_ date: Date = Date()) -> Date {
        #if DEBUG
        if let nowOverride { return nowOverride }
        #endif
        return date
    }

    /// Heute (ISO, Berlin); Debug mit festem Tag (`UFFmt.todayOverride`, Store-Bildschirmfotos) und ohne feste Uhrzeit:
    /// dieser Tag, wie die Hervorhebung der Spalte
    static func today(_ now: Date) -> String {
        #if DEBUG
        if nowOverride == nil, let day = UFFmt.todayOverride { return day }
        #endif
        return Fmt.isoDay(now)
    }

    /// Minuten seit 0:00 in Berlin (wie die Uhrzeiten der Termine)
    static func minutes(_ date: Date) -> Int {
        let c = PlanData.cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Strich sichtbar? Nur am heutigen Tag und innerhalb des Zeitbereichs
    static func visible(date: String, now: Date, lo: Int, hi: Int) -> Bool {
        guard date == today(now) else { return false }
        let m = minutes(now)
        return m >= lo && m <= hi
    }

    /// VoiceOver: "Jetzt, 10:30"
    static func label(_ now: Date) -> String { "Jetzt, \(UFTime.mh(minutes(now)))" }

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let now = Self.now(ctx.date)
            if Self.visible(date: date, now: now, lo: lo, hi: hi) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(UF.accent).frame(height: 2)
                    Circle().fill(UF.accent).frame(width: 8, height: 8).offset(x: -4)
                }
                .frame(width: max(0, width), height: 8)
                .accessibilityElement()
                .accessibilityLabel(Self.label(now))
                .accessibilityIdentifier("now-line")
                .offset(x: x, y: y(Self.minutes(now)) - 4)
            }
        }
        .allowsHitTesting(false)
    }
}
