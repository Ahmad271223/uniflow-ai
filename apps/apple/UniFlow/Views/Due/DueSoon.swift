import SwiftUI
import UIKit
import UniFlowCore

// Oben auf der Uebersicht (17.11.2026, Meldung des Inhabers: "Eine Klausur stand nur in einer Folie, keine Erinnerung"):
// Klausuren und Tests von HEUTE und MORGEN, dazu jeder neu erkannte Klausur- oder Testtermin, bis der Nutzer ihn
// gesehen hat. Je Zeile die Herkunft ("erkannt in VL05.pdf, S. 12 – bitte prüfen"), ein Vorbehalt der Erkennung
// (Wochentag passt nicht, nur die Woche genannt), "Zur Fundstelle" (oeffnet das Dokument auf der Seite), "Stimmt" und
// "Stimmt nicht". Daten: GET /api/due (nur lokal), dieselben Termine wie "Abgaben & Prüfungen" und der Stundenplan.
// Kommt fuer diese Termine keine Erinnerung (Schalter aus, Tarif, Mitteilungen in iOS aus), sagt die Karte das einmal;
// den System-Dialog zeigt sie nie.

enum DueSoon {
    /// Arten, die oben stehen
    static let kinds: Set<String> = ["klausur", "test"]

    /// Zeilen der Karte: Klausuren und Tests von heute und morgen (alle Quellen), dazu neu erkannte; ausgeblendete nicht
    static func rows(_ items: [JSONValue]) -> [JSONValue] {
        items.filter { x in
            guard kinds.contains(x.s("kind") ?? ""), x["hidden"]?.bool != true else { return false }
            return (x.i("days_left") ?? 99) <= 1 || x["is_new"]?.bool == true
        }
    }

    static func isSoon(_ x: JSONValue) -> Bool { (x.i("days_left") ?? 99) <= 1 }

    /// "Heute" / "Morgen" rot, sonst "in 6 Tagen"
    static func badge(_ x: JSONValue) -> (text: String, tone: UFTone) {
        let d = x.i("days_left") ?? 99
        if d <= 0 { return ("Heute", .bad) }
        if d == 1 { return ("Morgen", .bad) }
        return (x.s("in_days") ?? "", d <= 7 ? .warn : .neutral)
    }

    /// Herkunft, ehrlich: Erkanntes ist nicht sicher, bis der Nutzer es bestaetigt
    static func origin(_ x: JSONValue) -> String {
        let o = x.s("origin") ?? ""
        guard x["detected"]?.bool == true else { return o }
        return x["confirmed"]?.bool == true ? "\(o) – von dir bestätigt" : "\(o) – bitte prüfen"
    }

    /// Ueberschrift nach Inhalt
    static func title(_ rows: [JSONValue]) -> String {
        let soon = rows.contains(where: isSoon), new = rows.contains { !isSoon($0) }
        if soon && new { return "Klausuren und Tests: bald und neu erkannt" }
        return soon ? "Klausur oder Test: heute und morgen" : "Neu erkannt: Klausur oder Test"
    }

    static let hintKey = "uniflow.due.reminderHint.dismissed"

    /// Einmaliger, freundlicher Hinweis, wenn fuer die Termine keine Erinnerung kommt; nil: Erinnerungen laufen
    static func hint(_ state: DueReminderState) -> String? {
        switch state {
        case .on: return nil
        case .off:
            return "An diese Termine erinnert dich StudiNow nicht: Die Erinnerungen an Abgaben und Prüfungen sind ausgeschaltet. Du kannst sie in den Einstellungen unter „Uni-Zugang & Abgleich“ einschalten."
        case .denied:
            return UFDevice.adapt("An diese Termine kann StudiNow dich nicht erinnern: Mitteilungen für StudiNow sind in den iPad-Einstellungen ausgeschaltet.")
        case .locked:
            return "An diese Termine erinnert dich StudiNow nicht: Erinnerungen an Abgaben und Prüfungen gehören zu StudiNow Plus. Die Termine stehen hier und im Stundenplan."
        }
    }

    /// Text fuer Bedienungshilfen: "Klausur, Heute, Di., 17.11. 10:00 · Statistik I, erkannt in VL05.pdf, S. 12 – bitte prüfen"
    static func accessibility(_ x: JSONValue) -> String {
        [x.s("title") ?? "Termin", x["is_new"]?.bool == true ? "neu erkannt" : nil, badge(x).text, DueTexts.sub(x), origin(x), x.s("note")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Karte oben auf der Uebersicht; ohne Zeilen nichts (auch kein Platz)
struct DueSoonCard: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @ObservedObject private var scheduler = DueReminderScheduler.shared
    @Environment(\.openURL) private var openURL
    @AppStorage(DueSoon.hintKey) private var hintDismissed = false
    @State private var rows: [JSONValue] = []
    @State private var state: DueReminderState = .on

    var body: some View {
        // immer eine echte Ansicht (an einer leeren startet `.task` nie)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            if !rows.isEmpty {
                DueSoonList(rows: rows, hint: hintDismissed ? nil : DueSoon.hint(state), state: state,
                            open: { DueOpen.open($0, router: router, openURL: openURL) },
                            confirm: { x in Task { await patch(x, ["confirmed": true]) } },
                            reject: { x in
                                Task {
                                    await patch(x, ["hidden": true])
                                    toast.show(DueTexts.hiddenToast, seconds: 4)
                                }
                            },
                            seen: { Task { await markSeen() } },
                            dismissHint: { hintDismissed = true },
                            hintAction: { hintAction() })
                    .padding(.bottom, 19.2)
            }
        }
        .task { await load() }
        .ufReload { await load() }
        .onChange(of: scheduler.revision) { _, _ in Task { await load() } }
        .onChange(of: scheduler.enabled) { _, _ in Task { await load() } }
    }

