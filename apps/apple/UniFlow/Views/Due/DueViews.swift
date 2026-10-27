import SwiftUI
import UniFlowCore

// "Abgaben & Prüfungen": erkannte Termine aus Folien, Uebungsblaettern, Dateinamen und Ankuendigungen, dazu
// Learnweb-Fristen und Klausurtermine der Module (GET /api/due, nur lokal). Auf der Uebersicht und im Moduldetail;
// Antippen oeffnet die Quelle (PDF auf der Seite, Ankuendigung, Learnweb), das Menue blendet aus ("stimmt nicht"),
// bestaetigt oder aendert die Uhrzeit (PATCH /api/due/{id}). Die Einstellungen schalten die Erinnerungen.

/// Texte (fuer Tests an einer Stelle)
enum DueTexts {
    static let title = "Abgaben & Prüfungen"
    static let empty = "Keine Abgaben oder Prüfungen erkannt."
    static let emptyHint = "UniFlow sucht in Folien, Übungsblättern und Ankündigungen nach Abgaben, Tests und Klausuren."
    static let hiddenToast = "Ausgeblendet. Unter „ausgeblendete anzeigen“ holst du ihn zurück."
    static let reminderTitle = "Erinnerungen an Abgaben und Prüfungen"
    static let reminderText = "3 Tage vorher, 1 Tag vorher und am Morgen um 8:00 Uhr, bei Terminen mit Uhrzeit zusätzlich 2 Stunden vorher. Dabei sind die in Folien, Übungsblättern und Ankündigungen erkannten Termine, Fristen aus dem Learnweb-Kalender und eingetragene Klausurtermine – ausgeblendete nicht. Alles bleibt auf diesem iPad."
    static let deniedText = "Mitteilungen für UniFlow sind ausgeschaltet. Erlaube sie in den iPad-Einstellungen unter „Mitteilungen“ und schalte die Erinnerungen danach hier erneut ein."

    /// "Sa., 05.12. 23:59 · Kurzklausur · Analysis I"
    static func sub(_ x: JSONValue) -> String {
        var s = UFFmt.short(x.s("date"))
        if let t = x.s("time"), !t.isEmpty { s += " \(t)" }
        if let k = x.s("kind_label"), !k.isEmpty, k != x.s("title") { s += " · \(k)" }
        if let c = x.s("course_title") ?? x.s("module_name"), !c.isEmpty { s += " · \(UFFmt.shortName(c))" }
        return s
    }

    /// Pfad mit Anfrage ("/api/due?module_id=3&hidden=1")
    static func query(_ path: String, _ items: [String]) -> String { path + (items.isEmpty ? "" : "?" + items.joined(separator: "&")) }

    /// Ton des Abstands: heute/morgen rot, diese Woche gelb, sonst neutral
    static func tone(_ days: Int) -> UFTone { days <= 1 ? .bad : days <= 7 ? .warn : .neutral }
}

struct DueListCard: View {
    /// nur dieses Modul (Moduldetail); nil = alle (Uebersicht)
    var moduleID: Int?
    /// so viele Eintraege, bis "Alle anzeigen"
    var limit = 6
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @ObservedObject private var scheduler = DueReminderScheduler.shared
    @Environment(\.openURL) private var openURL
    @State private var items: [JSONValue] = []
    @State private var hiddenCount = 0
    @State private var showHidden = false
    @State private var showAll = false
    @State private var loaded = false

    private var path: String {
        var q: [String] = []
        if let moduleID { q.append("module_id=\(moduleID)") }
        if showHidden { q.append("hidden=1") }
        return DueTexts.query("/api/due", q)
    }

