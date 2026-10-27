import SwiftUI
import PDFKit
import UniFlowCore

// Einstellungen 1:1 nach viewSettings() und diagTab() in app/static/views-misc.js.
// Bewusst anders (WEB-IPAD-PARITAET.md, W.B.11.3): kein Passwortfeld fuer Stud.IP; statt "Auf dem iPad benutzen"
// (verbindet ein iPad mit dem PC) zeigt die Karte die Verbindung dieses iPads, Stud.IP direkt und den Tarif.
// V1 (docs/AUFTRAG-APPSTORE-V1.md 2a): Die Seite funktioniert auch ohne Server. Oben stehen "Konto" (Mit Apple
// angemeldet, Konto loeschen) und "Tarif"; die Verbindung zum eigenen PC-Server liegt unter "Entwicklung" (nur in
// Debug-Builds). Lokal kommen Lernzeit und Semester vom lokalen Backend (/api/settings, /api/terms), ebenso der
// Reiter "Module" (Anlegen, Zuordnen, automatische Zuordnung; /api/modules, /api/courses) ohne die Wochentests (KI).
// Ist ein gespeicherter Server nicht erreichbar (PC aus, PIN gewechselt), zeigt die Seite dieselben Bereiche wie
// ohne Server mit einem Hinweis oben, damit "Verbindung trennen" und "Konto loeschen" erreichbar bleiben.

struct SettingsPage: View {
    let initialTab: String?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @Environment(\.ufWindowWidth) private var windowWidth
    @State private var data: Loaded?
    @State private var error: String?
    @State private var tab = "modules"
    /// lokal: Einstellungen und Semester aus dem lokalen Backend
    @State private var local: LocalLoaded?

    struct LocalLoaded {
        var s: JSONValue
        var term: JSONValue
        /// Reiter "Module": Kurse und Module aus der lokalen Datenbank
        var courses: [JSONValue] = []
        var mods: [JSONValue] = []
    }

    /// Antworten von /settings, /courses, /modules, /sync/status, /credentials, /terms
    struct Loaded {
        var s: JSONValue
        var courses: [JSONValue]
        var mods: [JSONValue]
        var log: [JSONValue]
        var cred: JSONValue
        var term: JSONValue
    }

