import SwiftUI
import UniFlowCore

/// Karte "Neuigkeiten" auf der Uebersicht (Auftrag des Inhabers 02.11.2026: "alles schlau einbauen, nicht ueberladen").
/// Eine Karte statt vieler: Ankuendigungen (Kurs und Stud.IP-weit, auch Learnweb), Nachrichten (nur auf diesem Geraet)
/// und Aenderungen in Kursen (Activity-Stream), die neuesten fuenf. Je Zeile ein Symbol nach Art, Kurs bzw. Absender,
/// Betreff, Zeit und erkannte Hinweise als Chips ("Frist 12.11.", "Ausfall? 12.11."). Antippen klappt den Text auf, mit
/// Link nach Stud.IP bzw. Learnweb (nur http/https). "Alle anzeigen" oeffnet eine schlichte Liste mit Filter-Chips.
/// Daten: GET /api/news (StudIPExtras.feedFor). Nachrichten gehen von hier nie an die KI oder einen Dienst.
struct NewsCard: View {
    let items: [JSONValue]
    /// Tag fuer "heute"/"gestern" ("YYYY-MM-DD")
    let today: String
    var showAll: () -> Void

    var body: some View {
        UFCard {
            UFCardHead("Neuigkeiten", icon: "bell") {
                Button("Alle anzeigen") { showAll() }
                    .ufFont(13.12).foregroundStyle(UF.accentText).buttonStyle(.plain)
                    .accessibilityIdentifier("news.all")
            }
            let rows = Row.rows(Array(items.prefix(5)))
            ForEach(rows) { row in
                NewsRow(item: row.value, today: today).ufBorderBottom(row.id != rows.last?.id)
            }
        }
    }
}

/// Eine Zeile der Neuigkeiten (Karte und Liste)
struct NewsRow: View {
    let item: JSONValue
    let today: String
    @State private var open = false
    @Environment(\.openURL) private var openURL

    /// Art -> (Symbol, Ton, Bezeichnung fuer Bedienungshilfen)
    static func style(_ kind: String?) -> (icon: String, tone: UFTone, label: String) {
        switch kind {
        case "nachricht": return ("note", .info, "Nachricht")
        case "aenderung": return ("refresh", .ok, "Änderung")
        default: return ("bell", .accent, "Ankündigung")
        }
    }

    /// Chip-Ton: Ausfall rot, Frist und Verlegung gelb, Pruefung Akzent
    static func tone(_ chipKind: String?) -> UFTone {
        switch chipKind {
        case "ausfall": return .bad
        case "frist", "verlegt": return .warn
        default: return .accent
        }
    }

    /// "09:15" heute, "gestern", sonst "Sa., 31.10."
    static func time(_ at: String?, today: String) -> String {
        guard let at, at.count >= 10 else { return "" }
        let day = String(at.prefix(10))
        if day == today { return at.count >= 16 ? String(at.dropFirst(11).prefix(5)) : "heute" }
        if let t = BerlinDay.parse(today), let d = BerlinDay.parse(day), t - d == 1 { return "gestern" }
        return UFFmt.short(day)
    }

    /// Text fuer Bedienungshilfen: "Nachricht: Tutorium entfällt · Lehrende · 08:15 · Ausfall? 12.11."
    static func accessibility(_ item: JSONValue, today: String) -> String {
        var parts = ["\(style(item.s("kind")).label): \(item.s("title") ?? "")", item.s("who") ?? "", time(item.s("at"), today: today)]
        parts += item.list("chips").compactMap { $0.s("label") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        let st = Self.style(item.s("kind"))
        VStack(alignment: .leading, spacing: 6.4) {
            Button { withAnimation(UF.motion(.easeOut(duration: 0.12))) { open.toggle() } } label: {
                HStack(alignment: .top, spacing: 10.4) {
                    UFIcon(st.icon, size: 14)
                        .foregroundStyle(st.tone.fg)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(st.tone.bg))
                    VStack(alignment: .leading, spacing: 2.4) {
                        HStack(spacing: 6.4) {
                            Text(UFFmt.shortName(item.s("who"))).ufFont(12.8, 600).foregroundStyle(UF.text2).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Self.time(item.s("at"), today: today)).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                        }
                        Text(item.s("title") ?? "").ufFont(14.5, 550).foregroundStyle(UF.text).lineLimit(open ? nil : 2)
                            .multilineTextAlignment(.leading)
                        let chips = item.list("chips")
                        if !chips.isEmpty {
                            HStack(spacing: 5.6) {
                                ForEach(Row.rows(chips, key: "label")) { c in
                                    UFBadge(c.value.s("label") ?? "", tone: Self.tone(c.value.s("kind")))
                                }
                            }
                            .padding(.top, 2.4)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibility(item, today: today))
            .accessibilityAddTraits(.isButton)
            if open {
                VStack(alignment: .leading, spacing: 6.4) {
                    if let text = item.s("text"), !text.isEmpty {
                        Text(text).ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let url = UFDayExtras.safeURL(item.s("url")) {
                        Button(item.s("source") == "learnweb" ? "Im Learnweb öffnen" : "In Stud.IP öffnen") { openURL(url) }
                            .ufFont(12.8).foregroundStyle(UF.accentText).buttonStyle(.plain)
                    }
                }
                .padding(.leading, 36.8)
            }
        }
        .padding(.vertical, 7.2)
    }
}

/// Alle Neuigkeiten mit Filter-Chips (Alle · Ankündigungen · Nachrichten · Änderungen)
struct NewsAllList: View {
    let items: [JSONValue]
    let today: String
    let close: () -> Void
    @State var filter = ""

    static let filters: [(key: String, label: String)] = [("", "Alle"), ("ankuendigung", "Ankündigungen"),
                                                          ("nachricht", "Nachrichten"), ("aenderung", "Änderungen")]

    static func filtered(_ items: [JSONValue], _ filter: String) -> [JSONValue] {
        filter.isEmpty ? items : items.filter { $0.s("kind") == filter }
    }

    var body: some View {
        UFDialog("Neuigkeiten", icon: "bell") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6.4) {
                    ForEach(Self.filters, id: \.key) { f in
                        let n = Self.filtered(items, f.key).count
                        UFChip(text: f.key.isEmpty ? f.label : "\(f.label) \(n)", on: filter == f.key) { filter = f.key }
                    }
                }
                .padding(.bottom, 9.6)
                let shown = Self.filtered(items, filter)
                if shown.isEmpty {
                    Text("Nichts Neues.").ufFont(13.12).foregroundStyle(UF.muted).frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    let rows = Row.rows(shown)
                    ForEach(rows) { row in NewsRow(item: row.value, today: today).ufBorderBottom(row.id != rows.last?.id) }
                }
                if filter == "nachricht" || filter.isEmpty, items.contains(where: { $0.s("kind") == "nachricht" }) {
                    Text("Nachrichten bleiben nur auf diesem Gerät; Studora markiert sie in Stud.IP nicht als gelesen.")
                        .ufFont(12).foregroundStyle(UF.muted).padding(.top, 9.6).fixedSize(horizontal: false, vertical: true)
                }
            }
        } foot: {
            UFButton("Schließen") { close() }
        }
    }
}

/// Tagesnummer aus "YYYY-MM-DD" (fuer "gestern"), ohne Kalender und Zeitzone
enum BerlinDay {
    static func parse(_ s: String) -> Int? {
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        // Tage seit 1970 (H. Hinnant, days_from_civil)
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}
