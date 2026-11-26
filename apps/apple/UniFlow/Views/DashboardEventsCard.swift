import SwiftUI
import UniFlowCore

/// Karte "Heute an der Uni" der Startseite (aus `DashboardView` herausgeloest am 26.11.2026, damit die Bilder des
/// Countdowns sie mit fester Uhrzeit zeichnen koennen; Inhalt und Aussehen unveraendert). iPad/Mac: eine Zeile je
/// Termin mit dem Countdown als kleines Feld vor dem Raum; iPhone (`compact`): Zeitspalte, Farbbalken, Titel, Raum und
/// darunter der Countdown. Unten nach dem letzten Termin "Als Nächstes: morgen 8:15 · …".
struct DashboardEventsCard: View {
    let events: [JSONValue]
    let date: String
    let later: TerminCountdown.Later?
    let compact: Bool
    let openTimetable: () -> Void
    let open: (JSONValue) -> Void

    var body: some View {
        let evs = events
        return UFCard {
            UFCardHead("Heute an der Uni", icon: "clock") {
                Button("Stundenplan") { openTimetable() }.ufFont(13.12).foregroundStyle(UF.accentText).buttonStyle(.plain)
            }
            ForEach(Row.rows(evs, key: "event_id")) { row in
                let e = row.value
                let attending = e.s("status") == "teilnahme"
                Button { open(e) } label: {
                  if compact {
                    compactEventRow(e, attending: attending, events: evs, date: date)
                  } else {
                    HStack(spacing: 9.6) {
                        UFDot(color: Color(hex: e.s("color")))
                        Text("\(e.s("start") ?? "")–\(e.s("end") ?? "")").ufFont(13.12, 700).foregroundStyle(UF.text).frame(minWidth: 92, alignment: .leading)
                        Text(e.s("title") ?? "").ufFont(13.12).strikethrough(!attending)
                            .foregroundStyle(attending ? UF.text : UF.muted).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        if let mark = UFCancel.label(e) { UFCancelMark(text: mark, size: 11.52).help(UFCancel.helpText(e) ?? mark) }
                        TerminCountdownMark(event: e, events: evs, date: date)          // "läuft · noch 35 Min", "in 25 Min"
                        Text(String((e.s("room") ?? "").prefix(22))).ufFont(13.12).foregroundStyle(UF.muted).lineLimit(1)
                    }
                    .padding(.vertical, 4.8)
                    .ufBorderBottom()
                    .contentShape(Rectangle())
                  }
                }
                .buttonStyle(.plain)
            }
            // nach dem letzten Termin des Tages: "Als Nächstes: morgen 8:15 · …" (verschwindet sonst ganz)
            TerminCountdownLater(events: evs, date: date, later: later)
        }
    }

    /// iPhone (Feinschliff 23.11.2026, nach dem Vergleich mit StudGo): links Beginn fett und Ende klein, dann ein
    /// 4-pt-Balken in Modulfarbe, rechts Titel bis zwei Zeilen und darunter der Raum. Vorher stand alles in einer
    /// Zeile, auf 402 pt Breite wurde der Titel nach wenigen Zeichen gekuerzt. Inhalt und Reihenfolge wie bisher.
    /// Countdown (26.11.2026, `TerminCountdownMark`) als eigene Zeile unter dem Raum.
    private func compactEventRow(_ e: JSONValue, attending: Bool, events: [JSONValue], date: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(e.s("start") ?? "").ufFont(14, 700).foregroundStyle(UF.text).monospacedDigit()
                Text(e.s("end") ?? "").ufFont(12).foregroundStyle(UF.muted).monospacedDigit()
            }
            .frame(width: 44, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: e.s("color"))).frame(width: 4)
                .opacity(attending ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(e.s("title") ?? "").ufFont(14, 600).strikethrough(!attending)
                        .foregroundStyle(attending ? UF.text : UF.muted).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let mark = UFCancel.label(e) { UFCancelMark(text: mark, size: 11.52).help(UFCancel.helpText(e) ?? mark) }
                }
                if let room = e.s("room"), !room.isEmpty {
                    Text(room).ufFont(12.5).foregroundStyle(UF.muted).lineLimit(1)
                }
                TerminCountdownMark(event: e, events: events, date: date, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .ufBorderBottom()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