    var body: some View {
        Group {
            if !session.isOwnServer { localContent(error: nil) } else if let data { content(data) } else if let error {
                localContent(error: error)
            } else {
                UFContent(maxWidth: 1180) { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .task { tab = initialTab == "diag" ? "advanced" : (initialTab ?? (session.isOwnServer ? "modules" : "account")) }
        .task(id: session.api?.base) { await load() }                      // nach Verbinden/Trennen unter "Entwicklung"
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api else { data = nil; error = nil; local = nil; return }
        guard session.isOwnServer else {
            data = nil; error = nil
            async let s = try? api.value("/api/settings")
            async let t = try? api.value("/api/terms")
            let (sv, tv) = await (s, t)
            // Module zuerst: GET /api/modules ordnet neue Kurse ihrem Fach zu (ensure_modules), die Kursliste danach
            // zeigt diese Zuordnung schon
            let mv = try? await api.value("/api/modules")
            let cv = try? await api.value("/api/courses")
            local = sv.map { LocalLoaded(s: $0, term: tv ?? .null, courses: cv?.items ?? [], mods: mv?.items ?? []) }
            return
        }
        local = nil
        do {
            async let s = api.value("/api/settings")
            async let c = api.value("/api/courses")
            async let m = api.value("/api/modules")
            async let l = api.value("/api/sync/status")
            async let cr = api.value("/api/credentials")
            async let t = api.value("/api/terms")
            let (sv, cv, mv, lv, crv, tv) = try await (s, c, m, l, cr, t)
            data = Loaded(s: sv, courses: cv.items, mods: mv.items, log: lv.list("log"), cred: crv, term: tv)
            error = nil
        } catch { if data == nil { self.error = error.localizedDescription } }
    }

    @ViewBuilder private func content(_ d: Loaded) -> some View {
        UFContent(maxWidth: 1180) {
            UFPageHead("Einstellungen")
            layout(SettingsNav(tab: $tab, horizontal: windowWidth <= 820), SettingsBody(tab: tab, d: d, reload: { await load() }))
        }
    }

    /// ohne Server (V1-Normalfall): Konto, Tarif, Stud.IP direkt, Darstellung auf dem Geraet und "Entwicklung".
    /// Mit `error` ist ein gespeicherter Server nicht erreichbar: Hinweis oben, Navigation bleibt nutzbar.
    @ViewBuilder private func localContent(error: String?) -> some View {
        let keys = SettingsNav.localKeys(withPlan: local != nil)
        let current = keys.contains(tab) ? tab : "account"
        UFContent(maxWidth: 1180) {
            UFPageHead("Einstellungen")
            if let error { unreachableBanner(error) }
            layout(SettingsNav(tab: Binding(get: { current }, set: { tab = $0 }), horizontal: windowWidth <= 820, keys: keys),
                   Group {
                       switch current {
                       case "dev": DevelopmentTab(error: error)
                       case "advanced": LocalAdvancedTab()
                       case "plan": if let local { PlanTab(s: local.s) }
                       case "modules":
                           if let local {
                               ModulesTab(d: Loaded(s: local.s, courses: local.courses, mods: local.mods, log: [], cred: .null, term: local.term),
                                          reload: { await load() }, withTests: false)
                           }
                       default: LocalAccountTab(term: local?.term, reload: { await load() })
                       }
                   })
        }
    }

    /// Hinweis "Server nicht erreichbar" mit Weg zu "Erneut versuchen" und "Entwicklung" (Verbindung trennen)
    private func unreachableBanner(_ error: String) -> some View {
        UFCard {
            HStack(spacing: 7.2) { UFIcon("alert", size: 18); Text("Eigener UniFlow-Server nicht erreichbar").font(UF.h2) }
                .foregroundStyle(UF.warn)
            Text("\(error)\nDie Einstellungen dieses iPads kannst du trotzdem ändern. Unter „Entwicklung“ trennst du die Verbindung.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
                .fixedSize(horizontal: false, vertical: true)
            UFFlexWrap(gap: 9.6) {
                UFButton("Erneut versuchen", icon: "refresh", kind: .primary, size: .small) { Task { await load() } }
                UFButton("Entwicklung", icon: "layers", size: .small) { tab = "dev" }
            }
        }
        .padding(.bottom, 16)
    }

    /// .set-layout: 240 px Navigation | Inhalt, gap 1.2rem; bis 820 px untereinander, Navigation waagerecht
    @ViewBuilder private func layout<N: View, P: View>(_ nav: N, _ pane: P) -> some View {
        if windowWidth <= 820 {
            VStack(alignment: .leading, spacing: 19.2) { nav; pane }
        } else {
            HStack(alignment: .top, spacing: 19.2) { nav.frame(width: 240); pane.frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

/// .set-nav: Knoepfe mit Icon 16, min. 44 pt hoch; aktiv --accent-soft / --accent-text
struct SettingsNav: View {
    @Binding var tab: String
    let horizontal: Bool
    /// nur diese Bereiche zeigen (ohne Server: Zugang & Darstellung, Entwicklung)
    var keys: [String]?
    static let items: [(String, String, String)] = [("modules", "Module & Wochentests", "book"), ("plan", "Lernzeit & Verfügbarkeit", "clock"),
                                                    ("account", "Zugang & Darstellung", "user"), ("advanced", "Erweitert", "settings"),
                                                    ("dev", "Entwicklung", "layers")]
    /// ohne eigenen Server: Zugang & Darstellung, Module und Lernzeit (lokales Backend), Erweitert (Demo-Inhalte fuer die
    /// App-Pruefung, auch im Release-Build: die Pruefer von Apple muessen sie finden), Entwicklung (nur Debug)
    @MainActor static func localKeys(withPlan: Bool) -> [String] { localKeys(withPlan: withPlan, ownServer: Session.ownServerAvailable) }

    static func localKeys(withPlan: Bool, ownServer: Bool) -> [String] {
        ["account"] + (withPlan ? ["modules", "plan"] : []) + ["advanced"] + (ownServer ? ["dev"] : [])
    }

    /// Beschriftung eines Bereichs; ohne eigenen Server gibt es keine Wochentests (keine KI)
    static func label(_ key: String, _ label: String, local: Bool) -> String {
        local && key == "modules" ? "Module" : label
    }

    var body: some View {
        // "Entwicklung" (eigener Server) gibt es im Release-Build nicht
        let shown = Self.items.filter { (keys?.contains($0.0) ?? true) && ($0.0 != "dev" || Session.ownServerAvailable) }
        let buttons = ForEach(shown, id: \.0) { item in
            let (k, i) = (item.0, item.2)
            let l = Self.label(k, item.1, local: keys != nil)
            Button { tab = k } label: {
                HStack(spacing: 9.6) {
                    UFIcon(i, size: 16)
                    Text(l).ufFont(14.5, 500).fixedSize(horizontal: horizontal, vertical: false).multilineTextAlignment(.leading)
                }
                .foregroundStyle(tab == k ? UF.accentText : UF.text2)
                .padding(.vertical, 10.4).padding(.horizontal, 12.8)
                .frame(maxWidth: horizontal ? nil : .infinity, minHeight: 44, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(tab == k ? UF.accentSoft : .clear))
                .contentShape(RoundedRectangle(cornerRadius: UF.rSm))
            }
            .buttonStyle(.plain)
        }
        if horizontal {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 3.2) { buttons } }
        } else {
            VStack(alignment: .leading, spacing: 3.2) { buttons }
        }
    }
}

private struct SettingsBody: View {
    let tab: String
    let d: SettingsPage.Loaded
    let reload: () async -> Void

    var body: some View {
        switch tab {
        case "account": AccountTab(d: d)
        case "advanced": AdvancedTab(d: d)
        case "dev": DevelopmentTab()
        case "plan": PlanTab(s: d.s)
        default: ModulesTab(d: d, reload: reload)
        }
    }
}

/// gemeinsame Aenderungen ueber die API mit Meldung wie im Web
@MainActor
private struct SettingsAPI {
    let api: APIClient?
    let toast: UFToastCenter
    let router: UFRouter

    func put(_ body: [String: JSONValue], toast text: String = "Gespeichert", reload: Bool = false) async {
        guard let api else { return }
        do {
            _ = try await api.value("/api/settings", method: "PUT", body: .object(body))
            toast.show(text)
            if reload { router.reload() }
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }

    func send(_ path: String, method: String, body: JSONValue? = nil, toast text: String?, reload: Bool = true) async -> JSONValue? {
        guard let api else { return nil }
        do {
            let r = try await api.value(path, method: method, body: body)
            if let text { toast.show(text) }
            if reload { router.reload() }
            return r
        } catch { toast.show(error.localizedDescription, seconds: 4); return nil }
    }
}

// MARK: - Module & Wochentests

private struct ModulesTab: View {
    let d: SettingsPage.Loaded
    let reload: () async -> Void
    /// Wochentests (KI) nur mit eigenem Server; ohne PC nur Module und Zuordnung
    var withTests = true
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var openMod: Int?
    @State private var autoTests = false

    private var api: SettingsAPI { SettingsAPI(api: session.api, toast: toast, router: router) }

    var body: some View {
        let active = d.mods.filter { $0.i("active") != 0 }
        let tmin = d.s.i("test_minutes") ?? 30
        let loose = d.courses.filter { ($0["module_id"]?.isNull ?? true) && $0.s("id") != "__user__" }
        UFCard {
            UFCardHead(withTests ? "Module & Wochentests" : "Module") { UFBadge("\(active.count) aktiv", tone: .ok) }
            if withTests {
                (Text("Ein Modul fasst mehrere Stud.IP-Kurse zusammen (Vorlesung, Hörsaalübung, Gruppenübung …). Pro Modul und Lehrwoche entsteht höchstens ")
                 + Text("ein gemeinsamer Wochentest").font(.uf(13.12, 700))
                 + Text(", und nur wenn in der Woche neue Inhalte vorliegen."))
                    .ufFont(13.12).foregroundStyle(UF.muted).padding(.bottom, 5.6)

                // .row.wrap (margin .6rem 0): Checkbox, Spacer, "Standard-Testdauer" mit Segment
                UFFlexWrap(gap: 9.6) {
                    UFCheckbox("Gemeinsamen Wochentest pro Modul automatisch erstellen", isOn: Binding(get: { autoTests }, set: { v in
                        autoTests = v
                        Task { await api.put(["auto_tests": .bool(v)]) }
                    }))
                    UFFlexSpacer()
                    HStack(spacing: 8) {
                        Text("Standard-Testdauer").ufFont(13.6).foregroundStyle(UF.text2)
                        UFSegmented(options: [(15, "15 Min."), (30, "30 Min."), (60, "60 Min."), (0, "Eigene")],
                                    selection: Binding(get: { [15, 30, 60].contains(tmin) ? tmin : 0 }, set: { v in setMinutes(v, current: tmin) }))
                    }
                }
                .padding(.vertical, 9.6 - 5.6)
            } else {
                Text("Ein Modul fasst die Stud.IP-Kurse eines Fachs zusammen (Vorlesung, Übung, Gruppenübung …). Beim Abgleich ordnet UniFlow neue Kurse nach ihrem Titel einem Fach zu; hier legst du Module an und änderst die Zuordnung.")
                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 5.6)
            }

            VStack(alignment: .leading, spacing: 8) {                                          // .stack
                ForEach(d.mods.indices, id: \.self) { i in moduleRow(d.mods[i]) }
                if !loose.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Ohne Modul (nicht eingeplant)").ufFont(14.5, 700).foregroundStyle(UF.muted)
                        ForEach(loose.indices, id: \.self) { i in
                            let c = loose[i]
                            HStack(spacing: 9.6) {
                                Text(c.s("title") ?? "").ufFont(13.12).foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                                UFSelect(options: [(0, "– kein Modul –")] + d.mods.compactMap { m in m.i("id").map { ($0, UFFmt.shortName(m.s("name"))) } },
                                         selection: Binding(get: { 0 }, set: { v in assign(c, v) }))
                            }
                            .padding(.top, 6.4)
                        }
                    }
                    .padding(.vertical, 11.2 + ufB).padding(.horizontal, 14.4 + ufB)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
                }
            }

            UFFlexWrap(gap: 9.6) {
                UFChip(text: "Modul anlegen", icon: "plus") { overlay.modal { NewModuleDialog() } }
                UFChip(text: "Zuordnung automatisch prüfen", icon: "sparkles") { Task { await autoAssign() } }
            }
            .padding(.top, 12.8)

            if withTests {
                (Text("Deine Einstellungen:").font(.uf(13.12, 700))
                 + Text(" \(active.filter { $0.i("weekly_test") != 0 }.count) Wochentests in einer Woche mit neuen Inhalten in allen aktiven Modulen, jeweils \(tmin) Minuten. Vorlesungen und sämtliche zugehörigen Übungen werden gemeinsam berücksichtigt."))
                    .ufFont(13.12).foregroundStyle(UF.muted)
                    .padding(.top, 12.8).padding(.bottom, 5.6)
            }
        }
        .onAppear { autoTests = d.s["auto_tests"]?.bool ?? ((d.s.i("auto_tests") ?? 0) != 0) }
    }

    /// .card.flat (padding .7rem .9rem): Kopfzeile klappt die Kurstabelle auf; inaktive Module blass (.muted)
    @ViewBuilder private func moduleRow(_ m: JSONValue) -> some View {
        let id = m.i("id") ?? 0
        let cs = d.courses.filter { $0.i("module_id") == id }
        let open = openMod == id
        let inactive = m.i("active") == 0
        VStack(alignment: .leading, spacing: 0) {
            // .row.wrap mit b { flex: 1 }: der Name nimmt den freien Platz und bricht selbst um
            HStack(spacing: 9.6) {
                Circle().fill(Color(hex: m.s("color"))).frame(width: 12, height: 12)
                Text(m.s("name") ?? "").ufFont(14.5, 700).foregroundStyle(inactive ? UF.muted : UF.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(cs.count) Kurse").ufFont(13.12).foregroundStyle(UF.muted).fixedSize()
                if withTests {
                    UFBadge(m.i("weekly_test") == 0 ? "kein Wochentest" : "1 gemeinsamer Test pro Woche" + (m.i("test_minutes").map { " · \($0) min" } ?? ""),
                            tone: m.i("weekly_test") == 0 ? .neutral : .ok)
                        .fixedSize()                                               // .badge: white-space nowrap
                }
                ActiveToggle(on: !inactive) { v in
                    Task { _ = await api.send("/api/modules/\(id)", method: "PATCH", body: ["active": .number(v ? 1 : 0)], toast: "Gespeichert") }
                }
                .fixedSize()
                Button { overlay.modal { ModuleEditDialog(m: m) } } label: { UFIcon("settings", size: 14) }
                    .buttonStyle(UFButtonStyle(kind: .ghost, size: .small, iconOnly: true))
                UFIcon(open ? "chevron-down" : "chevron-right", size: 16).foregroundStyle(inactive ? UF.muted : UF.text)
            }
            .contentShape(Rectangle())
            .onTapGesture { openMod = open ? nil : id }
            if open {
                CoursesTable(courses: cs, mods: d.mods, setKind: setKind, assign: assign)
                    .padding(.top, 8)
                    .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
                    .padding(.top, 9.6)
            }
        }
        .padding(.vertical, 11.2 + ufB).padding(.horizontal, 14.4 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
    }

    private func setMinutes(_ v: Int, current: Int) {
        if v == 0 {
            Task {
                guard let text = await overlay.prompt("Testdauer in Minuten:", value: "\(current)"),
                      let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0 else { return }
                await api.put(["test_minutes": .number(Double(n))], toast: "Testdauer gespeichert", reload: true)
            }
        } else {
            Task { await api.put(["test_minutes": .number(Double(v))], toast: "Testdauer gespeichert", reload: true) }
        }
    }

    private func setKind(_ c: JSONValue, _ kind: String) {
        guard let id = c.s("id") else { return }
        Task { _ = await api.send("/api/courses/\(id)", method: "PATCH", body: ["kind": .string(kind)], toast: "Gespeichert", reload: false) }
    }

    private func assign(_ c: JSONValue, _ module: Int) {
        guard let id = c.s("id") else { return }
        Task { _ = await api.send("/api/courses/\(id)/module", method: "POST", body: ["module_id": module == 0 ? .null : .number(Double(module))], toast: "Zuordnung gespeichert") }
    }

    private func autoAssign() async {
        guard let r = await api.send("/api/modules/auto-assign", method: "POST", toast: nil) else { return }
        let unsure = r.list("uncertain")
        toast.show("\(r.i("assigned") ?? 0) Kurse zugeordnet" + (unsure.isEmpty ? "" : ", \(unsure.count) unsicher"))
        if !unsure.isEmpty { overlay.modal { UncertainDialog(items: unsure) } }
    }
}

/// <label class="small"><input type="checkbox"> aktiv</label>
private struct ActiveToggle: View {
    let on: Bool
    let change: (Bool) -> Void
    @State private var value = false

    var body: some View {
        Button { value.toggle(); change(value) } label: {
            HStack(spacing: 4.8) {
                Image(systemName: value ? "checkmark.square.fill" : "square").foregroundStyle(value ? UF.accent : UF.muted)
                Text("aktiv").ufFont(13.12).foregroundStyle(UF.text)
            }
        }
        .buttonStyle(.plain)
        .onAppear { value = on }
        .onChange(of: on) { _, v in value = v }
    }
}

/// table.tbl: Stud.IP-Kurs / Art / Modul mit Auswahlfeldern
private struct CoursesTable: View {
    let courses: [JSONValue]
    let mods: [JSONValue]
    let setKind: (JSONValue, String) -> Void
    let assign: (JSONValue, Int) -> Void
    private static let kinds = ["vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium", "labor", "seminar", "sonstiges"]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(["Stud.IP-Kurs", "Art", "Modul"], id: \.self) { h in
                    Text(h.uppercased()).ufFont(12.16, 600, em: 0.04).foregroundStyle(UF.muted)
                        .padding(.vertical, 7.2).padding(.horizontal, 8)
                        .frame(maxWidth: h == "Stud.IP-Kurs" ? .infinity : nil, alignment: .leading)
                }
            }
            line
            if courses.isEmpty {
                Text("Keine Kurse zugeordnet.").ufFont(13.76).foregroundStyle(UF.muted).padding(8)
                line
            }
            ForEach(courses.indices, id: \.self) { i in
                let c = courses[i]
                GridRow(alignment: .center) {
                    Text(c.s("title") ?? "").ufFont(13.76).foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    UFSelect(options: Self.kinds.map { ($0, UFKind.text($0)) },
                             selection: Binding(get: { c.s("kind") ?? "sonstiges" }, set: { setKind(c, $0) }), cell: true).padding(8)
                    UFSelect(options: mods.compactMap { m in m.i("id").map { ($0, UFFmt.shortName(m.s("name"))) } } + [(0, "– kein Modul –")],
                             selection: Binding(get: { c.i("module_id") ?? 0 }, set: { assign(c, $0) }), cell: true).padding(8)
                }
                line
            }
        }
    }

    private var line: some View { Rectangle().fill(UF.line).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
}

/// Modal "Neues Modul": Name, Abbrechen / Anlegen
private struct NewModuleDialog: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var name = ""

    var body: some View {
        UFDialog("Neues Modul") {
            UFField("Name") { UFTextInput(text: $name) }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Anlegen", kind: .primary) {
                Task {
                    do {
                        _ = try await session.api?.value("/api/modules", method: "POST", body: ["name": .string(name)])
                        close()
                        router.reload()
                    } catch { toast.show(error.localizedDescription, seconds: 4) }
                }
            }
        }
    }
}

/// Modal "Unsichere Zuordnungen": Liste "Kurs → Vorschlag", OK
private struct UncertainDialog: View {
    let items: [JSONValue]
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Unsichere Zuordnungen") {
            Text("Bitte unter dem jeweiligen Modul prüfen.").ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    Text("\(items[i].s("title") ?? "") → \(items[i].s("suggestion") ?? "kein Vorschlag")")
                        .overlay(alignment: .topLeading) { Text("•").offset(x: -13) }
                }
            }
            .ufFont(13.12).foregroundStyle(UF.text)
            .padding(.leading, 40).padding(.vertical, 13.12)
        } foot: {
            UFButton("OK", kind: .primary) { close() }
        }
    }
}