    private func load() async {
        guard let api = session.api, api.isLocal, let v = try? await api.value("/api/due") else { return }
        rows = DueSoon.rows(v.list("items"))
        if !rows.isEmpty { state = await scheduler.reminderState() }
    }

    private func patch(_ x: JSONValue, _ body: JSONValue) async {
        guard let api = session.api, let id = x.s("id") else { return }
        do {
            _ = try await api.value("/api/due/\(id)", method: "PATCH", body: body)
            await load()
            router.reload()                                                  // Abgaben & Prüfungen, Stundenplan
            scheduler.schedule(recompute: false)
        } catch {
            toast.show(error.localizedDescription, seconds: 4)
        }
    }

    /// "Gesehen": die neu erkannten gelten als bekannt (die von heute und morgen bleiben stehen)
    private func markSeen() async {
        guard let api = session.api else { return }
        let ids = rows.filter { $0["is_new"]?.bool == true }.compactMap { $0.s("id") }.map(JSONValue.string)
        _ = try? await api.value("/api/due/seen", method: "POST", body: ["ids": .array(ids), "seen": true])
        await load()
    }

    /// Schalter aus: zu den Einstellungen der App; in iOS aus: zu den Einstellungen des Geraets. Nie der System-Dialog.
    private func hintAction() {
        switch state {
        case .off: router.go(.settings(tab: "uni"))
        case .denied: if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        case .locked: router.go(.settings(tab: "account"))
        case .on: break
        }
    }
}

/// Inhalt der Karte ohne Laden (Tests, Vorschau)
struct DueSoonList: View {
    let rows: [JSONValue]
    var hint: String?
    var state: DueReminderState = .on
    let open: (JSONValue) -> Void
    let confirm: (JSONValue) -> Void
    let reject: (JSONValue) -> Void
    var seen: () -> Void = {}
    var dismissHint: () -> Void = {}
    var hintAction: () -> Void = {}

    var body: some View {
        UFCard {
            UFCardHead(DueSoon.title(rows), icon: UFExam.icon) {
                if rows.contains(where: { $0["is_new"]?.bool == true && !DueSoon.isSoon($0) }) {
                    Button("Gesehen") { seen() }
                        .ufFont(13.12).foregroundStyle(UF.accentText).buttonStyle(.plain)
                        .accessibilityHint("Neu erkannte Termine als gesehen merken")
                        .accessibilityIdentifier("duesoon.seen")
                }
            }
            let list = Row.rows(rows, key: "id")
            ForEach(list) { r in
                row(r.value).ufBorderBottom(r.id != list.last?.id || hint != nil)
            }
            if let hint { hintRow(hint) }
        }
        .accessibilityIdentifier("duesoon.card")
    }

    private func row(_ x: JSONValue) -> some View {
        let detected = x["detected"]?.bool == true
        let badge = DueSoon.badge(x)
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UFIcon(UFExam.icon, size: 15).foregroundStyle(UFExam.color)
                    Text(x.s("title") ?? "Termin").ufFont(15.5, 650).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if x["is_new"]?.bool == true { UFBadge("neu erkannt", tone: .accent).fixedSize() }
                    UFBadge(badge.text, tone: badge.tone).fixedSize()
                }
                Text(DueTexts.sub(x)).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    UFIcon(detected ? "file-text" : "info", size: 11)
                    Text(DueSoon.origin(x)).fixedSize(horizontal: false, vertical: true)
                }
                .ufFont(12.8).foregroundStyle(UF.muted)
                if let note = x.s("note"), !note.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        UFIcon("alert", size: 11)
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    }
                    .ufFont(12.8, 600).foregroundStyle(UF.warnText)
                    .accessibilityIdentifier("duesoon.note")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DueSoon.accessibility(x))
            UFFlexWrap(gap: 8, rowGap: 6) {
                if DueOpen.route(x) != nil {
                    UFButton(x.s("file_id") != nil ? "Zur Fundstelle" : "Quelle öffnen", icon: "arrow-right", size: .small) { open(x) }
                        .accessibilityIdentifier("duesoon.open")
                }
                if detected, x["confirmed"]?.bool != true {
                    UFButton("Stimmt", icon: "check", size: .small) { confirm(x) }
                        .accessibilityIdentifier("duesoon.confirm")
                    UFButton("Stimmt nicht", kind: .ghost, size: .small) { reject(x) }
                        .accessibilityIdentifier("duesoon.reject")
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityIdentifier("duesoon.row.\(x.s("id") ?? "")")
    }

    private func hintRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                UFIcon("bell", size: 12)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .ufFont(12.8).foregroundStyle(UF.text2)
            UFFlexWrap(gap: 8, rowGap: 6) {
                if state == .off { UFButton("Zu den Einstellungen", size: .small) { hintAction() } }
                if state == .denied { UFButton(UFDevice.adapt("iPad-Einstellungen öffnen"), size: .small) { hintAction() } }
                if state == .locked { UFButton("Tarife ansehen", size: .small) { hintAction() } }
                UFButton("Verstanden", kind: .ghost, size: .small) { dismissHint() }
                    .accessibilityIdentifier("duesoon.hint.dismiss")
            }
        }
        .padding(.top, 9)
        .accessibilityIdentifier("duesoon.hint")
    }
}