    /// im Modul nur mit Eintraegen; auf der Uebersicht immer (mit ehrlichem Leerzustand)
    private var visible: Bool {
        guard session.api?.isLocal == true, loaded else { return false }
        return moduleID == nil || !items.isEmpty || hiddenCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if visible { card }
        }
        .task(id: path) { await load() }
        .ufReload { await load() }
        .onChange(of: scheduler.revision) { _, _ in Task { await load() } }
    }

    private func load() async {
        guard let api = session.api, api.isLocal else { return }
        guard let v = try? await api.value(path) else { return }
        items = v.list("items")
        hiddenCount = v.i("hidden") ?? 0
        loaded = true
    }

    private var card: some View {
        UFCard {
            UFCardHead(DueTexts.title, icon: "flag") {
                if !items.isEmpty { Text("\(items.filter { $0["hidden"]?.bool != true }.count)").ufFont(13.12).foregroundStyle(UF.muted) }
            }
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(DueTexts.empty).ufFont(13.12).foregroundStyle(UF.muted)
                    Text(DueTexts.emptyHint).ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
            } else {
                let shown = showAll ? items : Array(items.prefix(limit))
                let rows = Row.rows(shown)
                ForEach(rows) { r in
                    row(r.value).ufBorderBottom(r.id != rows.last?.id)
                }
                if items.count > limit {
                    Button(showAll ? "Weniger anzeigen" : "Alle anzeigen (\(items.count))") { showAll.toggle() }
                        .ufFont(12.8, 600).foregroundStyle(UF.accentText).buttonStyle(.plain).padding(.top, 8)
                }
            }
            if hiddenCount > 0 {
                Button(showHidden ? "Ausgeblendete verbergen" : "\(hiddenCount) ausgeblendete anzeigen") { showHidden.toggle() }
                    .ufFont(12.8).foregroundStyle(UF.muted).buttonStyle(.plain).padding(.top, 8)
                    .accessibilityIdentifier("due.hidden.toggle")
            }
        }
        .accessibilityIdentifier(moduleID == nil ? "due.card" : "due.card.module")
    }

    private func row(_ x: JSONValue) -> some View {
        let detected = x["detected"]?.bool == true
        let hidden = x["hidden"]?.bool == true
        let days = x.i("days_left") ?? 0
        return HStack(alignment: .top, spacing: 9.6) {
            UFDot(color: x.s("color").map { Color(hex: $0) } ?? UF.bad).padding(.top, 6)
            Button { DueOpen.open(x, router: router, openURL: openURL) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(x.s("title") ?? "Termin").ufFont(14.5, 550).foregroundStyle(hidden ? UF.muted : UF.text)
                            .strikethrough(hidden).lineLimit(1)
                        if detected, x["confirmed"]?.bool == true {
                            UFIcon("check", size: 12).foregroundStyle(UF.ok).accessibilityLabel("bestätigt")
                        }
                    }
                    Text(DueTexts.sub(x)).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                    if let o = x.s("origin"), !o.isEmpty {
                        HStack(spacing: 4) {
                            UFIcon(detected ? "file-text" : "info", size: 11)
                            Text(o).lineLimit(1)
                        }
                        .ufFont(11.84).foregroundStyle(UF.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(x.s("title") ?? "Termin"), \(DueTexts.sub(x)), \(x.s("in_days") ?? ""). \(x.s("origin") ?? "")")
            UFBadge(x.s("in_days") ?? "", tone: DueTexts.tone(days))
            if detected { menu(x, hidden: hidden) }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("due.row.\(x.s("id") ?? "")")
    }

    private func menu(_ x: JSONValue, hidden: Bool) -> some View {
        Menu {
            Button { DueOpen.open(x, router: router, openURL: openURL) } label: { Label("Quelle öffnen", systemImage: "doc.text") }
            if hidden {
                Button { Task { await patch(x, ["hidden": false]) } } label: { Label("Wieder anzeigen", systemImage: "eye") }
            } else {
                if x["confirmed"]?.bool != true {
                    Button { Task { await patch(x, ["confirmed": true]) } } label: { Label("Bestätigen", systemImage: "checkmark") }
                }
                Button {
                    _ = overlay.modal { DueTimeDialog(item: x) { t in Task { await patch(x, ["time": t.map(JSONValue.string) ?? .null, "confirmed": true]) } } }
                } label: { Label("Uhrzeit ändern …", systemImage: "clock") }
                Button(role: .destructive) {
                    Task {
                        await patch(x, ["hidden": true])
                        toast.show(DueTexts.hiddenToast, seconds: 4)
                    }
                } label: { Label("Stimmt nicht – ausblenden", systemImage: "eye.slash") }
            }
        } label: {
            UFIcon("more", size: 16).foregroundStyle(UF.muted).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .accessibilityLabel("Aktionen")
        .accessibilityIdentifier("due.menu.\(x.s("id") ?? "")")
    }

    private func patch(_ x: JSONValue, _ body: JSONValue) async {
        guard let api = session.api, let id = x.s("id") else { return }
        do {
            _ = try await api.value("/api/due/\(id)", method: "PATCH", body: body)
            await load()
            router.reload()                                                  // Kalender, Stundenplan, Naechste Termine
            DueReminderScheduler.shared.schedule(recompute: false)
        } catch {
            toast.show(error.localizedDescription, seconds: 4)
        }
    }
}

/// Uhrzeit eines erkannten Termins aendern (leer = ohne Uhrzeit, ganztags)
struct DueTimeDialog: View {
    let item: JSONValue
    let save: (String?) -> Void
    @Environment(\.ufClose) private var close
    @State private var time = ""

    var body: some View {
        UFDialog("Uhrzeit ändern", icon: "clock") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text("\(item.s("title") ?? "Termin") · \(UFFmt.short(item.s("date")))").ufFont(13.12, 600).foregroundStyle(UF.text)
                if let o = item.s("origin") { Text(o).ufFont(12.16).foregroundStyle(UF.muted) }
                UFField("Uhrzeit") { UFTimeField(hm: $time, allowEmpty: true) }
                Text("Ohne Uhrzeit erinnert UniFlow am Morgen um 8:00 Uhr.").ufFont(12.16).foregroundStyle(UF.muted)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) {
                save(time.isEmpty ? nil : time)
                close()
            }
        }
        .onAppear { time = item.s("time") ?? "" }
    }
}

/// Einstellungen: Erinnerungen an/aus. Erst das Einschalten fragt iOS nach der Erlaubnis.
struct DueReminderCard: View {
    @ObservedObject private var scheduler = DueReminderScheduler.shared
    @State private var asking = false
    @State private var hint: String?

    var body: some View {
        UFCard {
            UFCardHead(DueTexts.reminderTitle, icon: "bell") {
                UFBadge(scheduler.enabled ? "an" : "aus", tone: scheduler.enabled ? .ok : .neutral)
            }
            Toggle(isOn: Binding(get: { scheduler.enabled }, set: { set($0) })) {
                Text(DueTexts.reminderTitle).ufFont(14.5, 550).foregroundStyle(UF.text)
            }
            .tint(UF.accent)
            .disabled(asking)
            .accessibilityIdentifier("due.reminders")
            Text(DueTexts.reminderText).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            if scheduler.enabled {
                Text(scheduler.scheduled == 1 ? "1 Erinnerung geplant" : "\(scheduler.scheduled) Erinnerungen geplant")
                    .ufFont(13.12, 600).foregroundStyle(UF.text2).padding(.top, 6.4)
                    .accessibilityIdentifier("due.reminders.count")
            }
            if let hint {
                Text(hint).ufFont(12.8, 600).foregroundStyle(UF.warn).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    .accessibilityIdentifier("due.reminders.hint")
            }
        }
    }

    private func set(_ on: Bool) {
        hint = nil
        asking = true
        Task {
            let ok = await scheduler.setEnabled(on)
            asking = false
            if on, !ok { hint = DueTexts.deniedText }
        }
    }
}