// MARK: - Lernzeit & Verfuegbarkeit

private struct PlanTab: View {
    let s: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let a = PlanActions(api: session.api, overlay: overlay, toast: toast, router: router)
        let free = (s["free_days"]?.array ?? []).compactMap(\.int).map { ShellState.days[safe: $0] ?? "" }
        UFCard {
            UFCardHead("Lernzeit & Verfügbarkeit")
            Text("Lernkombination (Fächer pro Tag, Vorlesung/Übungen/Wochentest) und persönliche Verfügbarkeit (Lernzeiten, Fahrtzeit, Sperrzeiten).")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.bottom, 5.6)
            UFFlexWrap(gap: 9.6) {
                UFButton("Lernkombination", icon: "settings", kind: .primary) { a.config { router.reload() } }
                UFButton("Verfügbarkeit & Sperrzeiten", icon: "clock") { a.availability() }
            }
            Text("Aktuell: \(s.i("subjects_per_day") ?? 0) Fächer pro Tag · \(UFFmt.min(s.n("minutes_per_day"))) · Lernzeit \(s.s("learn_start") ?? "")–\(s.s("learn_end") ?? "") · freie Tage: \(free.isEmpty ? "keine" : free.joined(separator: ", ")) · Fahrtzeit \(s.i("travel_minutes") ?? 0) min")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 12.8)
        }
    }
}

// MARK: - Zugang & Darstellung

private struct AccountTab: View {
    let d: SettingsPage.Loaded
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true
    @AppStorage("uniflow.hand") private var localHand = "right"
    @State private var termName = ""
    @State private var termStart = ""
    @State private var termEnd = ""
    @State private var userName = ""
    @State private var pen = "all"
    @State private var hand = "right"
    @State private var studipSheet = false

    private var api: SettingsAPI { SettingsAPI(api: session.api, toast: toast, router: router) }

    var body: some View {
        // .set-body .grid.cols-2: auto-fit, minmax(340px, 1fr); .span-2 ueber die ganze Zeile
        VStack(alignment: .leading, spacing: 16) {
            AppAccountCards()
            UFGridLayout(spacing: 16, minWidth: 340) {
                credCard
                looksCard
            }
            .environment(\.ufFillsCell, true)
            CommunitySettingsCard()                                          // Pseudonym, Lerngruppen, Sperrliste
        }
            .onAppear {
                termName = d.term.s("name") ?? ""
                termStart = d.term.s("start") ?? ""
                termEnd = d.term.s("end") ?? ""
                userName = d.s.s("user_name") ?? ""
                pen = d.s.s("pen_input") ?? (pencilOnly ? "pen_only" : "all")
                hand = d.s.s("hand") ?? "right"
                localHand = hand
            }
            .sheet(isPresented: $studipSheet) { SettingsSheet(close: { studipSheet = false }) { StudIPView() } }
    }

    /// Stud.IP-Zugang: Status wie im Web; ohne Passwortfeld (Anmeldung auf der echten Stud.IP-Seite)
    private var credCard: some View {
        let saved = d.cred.s("user") != nil && d.cred["password_set"]?.bool == true
        return UFCard {
            UFCardHead("Stud.IP-Zugang", icon: "log-out") {
                saved ? UFBadge("gespeichert", tone: .ok) : UFBadge("fehlt", tone: .warn)
            }
            Text("Nur lokal in der .env gespeichert, für den Sync um 8 und 15 Uhr.").ufFont(13.12).foregroundStyle(UF.muted).padding(.bottom, 5.6)
            UFField("LUH-ID") {
                UFInputBox { Text(d.cred.s("user") ?? "noch nicht gesetzt").foregroundStyle(d.cred.s("user") == nil ? UF.muted : UF.text) }
                    .opacity(0.8)
            }
            Text("Das WebSSO-Passwort trägst du selbst in der Web-App am PC ein. Auf dem iPad wird kein Passwort eingegeben – für Stud.IP direkt meldest du dich auf der echten Stud.IP-Seite an.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
            UFFlexWrap(gap: 9.6) {
                UFButton("Dateien jetzt holen (ohne KI)", size: .small) {
                    Task {
                        if await api.send("/api/sync?ai=false", method: "POST", toast: "Dateien werden geholt…", reload: false) != nil {
                            await shell.pollBackground(toast: toast)
                        }
                    }
                }
                UFButton("Stud.IP direkt auf dem iPad", icon: "book", size: .small) { studipSheet = true }
            }
        }
    }

    private var looksCard: some View {
        UFCard {
            UFCardHead("Semester", icon: "calendar")
            HStack(alignment: .top, spacing: 9.6) {                               // .row, label.field { flex: 1 }
                UFField("Name") { UFTextInput(text: $termName) }
                UFField("Beginn") { UFDateField(iso: $termStart) }
                UFField("Ende") { UFDateField(iso: $termEnd) }
            }
            UFButton("Speichern", kind: .primary, size: .small) {
                Task { _ = await api.send("/api/terms", method: "PUT", body: ["name": .string(termName), "start": .string(termStart), "end": .string(termEnd)], toast: "Semester gespeichert", reload: false) }
            }

            UFCardHead("Anzeigename", icon: "user").padding(.top, 16)
            HStack(spacing: 9.6) {
                UFTextInput("z. B. Ahmad H.", text: $userName).frame(maxWidth: 260)
                UFButton("Speichern", size: .small) {
                    Task {
                        await api.put(["user_name": .string(userName)])
                        await shell.refresh()                                    // Web: location.reload() fuer die Initialen
                    }
                }
            }

            UFCardHead("Darstellung", icon: "sun").padding(.top, 16)
            UFSegmented(options: [("auto", "Automatisch"), ("light", "Hell"), ("dark", "Dunkel")], selection: $theme)

            UFCardHead("Stift & Touch", icon: "pen").padding(.top, 16)
            UFSelect(options: [("all", "Finger darf schreiben (Handballen wird bei Stift ignoriert)"), ("pen_only", "Nur Stift schreibt, Finger navigiert")],
                     selection: Binding(get: { pen }, set: { v in
                         pen = v
                         pencilOnly = v == "pen_only"                               // Editor auf dem iPad
                         Task { await api.put(["pen_input": .string(v)]) }
                     }))

            UFCardHead("Schreibhand", icon: "hand").padding(.top, 16)
            UFSegmented(options: [("right", "Rechtshänder"), ("left", "Linkshänder")],
                        selection: Binding(get: { hand }, set: { v in
                            hand = v
                            localHand = v                                         // Seite des Skripts in der geteilten Ansicht
                            Task { await api.put(["hand": .string(v)], toast: "Schreibhand gespeichert") }
                        }))
            Text("Geteilte Ansicht: Das Skript öffnet auf der Seite der freien Hand (35 %), das Übungsblatt daneben.")
                .ufFont(11.84).foregroundStyle(UF.muted).padding(.top, 6.4).padding(.bottom, 5.6)
        }
    }
}

// MARK: - Konto und Tarif (auch ohne Server)

private struct UFSwitchPlanKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// "Tarif wechseln" in den Einstellungen; setzt das Abo-Paket. Ohne Wert oeffnet die Karte im Debug-Build die
    /// bisherige Tarifansicht (Testmodus); im Release ist der Knopf dann deaktiviert (keine Preise ohne Pflichtangaben).
    var ufSwitchPlan: (() -> Void)? {
        get { self[UFSwitchPlanKey.self] }
        set { self[UFSwitchPlanKey.self] = newValue }
    }
}

/// Karten "Konto" (Mit Apple angemeldet, Konto loeschen), "Tarif" und "Hochschule" (Wechsel, Daten loeschen)
private struct AppAccountCards: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufSwitchPlan) private var switchPlan
    @State private var plans = false

    var body: some View {
        UFGridLayout(spacing: 16, minWidth: 340) {
            accountCard
            planCard
            UniversitySettingsCard()
        }
        .environment(\.ufFillsCell, true)
        #if DEBUG
        .sheet(isPresented: $plans) { SettingsSheet(close: { plans = false }) { SubscriptionView() } }
        #endif
    }

    /// ohne Abo-Paket gibt es nur im Debug-Build einen Ersatz
    private var canSwitchPlan: Bool { switchPlan != nil || AccountStore.isDebugBuild }

    private var accountCard: some View {
        let a = account.account
        return UFCard {
            UFCardHead("Konto", icon: "user") {
                if a?.isDebug == true { UFBadge("Debug ohne Apple-ID", tone: .warn) } else { UFBadge("Mit Apple angemeldet", tone: .ok) }
            }
            VStack(alignment: .leading, spacing: 7.2) {
                if a?.isDebug == true {
                    Text("Die Anmeldung wurde in diesem Debug-Build übersprungen.").foregroundStyle(UF.muted)
                } else {
                    (Text("Name: ").font(.uf(13.12, 700)) + Text(a?.name ?? "nicht freigegeben"))
                    (Text("E-Mail: ").font(.uf(13.12, 700)) + Text(a?.email ?? "nicht freigegeben"))
                }
                Text("Das Konto ordnet dein Abo, deine Hochschule und ihre Verbindungen zu. Deine Dateien und Notizen bleiben auf diesem iPad.")
                    .foregroundStyle(UF.muted)
            }
            .ufFont(13.12).foregroundStyle(UF.text)
            UFFlexWrap(gap: 9.6) {
                UFButton("Konto löschen", icon: "trash", kind: .danger, size: .small) { overlay.modal { DeleteAccountDialog() } }
            }
            .padding(.top, 9.6)
        }
    }

    /// Platz fuer den Tarif; Inhalt (aktueller Tarif, Verwalten, Wiederherstellen) baut das Abo-Paket
    private var planCard: some View {
        UFCard {
            UFCardHead("Tarif", icon: "star")
            Text(canSwitchPlan
                 ? "Free oder Plus wählen, Abo verwalten und Käufe wiederherstellen."
                 : "Die Auswahl zwischen Free und Plus folgt hier.")
                .ufFont(13.12).foregroundStyle(UF.muted)
            UFFlexWrap(gap: 9.6) {
                UFButton("Tarif wechseln", icon: "star", kind: .primary, size: .small) {
                    if let switchPlan { switchPlan() } else { plans = true }
                }
                .disabled(!canSwitchPlan)
            }
            .padding(.top, 9.6)
        }
    }
}

/// Texte der Rueckfrage "Konto loeschen": die Server-PIN gibt es nur im Debug-Build mit eigenem Server
/// (`Session.ownServerAvailable`), im Release kein Hinweis auf PC, Server oder PIN. V1 loest keine Apple-Token ein
/// (kein Server), darum kann die App die Verknuepfung "Mit Apple anmelden" nicht selbst widerrufen; der Nutzer loest
/// sie in den Einstellungen des iPads.
enum DeleteAccountText {
    static func removed(ownServer: Bool) -> String {
        "Deine Anmeldung mit Apple, die Kontodaten und alle Schlüsselbund-Einträge von UniFlow (Stud.IP-Sitzung, "
            + (ownServer ? "Server-PIN, " : "") + "gemerkte Hochschul-Zugangsdaten) werden von diesem iPad entfernt. Danach siehst du wieder die Begrüßung."
    }

    static let appleID = "UniFlow speichert dein Apple-Konto nirgends außerhalb dieses iPads. Die Verknüpfung „Mit Apple anmelden“ löst du in den Einstellungen des iPads: dein Name → Anmelden und Sicherheit → Mit Apple anmelden → UniFlow."
}

/// Rueckfrage "Konto loeschen" (Richtlinie 5.1.1(v)) mit Hinweis auf die Abo-Verwaltung bei Apple
private struct DeleteAccountDialog: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var busy = false


    var body: some View {
        UFDialog("Konto löschen?", icon: "trash") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(DeleteAccountText.removed(ownServer: Session.ownServerAvailable))
                Text("Ebenso werden alle Daten deines Kontos auf diesem iPad gelöscht, für jede Hochschule: heruntergeladene Dateien, eigene Dokumente, Notizen, Lernplan, Einstellungen und die Anmeldungen in den Webansichten. Das lässt sich nicht rückgängig machen.")
                    .font(.uf(13.12, 600)).foregroundStyle(UF.bad)
                Text("Ein Abo wird dadurch nicht gekündigt. Abos kündigst du bei Apple:").font(.uf(13.12, 700)).foregroundStyle(UF.text)
                Link("Abos verwalten", destination: AccountStore.manageSubscriptionsURL)
                    .ufFont(13.12, 600).foregroundStyle(UF.accentText)
                Text(DeleteAccountText.appleID)
                ContainerSyncGate { syncing in
                    if syncing { ContainerSyncNotice() }
                }
            }
            .ufFont(13.12).foregroundStyle(UF.text2)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { close() }
            // gesperrt, solange ein Abgleich laeuft (deleteAllData haelt ihn sonst an und wartet auf ihn)
            ContainerSyncGate { syncing in
                UFButton("Konto löschen", icon: "trash", kind: .danger) {
                    busy = true
                    Task {
                        // RootView zeigt danach die Begruessung
                        let steps = account.account.map { AccountStore.deletionSteps(containers: containers, session: session, userID: $0.userID) } ?? []
                        await account.deleteAccount(also: steps) {
                            overlay.closeAll()
                            router.go(.dashboard)
                        }
                    }
                }
                .disabled(busy || syncing)
            }
        }
    }
}

/// "Zugang & Darstellung" ohne Server: Konto, Tarif, Stud.IP und QIS (LUH) bzw. Learnweb und LSF (Uni Hildesheim),
/// Semester (lokales Backend) und die
/// Einstellungen dieses Geraets
private struct LocalAccountTab: View {
    /// aktives Semester aus /api/terms; nil, solange nicht geladen
    var term: JSONValue?
    var reload: () async -> Void = {}
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufDemoActive) private var demo
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true
    @AppStorage("uniflow.hand") private var hand = "right"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Demo-Inhalte aktiv: eine Anmeldung unten gleicht erst nach dem Entfernen ab
            if demo { DemoActiveBar() }
            AppAccountCards()
            UFGridLayout(spacing: 16, minWidth: 340) {
                if studip.offersStudIP {
                    LUHSourcesCard()                                         // Stud.IP und QIS der LUH (Views/QISViews.swift)
                } else {
                    HildesheimSourcesCard()                                  // Learnweb und LSF der Uni Hildesheim
                }
                DueReminderCard()                                            // Erinnerungen an Abgaben und Prüfungen
                UFCard {
                    if let term { SemesterFields(term: term, reload: reload).padding(.bottom, 16) }
                    UFCardHead("Darstellung", icon: "sun")
                    UFSegmented(options: [("auto", "Automatisch"), ("light", "Hell"), ("dark", "Dunkel")], selection: $theme)
                    UFCardHead("Stift & Touch", icon: "pen").padding(.top, 16)
                    UFSelect(options: [("all", "Finger darf schreiben (Handballen wird bei Stift ignoriert)"), ("pen_only", "Nur Stift schreibt, Finger navigiert")],
                             selection: Binding(get: { pencilOnly ? "pen_only" : "all" }, set: { pencilOnly = $0 == "pen_only" }))
                    UFCardHead("Schreibhand", icon: "hand").padding(.top, 16)
                    UFSegmented(options: [("right", "Rechtshänder"), ("left", "Linkshänder")], selection: $hand)
                    Text("Geteilte Ansicht: Das Skript öffnet auf der Seite der freien Hand (35 %), das Übungsblatt daneben.")
                        .ufFont(11.84).foregroundStyle(UF.muted).padding(.top, 6.4).padding(.bottom, 5.6)
                }
                BackgroundSyncCard()                                         // Abgleich im Hintergrund (S8)
            }
            .environment(\.ufFillsCell, true)
            CommunitySettingsCard()                                          // Pseudonym, Lerngruppen, Sperrliste (Plus)
        }
    }
}

/// "Semester": Name, Beginn, Ende wie im Web (PUT /api/terms legt ein neues aktives Semester an)
private struct SemesterFields: View {
    let term: JSONValue
    let reload: () async -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var name = ""
    @State private var start = ""
    @State private var end = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UFCardHead("Semester", icon: "calendar")
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Name") { UFTextInput(text: $name) }
                UFField("Beginn") { UFDateField(iso: $start) }
                UFField("Ende") { UFDateField(iso: $end) }
            }
            UFButton("Speichern", kind: .primary, size: .small) {
                Task {
                    let body: JSONValue = ["name": .string(name), "start": .string(start), "end": .string(end)]
                    if await SettingsAPI(api: session.api, toast: toast, router: router)
                        .send("/api/terms", method: "PUT", body: body, toast: "Semester gespeichert", reload: false) != nil {
                        await reload()
                    }
                }
            }
        }
        .onAppear {
            name = term.s("name") ?? ""
            start = term.s("start") ?? ""
            end = term.s("end") ?? ""
        }
    }
}

/// Blatt mit "Fertig" fuer die bisherigen Systemansichten (Stud.IP direkt, Tarif im Testmodus)
private struct SettingsSheet<Content: View>: View {
    let close: () -> Void
    @ViewBuilder let content: Content

    init(close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.close = close
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
    }
}

// MARK: - Entwicklung

/// Nur fuer den Inhaber: Verbindung zum eigenen UniFlow-Server (frueher der Startbildschirm)
private struct DevelopmentTab: View {
    /// gespeicherter Server antwortet nicht (Netzfehler, PIN abgelehnt)
    var error: String?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.isOwnServer, let api = session.api {
                UFCard {
                    UFCardHead("Eigener UniFlow-Server", icon: "layers") {
                        error == nil ? UFBadge("verbunden", tone: .ok) : UFBadge("nicht erreichbar", tone: .warn)
                    }
                    VStack(alignment: .leading, spacing: 7.2) {
                        (Text("Server: ").font(.uf(13.12, 700)) + Text(api.base.absoluteString))
                        Text("Die Daten kommen von deinem UniFlow-Server. Die PIN liegt im Schlüsselbund dieses iPads. Nach „Verbindung trennen“ kommen die Daten wieder vom iPad selbst; Notizen beider Quellen bleiben getrennt erhalten.")
                            .foregroundStyle(UF.muted)
                    }
                    .ufFont(13.12).foregroundStyle(UF.text)
                    UFFlexWrap(gap: 9.6) {
                        UFButton("Verbindung trennen", icon: "log-out", kind: .danger, size: .small) {
                            Task { if await overlay.confirm("Verbindung zum UniFlow-Server trennen?") { session.disconnect() } }
                        }
                    }
                    .padding(.top, 9.6)
                }
            } else {
                ConnectView()
            }
        }
    }
}

/// "Mit eigenem UniFlow-Server verbinden": die Adresse darf die App vortragen (zuletzt verwendet oder -UFServerHint),
/// die PIN gibt der Nutzer selbst ein.
struct ConnectView: View {
    @EnvironmentObject private var session: Session
    @State private var url = ""
    @State private var pin = ""

    var body: some View {
        UFCard {
            UFCardHead("Mit eigenem UniFlow-Server verbinden", icon: "layers") { UFBadge("Entwicklung", tone: .neutral) }
            Text("Nur für die Entwicklung: verbindet dieses iPad mit deinem UniFlow-Server im WLAN. Am PC Start-iPad.cmd starten; Adresse und PIN stehen in der Web-App unter Einstellungen → Zugang & Darstellung → Auf dem iPad benutzen.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.bottom, 5.6)
            UFField("Adresse") {
                UFTextField("http://192.168.0.10:8765", text: $url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            UFField("PIN") {
                UFTextField("6 Ziffern", text: $pin, secure: true).keyboardType(.numberPad).frame(maxWidth: 260)
            }
            if let error = session.lastError {
                HStack(alignment: .top, spacing: 7.2) {
                    UFIcon("alert", size: 14)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .ufFont(13.12).foregroundStyle(UF.bad).padding(.top, 5.6)
            }
            UFFlexWrap(gap: 9.6) {
                UFButton(session.connecting ? "Verbinde …" : "Verbinden", icon: "sync", kind: .primary, size: .small) {
                    Task { await session.connect(urlString: url, pin: pin) }
                }
                .disabled(url.isEmpty || pin.isEmpty || session.connecting)
            }
            .padding(.top, 9.6)
        }
        .onAppear { if url.isEmpty { url = session.savedURL } }
    }
}

// MARK: - Erweitert

/// "Erweitert" ohne Server: Demo-Inhalte fuer die App-Pruefung (Views/DemoViews.swift)
private struct LocalAdvancedTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DemoContentCard()
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

private struct AdvancedTab: View {
    let d: SettingsPage.Loaded
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufWindowWidth) private var windowWidth
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue
    @State private var autoPlan = false
    @State private var diag: Diagnostics?
    @State private var test: PDFTestResult?
    @State private var testing = false

    struct PDFTestResult { var ok: Bool; var lines: [String]; var image: UIImage? }
    struct PDFTestError: LocalizedError { var errorDescription: String? { "PDF nicht lesbar" } }

    private static let logDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d.M.yyyy, HH:mm:ss"                                       // toLocaleString("de-DE")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {                                    // .stack
            DemoContentCard()                                                        // Demo-Inhalte des eigenen Servers
            UFCard {
                UFCardHead("Sync-Protokoll", icon: "sync") {
                    Button {
                        autoPlan.toggle()
                        let v = autoPlan
                        Task { await SettingsAPI(api: session.api, toast: toast, router: router).put(["auto_plan": .bool(v)]) }
                    } label: {
                        HStack(spacing: 4.8) {
                            Image(systemName: autoPlan ? "checkmark.square.fill" : "square").foregroundStyle(autoPlan ? UF.accent : UF.muted)
                            Text("Lernkalender nach dem Sync automatisch auffüllen").ufFont(13.12).foregroundStyle(UF.text)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if d.log.isEmpty { Text("Noch kein Sync.").foregroundStyle(UF.muted) }
                        ForEach(d.log.indices, id: \.self) { i in
                            let l = d.log[i]
                            let ok = (l.i("ok") ?? 0) == 1 || l["ok"]?.bool == true
                            // HTML fasst Zeilenumbrueche und Leerraum zu einem Leerzeichen zusammen
                            let msg = String((l.s("message") ?? "").prefix(90)).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                            let when = l.s("started_at").flatMap { ISO8601DateFormatter.local.date(from: String($0.prefix(19))) }
                            Text("\(ok ? "✅" : "❌") \(when.map { Self.logDate.string(from: $0) } ?? "") – \(msg)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .ufFont(13.12).foregroundStyle(UF.text)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
            UFCard {
                UFCardHead("Diagnose", icon: "info") {
                    UFButton("Kopieren", icon: "copy", size: .small) {
                        UIPasteboard.general.string = diagText
                        toast.show("Diagnose kopiert")
                    }
                }
                Text(diagText)
                    .font(.system(size: 13.12, design: .monospaced))
                    .foregroundStyle(UF.text)
                    .padding(11.2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
                    .padding(.vertical, 13.12)
                    .textSelection(.enabled)

                UFCardHead("PDF-Anzeige testen", icon: "file-text") {
                    UFButton("Test starten", kind: .primary, size: .small) { Task { await runPDFTest() } }.disabled(testing)
                }
                .padding(.top, 16 - 13.12)
                Text("Lädt eine PDF aus deiner Bibliothek, liest sie mit PDFKit und zeichnet Seite 1 – genau wie der Editor. Wenn hier ein Bild erscheint, funktioniert die Anzeige auf diesem iPad.")
                    .ufFont(13.12).foregroundStyle(UF.muted).padding(.bottom, 5.6)
                if testing { Text("Prüfe…").ufFont(13.12).foregroundStyle(UF.text) }
                if let test {
                    VStack(alignment: .leading, spacing: 8) {
                        Text((test.ok ? "✅ " : "") + test.lines.joined(separator: "\n")).ufFont(13.12).foregroundStyle(test.ok ? UF.ok : UF.bad)
                        if let img = test.image {
                            Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: 220)
                                .overlay(Rectangle().strokeBorder(UF.line, lineWidth: 1))
                        }
                    }
                }
            }
        }
        .task {
            autoPlan = d.s["auto_plan"]?.bool ?? ((d.s.i("auto_plan") ?? 0) != 0)
            diag = await Diagnostics.collect()
        }
    }

    /// wie diagTab(): Geraet, Fenster, Design, Adresse, Version, dazu der Zustand der lokalen Daten
    private var diagText: String {
        let scale = UIScreen.main.scale
        var lines = [
            "Gerät: \(UIDevice.current.model), iPadOS \(UIDevice.current.systemVersion)",
            "Fenster: \(Int(windowWidth))×\(Int(UIScreen.main.bounds.height)), Pixelverhältnis \(Self.js(scale))",
            "Design: \(theme)",
            "Adresse: \(session.api?.base.absoluteString ?? "–")",
            "App-Version: \(diag?.appVersion ?? "…")",
        ]
        if let d = diag {
            lines += [
                "Lokale Notizen: \(ByteCountFormatter.string(fromByteCount: d.journalBytes, countStyle: .file))",
                "Zwischenspeicher: \(ByteCountFormatter.string(fromByteCount: d.cacheBytes, countStyle: .file))",
                "Ungesendete Seiten: \(d.unsentPages) in \(d.documentsWithUnsent) Dokumenten",
                "Beschädigte lokale Dateien: \(d.damaged.isEmpty ? "keine" : d.damaged.joined(separator: ", "))",
            ]
        }
        return lines.joined(separator: "\n")
    }

    private static func js(_ d: CGFloat) -> String { d == d.rounded() ? String(Int(d)) : "\(d)" }

    /// erste geladene PDF aus /library holen, mit PDFKit oeffnen und Seite 1 zeichnen
    private func runPDFTest() async {
        guard let api = session.api else { return }
        testing = true; test = nil
        defer { testing = false }
        var lines: [String] = []
        do {
            let lib = try await api.value("/api/library")
            guard let f = lib.list("files").first(where: { $0.s("kind") == "pdf" && !($0["downloaded_at"]?.isNull ?? true) }), let id = f.s("id") ?? f.i("id").map(String.init) else {
                test = PDFTestResult(ok: false, lines: ["Keine PDF vorhanden."], image: nil); return
            }
            let (data, resp) = try await api.data("/api/files/\(id)/content")
            lines.append("PDF-Abruf: HTTP \(resp.statusCode), Typ \(resp.value(forHTTPHeaderField: "Content-Type") ?? "?")")
            guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { throw PDFTestError() }
            lines.append("PDFKit: \(doc.pageCount) Seiten gelesen")
            let box = page.bounds(for: .mediaBox)
            let img = page.thumbnail(of: CGSize(width: box.width, height: box.height), for: .mediaBox)
            lines.append("Seite 1 gezeichnet (\(Int(box.width.rounded()))×\(Int(box.height.rounded())))")
            test = PDFTestResult(ok: true, lines: lines, image: img)
        } catch {
            lines.append("❌ \(error.localizedDescription)")
            test = PDFTestResult(ok: false, lines: lines, image: nil)
        }
    }
}
