import SwiftUI
import PDFKit
import UniFlowCore

// Einstellungen 1:1 nach viewSettings() und diagTab() in app/static/views-misc.js.
// Bewusst anders (WEB-IPAD-PARITAET.md, W.B.11.3): kein Passwortfeld fuer Stud.IP; statt "Auf dem iPad benutzen"
// (verbindet ein iPad mit dem PC) zeigt die Karte die Verbindung dieses iPads, Stud.IP direkt und den Tarif.
// V1 (docs/AUFTRAG-APPSTORE-V1.md 2a): Die Seite funktioniert auch ohne Server. Oben stehen "Konto" (Mit Apple
// angemeldet, Konto loeschen) und "Tarif"; die Verbindung zum eigenen PC-Server liegt unter "Erweitert" -> "Eigener
// Server (Entwicklung)" (nur in Debug-Builds). Gliederung in Bereiche seit 17.11.2026: `SettingsArea` (SettingsAreas.swift). Lokal kommen Lernzeit und Semester vom lokalen Backend (/api/settings, /api/terms), ebenso der
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.ufCompact) private var compact
    /// Sprungziel bzw. gewaehlter Bereich als Rohwert (`SettingsArea.resolve`); nil = Startseite der Einstellungen
    @State private var tab: String?
    /// Schmal (iPhone hoch und quer, Fenster bis 820 pt, Bedienungshilfen-Schriftgroessen): Liste der Bereiche mit
    /// Unterseiten statt Liste neben dem Inhalt (Audit 03.11.2026: die 232 pt breite Spalte liess dem Inhalt bei
    /// grosser Schrift so wenig Platz, dass Modulnamen buchstabenweise umbrachen)
    private var narrow: Bool { compact || windowWidth <= 820 || typeSize.isAccessibilitySize }
    /// Laden mit Fehlermeldung und nur dem zuletzt begonnenen Ergebnis (Pruefbericht 561-566, `SettingsLoader`)
    @StateObject private var loader = SettingsLoader()
    private var data: Loaded? { loader.data }
    private var error: String? { loader.error }
    /// lokal: Einstellungen und Semester aus dem lokalen Backend
    private var local: LocalLoaded? { loader.local }

    init(initialTab: String?) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

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
            if !session.isOwnServer { page(server: nil, error: nil) } else if let data { page(server: data, error: nil) } else if let error {
                page(server: nil, error: error)
            } else {
                UFContent(maxWidth: 1180) { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .onChange(of: initialTab) { _, t in tab = t }                      // Sprung, waehrend die Einstellungen offen sind
        .task(id: session.api?.base) { await load() }                      // nach Verbinden/Trennen unter "Erweitert"
        .ufReload { await load() }
    }

    private func load() async { await loader.load(api: session.api, ownServer: session.isOwnServer) }

    /// Die Seite in beiden Fassungen. `d`: Daten vom eigenen Server (nur Entwicklung); sonst der V1-Normalfall ohne
    /// Server mit Konto, Tarif, Hochschule und den Einstellungen dieses Geraets. Mit `error` ist ein gespeicherter
    /// Server nicht erreichbar: Hinweis oben, alles andere bleibt nutzbar ("Verbindung trennen", "Konto löschen").
    @ViewBuilder private func page(server d: Loaded?, error: String?) -> some View {
        let areas = SettingsArea.visible(hasData: d != nil || local != nil)
        let wanted = SettingsArea.resolve(tab, visible: areas, ownServer: Session.ownServerAvailable)
        // breit steht immer ein Bereich neben der Liste; schmal ist die Startseite die Liste selbst
        let shown = wanted ?? (narrow ? nil : areas.first)
        let editor = UFEditorAvailability.available
        UFContent(maxWidth: 1180) {
            if narrow, let shown {
                SettingsBackLink { tab = nil }
                UFPageHead(shown.title(editor: editor, withTests: d != nil), sub: shown.sub(editor: editor))
            } else {
                UFPageHead("Einstellungen")
            }
            if let error { unreachableBanner(error) }
            if let stale = loader.stale { staleBanner(stale, loaded: d != nil || local != nil) }
            if narrow {
                if let shown {
                    pane(shown, server: d, error: error)
                } else {
                    SettingsAreaList(areas: areas, withTests: d != nil) { tab = $0.rawValue }
                }
            } else if let shown {
                // .set-layout: Liste der Bereiche | Inhalt; etwas Luft dazwischen, die Spalten lesen sich als zwei Ebenen
                HStack(alignment: .top, spacing: 28.8) {
                    SettingsAreaNav(areas: areas, current: shown, withTests: d != nil) { tab = $0.rawValue }.frame(width: 232)
                    SettingsSection(shown.title(editor: editor, withTests: d != nil), sub: shown.sub(editor: editor)) {
                        pane(shown, server: d, error: error)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // schmal auf einer Unterseite: der Pfeil der Kopfzeile fuehrt zuerst zur Liste der Bereiche
        .ufLocalBack(id: "settings.area", active: narrow && shown != nil) { tab = nil }
    }

    /// Inhalt eines Bereichs
    @ViewBuilder private func pane(_ area: SettingsArea, server d: Loaded?, error: String?) -> some View {
        switch area {
        case .account:
            SettingsAccountArea(invites: d == nil) { tab = SettingsArea.uni.rawValue }
        case .uni:
            if let d { ServerAccountArea(d: d, part: .uni) } else { LocalUniArea(term: local?.term, reload: { await load() }) }
        case .look:
            if let d { ServerAccountArea(d: d, part: .look) } else { LocalLookArea() }
        case .modules:
            if let d {
                ModulesTab(d: d, reload: { await load() })
            } else if let local {
                ModulesTab(d: Loaded(s: local.s, courses: local.courses, mods: local.mods, log: [], cred: .null, term: local.term),
                           reload: { await load() }, withTests: false)
            }
        case .plan:
            if let s = d?.s ?? local?.s { PlanTab(s: s) }
        case .community:
            CommunitySettingsCard()                                      // Pseudonym, Lerngruppen, Sperrliste (Plus)
        case .help:
            LegalSupportCard().frame(maxWidth: 720, alignment: .leading)
        case .advanced:
            // "dev" und "diag" klappen ihren Teil gleich auf
            if let d {
                SettingsServerAdvancedTab(d: d, openDev: tab == "dev", openDiag: tab == "diag").id(tab)
            } else {
                LocalAdvancedTab(error: error, openDev: tab == "dev").id(tab == "dev")
            }
        }
    }

    /// Hinweis "Server nicht erreichbar" mit Weg zu "Erneut versuchen" und zum eigenen Server (Verbindung trennen)
    private func unreachableBanner(_ error: String) -> some View {
        // Hinweis in Warnfarbe statt einer weissen Karte mit farbiger Ueberschrift: Zustand auf einen Blick
        SettingsNotice("Eigener StudiNow-Server nicht erreichbar",
                       text: UFDevice.adapt("\(error)\nDie Einstellungen dieses iPads kannst du trotzdem ändern. Unter „Erweitert“ → „Eigener Server“ trennst du die Verbindung.")) {
            UFButton("Erneut versuchen", icon: "refresh", kind: .primary, size: .small) { Task { await load() } }
            UFButton("Eigener Server", icon: "layers", size: .small) { tab = "dev" }
        }
        .padding(.bottom, 19.2)
    }

    /// Laden scheiterte (Pruefbericht 561-565): mit geladenem Stand bleibt dieser sichtbar und ist als nicht
    /// aktualisiert gekennzeichnet; ohne Stand fehlen Module und Lernzeit, statt leer zu erscheinen
    private func staleBanner(_ error: String, loaded: Bool) -> some View {
        SettingsNotice(loaded ? "Nicht aktualisiert – angezeigt wird der zuletzt geladene Stand" : "Einstellungen ließen sich nicht laden",
                       text: error) {
            UFButton("Erneut versuchen", icon: "refresh", kind: .primary, size: .small) { Task { await load() } }
        }
        .padding(.bottom, 19.2)
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
    /// lokal: "Ältere Semester laden" (`OlderSemesters.Mode`, `SyncOrder` Stufe d); nil = nichts zu waehlen
    @State private var olderMode: OlderSemesters.Mode?
    @EnvironmentObject private var studip: StudIPSync
    @EnvironmentObject private var containers: ContainerManager
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.dynamicTypeSize) private var typeSize

    private var api: SettingsAPI { SettingsAPI(api: session.api, toast: toast, router: router) }

    var body: some View {
        let active = d.mods.filter { $0.i("active") != 0 }
        let tmin = d.s.i("test_minutes") ?? 30
        let loose = d.courses.filter { ($0["module_id"]?.isNull ?? true) && $0.s("id") != "__user__" }
        UFCard {
            UFCardHead(withTests ? "Module & Wochentests" : "Module") { UFBadge("\(active.count) aktiv", tone: .ok) }
            if withTests {
                (Text("Ein Modul fasst mehrere Stud.IP-Kurse zusammen (Vorlesung, Hörsaalübung, Gruppenübung …). \(Self.olderSemesters) Pro Modul und Lehrwoche entsteht höchstens ")
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
                // zu steht der erste Satz da, offen der ganze Text (17.11.2026)
                SettingsMore(summary: Self.localIntroShort, text: "\(Self.localIntroShort) Beim Abgleich ordnet StudiNow neue Kurse nach ihrem Titel einem Fach zu; hier legst du Module an und änderst die Zuordnung. \(Self.olderSemesters)",
                             identifier: "settings.modules.intro", size: 13.12)
                    .padding(.bottom, 5.6)
            }

            if let mode = olderMode {
                // "Ältere Semester laden: Automatisch / Nur WLAN / Aus" (Wunsch des Inhabers 05.11.2026)
                UFFlexWrap(gap: 9.6) {
                    Text("Ältere Semester laden").ufFont(13.6).foregroundStyle(UF.text2)
                    UFSegmented(options: OlderSemesters.Mode.allCases.map { ($0, $0.label) },
                                selection: Binding(get: { mode }, set: { v in setOlder(v) }))
                }
                .frame(minHeight: 44, alignment: .leading)
                Text(SyncOrder.olderFilesHint).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 9.6)
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
        .task {
            // nur lokal (die PC-Fassung kennt fruehere Semester nicht) und nur, wenn es welche gibt oder schon gewaehlt
            guard let api = session.api, api.isLocal, let o = try? await api.value("/api/older-semesters") else { return }
            if !(o["choice"]?.isNull ?? true) || !(o["semesters"]?.array ?? []).isEmpty {
                olderMode = o.s("mode").flatMap(OlderSemesters.Mode.init(rawValue:)) ?? OlderSemesters.defaultMode
            }
        }
    }

    /// Wahl aendern; nicht "Aus": Stufe (d) laedt die frueheren Semester gleich im Hintergrund (`OlderSemesterLoader`,
    /// nach Stromsparmodus und WLAN), neuestes zuerst
    private func setOlder(_ mode: OlderSemesters.Mode) {
        olderMode = mode
        Task {
            guard let api = session.api, await toast.attempt("Speichern", {
                _ = try await api.value("/api/older-semesters/mode", method: "POST", body: ["mode": .string(mode.rawValue)])
            }) else { return }
            if mode != .off { OlderSemesterLoader.shared.kick(containers) }
        }
    }

    /// .card.flat (padding .7rem .9rem): Kopfzeile klappt die Kurstabelle auf; inaktive Module blass (.muted)
    @ViewBuilder private func moduleRow(_ m: JSONValue) -> some View {
        let id = m.i("id") ?? 0
        let cs = d.courses.filter { $0.i("module_id") == id }
        let open = openMod == id
        let inactive = m.i("active") == 0
        let controls = Group {
            Text("\(cs.count) \(cs.count == 1 ? "Kurs" : "Kurse")").ufFont(13.12).foregroundStyle(UF.muted).fixedSize()
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
                .accessibilityLabel("Modul bearbeiten")
                .buttonStyle(UFButtonStyle(kind: .ghost, size: .small, iconOnly: true))
        }
        let name = UFWordWrapText(m.s("name") ?? "", size: 14.5, weight: 700).foregroundStyle(inactive ? UF.muted : UF.text)
        let chevron = UFIcon(open ? "chevron-down" : "chevron-right", size: 16).foregroundStyle(inactive ? UF.muted : UF.text)
        VStack(alignment: .leading, spacing: 0) {
            // .row.wrap mit b { flex: 1 }: der Name nimmt den freien Platz und bricht nur zwischen Woertern um; bei
            // Bedienungshilfen-Schriftgroessen steht er allein in der ersten Zeile, Schalter darunter (Audit 03.11.2026)
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 9.6) {
                            Circle().fill(Color(hex: m.s("color"))).frame(width: 12, height: 12)
                            name
                            chevron
                        }
                        UFFlexWrap(gap: 9.6, rowGap: 4) { controls }.padding(.leading, 21.6)
                    }
                } else {
                    HStack(spacing: 9.6) {
                        Circle().fill(Color(hex: m.s("color"))).frame(width: 12, height: 12)
                        name
                        controls
                        chevron
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { openMod = open ? nil : id }
            if open {
                CoursesTable(courses: cs, mods: d.mods, setKind: setKind, assign: assign, setActive: setActive)
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

    /// Erster Satz der Erklaerung ohne eigenen Server
    static let localIntroShort = "Ein Modul fasst die Stud.IP-Kurse eines Fachs zusammen (Vorlesung, Übung, Gruppenübung …)."
    /// Hinweis wie in der Web-App (c0721da): Semesterregel `Semesters`, Schalter je Kurs in der Kurstabelle
    static let olderSemesters = "Kurse aus früheren Semestern erkennt die App am Semester in Stud.IP und plant sie nicht ein; ihre Unterlagen bleiben in der Bibliothek."
    /// Hinweis unter "Dateien früherer Semester mitladen"
    static let olderFilesHint = SyncOrder.olderFilesHint

    /// Kurs eingeplant ja/nein: PATCH active, das lokale Backend merkt sich die eigene Entscheidung (active_custom)
    private func setActive(_ c: JSONValue, _ on: Bool) {
        guard let id = c.s("id") else { return }
        Task { _ = await api.send("/api/courses/\(id)", method: "PATCH", body: ["active": .number(on ? 1 : 0)],
                                  toast: on ? "Kurs eingeplant" : "Kurs nicht mehr eingeplant") }
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
            .ufHitArea()
        }
        .buttonStyle(.plain)
        .onAppear { value = on }
        .onChange(of: on) { _, v in value = v }
    }
}

/// table.tbl: Stud.IP-Kurs (mit Haken "eingeplant") / Semester / Art / Modul mit Auswahlfeldern; Kurse frueherer
/// Semester (active=0) grau wie `tr.muted` in der Web-App
private struct CoursesTable: View {
    let courses: [JSONValue]
    let mods: [JSONValue]
    let setKind: (JSONValue, String) -> Void
    let assign: (JSONValue, Int) -> Void
    let setActive: (JSONValue, Bool) -> Void
    private static let kinds = ["vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium", "labor", "seminar", "sonstiges"]

    /// Hinweis zum Haken wie das title-Attribut der Web-App
    static func activeHelp(_ c: JSONValue) -> String {
        c.i("active") == 0 ? "Früheres Semester – nicht eingeplant. Einschalten, wenn du den Kurs doch brauchst." : "Eingeplant"
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(["Stud.IP-Kurs", "Semester", "Art", "Modul"], id: \.self) { h in
                    Text(h).ufFont(12.8, 600).foregroundStyle(UF.muted)                 // Satzschreibung statt Versalien
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
                    let on = c.i("active") != 0
                    Button { setActive(c, !on) } label: {
                        HStack(spacing: 6.4) {
                            Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? UF.accent : UF.muted)
                            Text(c.s("title") ?? "").ufFont(13.76).foregroundStyle(on ? UF.text : UF.muted).multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.s("title") ?? "")
                    .accessibilityValue(on ? "eingeplant" : "nicht eingeplant")
                    .accessibilityHint(Self.activeHelp(c))
                    .help(Self.activeHelp(c))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    Text(c.s("semester") ?? "").ufFont(12.16).foregroundStyle(UF.muted).padding(8)
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

/// Nur mit Lernkalender (`LearnCalendar.enabled`, `SettingsArea.visible`): ohne ihn gibt es den Bereich nicht, also
/// auch nicht "Lernkombination", "Verfügbarkeit & Sperrzeiten" und "Fächer im Lernkalender".
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
                if session.api?.isLocal == true {                        // Fächer im Lernkalender (12.11.2026, nur lokal)
                    UFButton(PlanModulesText.button, icon: "calendar") { PlanModulesOpen.open(api: session.api, overlay: overlay, toast: toast) }
                }
            }
            // aktueller Stand als Liste aus Bezeichnung und Wert statt einer langen Zeile mit Mittelpunkten
            VStack(alignment: .leading, spacing: 0) {
                Text("Aktuell").ufFont(13.12, 600).foregroundStyle(UF.text2).padding(.bottom, 4)
                ForEach(Array(Self.current(s, free: free).enumerated()), id: \.offset) { i, row in
                    if i > 0 { SettingsDivider() }
                    SettingsValue(label: row.0, value: row.1).padding(.vertical, 8)
                }
            }
            .padding(.top, 19.2)
        }
    }

    /// Bezeichnung und Wert des aktuellen Stands (Faecher pro Tag, Lernzeit, Lernfenster, freie Tage, Fahrtzeit)
    static func current(_ s: JSONValue, free: [String]) -> [(String, String)] {
        [("Fächer pro Tag", "\(s.i("subjects_per_day") ?? 0)"),
         ("Lernzeit pro Tag", UFFmt.min(s.n("minutes_per_day"))),
         ("Lernfenster", "\(s.s("learn_start") ?? "")–\(s.s("learn_end") ?? "")"),
         ("Freie Tage", free.isEmpty ? "keine" : free.joined(separator: ", ")),
         ("Fahrtzeit", "\(s.i("travel_minutes") ?? 0) min")]
    }
}

// MARK: - Uni-Zugang und Darstellung am eigenen Server (nur Entwicklung)

/// Mit eigenem Server: die Teile der frueheren Seite "Zugang & Darstellung", die ueber den Server laufen.
/// `.uni`: Stud.IP-Zugang, Semester, Hochschule; `.look`: Anzeigename, Darstellung, Stift.
private struct ServerAccountArea: View {
    enum Part { case uni, look }

    let d: SettingsPage.Loaded
    let part: Part
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @AppStorage("theme") private var theme = UFThemeMode.standardRaw
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
        Group {
            switch part {
            case .uni:
                UFGridLayout(spacing: 16, minWidth: 340) {
                    credCard
                    termCard
                    UniversitySettingsCard()
                }
                .environment(\.ufFillsCell, true)
            case .look:
                VStack(alignment: .leading, spacing: 16) {
                    looksCard
                    if UFEditorAvailability.available { penCard }
                }
                .frame(maxWidth: 720, alignment: .leading)
            }
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
            .ufSheet(isPresented: $studipSheet) { SettingsSheet(close: { studipSheet = false }) { StudIPView() } }
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
                UFButton("Stud.IP direkt auf dem \(UFDevice.textName)", icon: "book", size: .small) { studipSheet = true }
            }
        }
    }

    /// Semester (Name, Beginn, Ende) wie im Web
    private var termCard: some View {
        UFCard {
            UFCardHead("Semester", icon: "calendar")
            HStack(alignment: .top, spacing: 9.6) {                           // .row, label.field { flex: 1 }
                UFField("Name") { UFTextInput(text: $termName) }
                UFField("Beginn") { UFDateField(iso: $termStart) }
                UFField("Ende") { UFDateField(iso: $termEnd) }
            }
            UFButton("Speichern", kind: .primary, size: .small) {
                Task { _ = await api.send("/api/terms", method: "PUT", body: ["name": .string(termName), "start": .string(termStart), "end": .string(termEnd)], toast: "Semester gespeichert", reload: false) }
            }
        }
    }

    /// eine Karte, darin Zeilen mit Titel und Bedienelement, getrennt durch Linien
    private var looksCard: some View {
        UFCard {
            SettingsRow("Anzeigename", icon: "user") {
                HStack(spacing: 9.6) {
                    UFTextInput("z. B. Alex M.", text: $userName).frame(maxWidth: 260)
                    UFButton("Speichern", size: .small) {
                        Task {
                            await api.put(["user_name": .string(userName)])
                            await shell.refresh()                                // Web: location.reload() fuer die Initialen
                        }
                    }
                }
            }
            .padding(.top, -12)
            SettingsDivider()
            SettingsRow("Darstellung", icon: "sun") {
                UFSegmented(options: [("auto", "Wie \(UFDevice.textName)"), ("light", "Hell"), ("dark", "Dunkel")], selection: $theme)
            }
            .padding(.bottom, -12)
        }
    }

    /// Stift und Schreibhand nur mit Editor (am iPhone keiner, Vorgabe 11.11.2026)
    private var penCard: some View {
        UFCard {
            SettingsRow(EditorPointer.settingsTitle(isMac: PDFEditorController.isMac), icon: "pen") {
                UFSelect(options: EditorPointer.settingsOptions(isMac: PDFEditorController.isMac),
                         selection: Binding(get: { pen }, set: { v in
                             pen = v
                             pencilOnly = v == "pen_only"                           // Editor auf dem iPad
                             Task { await api.put(["pen_input": .string(v)]) }
                         }))
            }
            .padding(.top, -12)
            SettingsDivider()
            SettingsRow("Schreibhand", icon: "hand", note: SettingsSections.handNote) {
                UFSegmented(options: [("right", "Rechtshänder"), ("left", "Linkshänder")],
                            selection: Binding(get: { hand }, set: { v in
                                hand = v
                                localHand = v                                     // Seite des Skripts in der geteilten Ansicht
                                Task { await api.put(["hand": .string(v)], toast: "Schreibhand gespeichert") }
                            }))
            }
            SettingsDivider()
            PencilFeelSettingsRows()                                     // Glättung, Formen erkennen (13.11.2026)
            SettingsDivider()
            EditorToolbarPlacementRow()                                  // Werkzeugleiste oben/unten/schwebend (12.11.2026)
            .padding(.bottom, -12)
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

/// Bereich "Konto & Tarif": Tarif und Konto, ohne eigenen Server dazu "Freunde einladen". Oben der Hinweis mit dem
/// Weg zum Uni-Zugang, solange Stud.IP nicht verbunden ist (`SettingsUniAccessHint`).
private struct SettingsAccountArea: View {
    /// "Freunde einladen" (docs/EINLADUNGEN.md) und der Hinweis nur ohne eigenen Server
    var invites = true
    let openUni: () -> Void
    @Environment(\.ufStudoraAccount) private var studoraAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if invites { SettingsUniAccessHint(open: openUni) }
            AppAccountCards()                                            // "Konto": Apple-ID und StudiNow-Konto in einer Karte
            if invites, StudoraAccountLink.available, let studoraAccount {
                InviteCard(link: studoraAccount)                         // Freunde einladen (docs/EINLADUNGEN.md)
            }
        }
    }
}

/// Karten "Tarif" und "Konto" (Mit Apple angemeldet, StudiNow-Konto, Konto loeschen). Der Tarif steht vorn: er wird
/// oefter gebraucht, und die Konto-Karte ist lang. "Hochschule" steht seit 17.11.2026 unter "Uni-Zugang & Abgleich",
/// "Rechtliches & Support" unter "Hilfe & Rechtliches" (`LegalSupportCard`).
private struct AppAccountCards: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufSwitchPlan) private var switchPlan
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @ObservedObject private var ent = Entitlements.shared
    @State private var plans = false

    /// kaufbare Tarife, in V1 "StudiNow Free oder StudiNow Plus" (Namen aus plans.json, `UFPlanCatalog.sellable`)
    static var planNames: String {
        let names = UFPlanCatalog.sellable.map(\.name)
        return names.dropLast().joined(separator: ", ") + " oder " + names.last!
    }

    var body: some View {
        UFGridLayout(spacing: 16, minWidth: 340) {
            planCard
            accountCard
        }
        .environment(\.ufFillsCell, true)
        #if DEBUG
        .ufSheet(isPresented: $plans) { SettingsSheet(close: { plans = false }) { SubscriptionView() } }
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
                    Text("Die Anmeldung wurde in diesem Debug-Build übersprungen.").ufFont(13.12).foregroundStyle(UF.muted)
                } else {
                    // Bezeichnung und Wert in zwei Spalten statt "Name: …" in einer Zeile
                    SettingsValue(label: "Name", value: a?.name ?? "nicht freigegeben", muted: a?.name == nil)
                    SettingsValue(label: "E-Mail", value: a?.email ?? "nicht freigegeben", muted: a?.email == nil)
                }
                // Rufname fuer "Hallo Ahmad – lass uns gemeinsam lernen." auf der Uebersicht (je Container, nur auf dem
                // iPad; leer: der Vorname aus der Anmeldung, `UFGreeting`)
                RufnameField().padding(.top, 4.8)
                // was das Konto ist: hinter "Mehr dazu" (Text unveraendert)
                SettingsMore(text: Self.accountText, identifier: "settings.account.about", size: 13.12, title: "Mehr zum Konto")
                    .padding(.top, 2.4)
            }
            // eine Karte "Konto" (12.11.2026): darunter das StudiNow-Konto beim Dienst mit derselben Apple-ID
            if StudoraAccountLink.available, let studoraAccount {
                SettingsDivider().padding(.vertical, 12)
                StudoraAccountCard(link: studoraAccount)
            }
            // Loeschen abgesetzt am Kartenende wie bei "Hochschule"
            SettingsDangerZone {
                UFButton("Konto löschen", icon: "trash", kind: .danger, size: .small) { overlay.modal { DeleteAccountDialog() } }
            }
        }
    }

    /// Was das Konto ist (eine Apple-ID = ein StudiNow-Konto = ein Abo, 12.11.2026)
    static let accountText = UFDevice.adapt("Mit deiner Apple-ID bist du in StudiNow und beim StudiNow-Dienst angemeldet – auf jedem Gerät mit derselben Apple-ID dasselbe Konto. Dateien aus Stud.IP und deine Uni-Anmeldungen bleiben auf diesem iPad.")

    /// Rufname (Einstellungen -> Konto): ein Feld, gespeichert je Container beim Tippen (`Rufname.save`)
    struct RufnameField: View {
        @State private var name = Rufname.current() ?? ""

        var body: some View {
            VStack(alignment: .leading, spacing: 4.8) {
                Text("Rufname").ufFont(13.12, 600).foregroundStyle(UF.text)
                UFTextField("Wie sollen wir dich nennen?", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.rufname")
                Text(UFDevice.adapt("Für die Begrüßung auf der Übersicht. Leer: dein Vorname aus der Anmeldung. Bleibt auf diesem iPad."))
                    .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: name) { _, now in Rufname.save(now) }
        }
    }

    /// Platz fuer den Tarif; Inhalt (aktueller Tarif, Verwalten, Wiederherstellen) baut das Abo-Paket
    private var planCard: some View {
        UFCard {
            UFCardHead("Tarif", icon: "star") {
                // waehrend der Probe ohne Kauf "Probe: noch n Tage alles frei", sonst der Tarif
                if !ent.loading { UFBadge(ent.statusLabel, tone: ent.plan == .free ? .neutral : .ok) }
            }
            Text(canSwitchPlan
                 ? "\(Self.planNames) wählen, Abo verwalten und Käufe wiederherstellen."
                 : "Die Auswahl zwischen \(Self.planNames) folgt hier.")
                .ufFont(13.12).foregroundStyle(UF.muted)
            Text(UFTrialTexts.perAppleID).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4.8)
            // Credits der StudiNow-KI (nur mit Konto beim Dienst und Stand aus GET /api/entitlements)
            if let studoraAccount { StudoraCreditsRow(link: studoraAccount) }
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

/// Bereich "Hilfe & Rechtliches". Rechtliches und Support: die oeffentlichen Seiten auf studinow.app (UFLegalLinks)
/// oeffnen in Safari, die Support-Adresse in Mail; dieselben Adressen wie in App Store Connect. Texte und Ziele
/// unveraendert, nur der Ort (vorher zwischen "Hochschule" und "Freunde einladen").
struct LegalSupportCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        UFCard {
            UFCardHead("Rechtliches & Support", icon: "life-buoy")
            Text(UFLegalLinks.settingsIntro).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            UFFlexWrap(gap: 9.6) {
                UFButton("Support", icon: "life-buoy", kind: .primary, size: .small) { openURL(UFLegalLinks.support) }
                UFButton("E-Mail schreiben", size: .small) { openURL(UFLegalLinks.supportMail) }
                UFButton("Nutzungsbedingungen", size: .small) { openURL(UFLegalLinks.terms) }
                UFButton("Datenschutzerklärung", size: .small) { openURL(UFLegalLinks.privacy) }
                UFButton("Impressum", size: .small) { openURL(UFLegalLinks.imprint) }
            }
            .padding(.top, 9.6)
        }
    }
}

/// Zeile "Credits" auf der Tarif-Karte (04.11.2026, docs/ABO-SYSTEM.md Abschnitt 6a): der echte Stand beider Toepfe
/// vom Dienst ("Diesen Monat: x von 100 · Gekauft: y", 15.11.2026) mit einem ehrlichen Satz dazu und dem Eintrag
/// "Credits kaufen"; ohne Konto beim Dienst oder ohne Stand bleibt sie weg. Beobachtet den Anschluss,
/// damit eine berechnete Antwort den Rest sofort nachzieht.
struct StudoraCreditsRow: View {
    @ObservedObject var link: StudoraAccountLink

    /// Wie viele Credits es gibt, ohne Centbetrag (Entscheidung des Inhabers 11.11.2026: „das müssen Nutzer nicht wissen“);
    /// die Tarife und ihren Rahmen zeigt "Tarif wechseln" darunter
    static let explanation = "Pro AI hat 100 Credits im Monat, die Probewoche 25, andere Tarife keine; nicht Verbrauchtes verfällt zum Monatsanfang. Gekaufte Credits verfallen nicht; mit Plus reichen sie für Fragen an die KI. Welcher Tarif was enthält, steht unter „Tarif wechseln“."

    var body: some View {
        if let c = link.credits, let value = AICost.balanceLine(c, trial: link.planStatus?.trialActive ?? false, labelled: false) {
            VStack(alignment: .leading, spacing: 4.8) {
                SettingsValue(label: "Credits", value: value)
                Text(Self.explanation).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                // "Credits kaufen" (nur, wenn das Konto kaufen darf) bzw. der Hinweis auf ruhende gekaufte Credits
                CreditShopEntry(link: link)
            }
            .padding(.top, 7.2)
            .accessibilityIdentifier("settings.credits")
        }
    }
}

/// Texte der Rueckfrage "Konto loeschen": die Server-PIN gibt es nur im Debug-Build mit eigenem Server
/// (`Session.ownServerAvailable`), im Release kein Hinweis auf PC, Server oder PIN. V1 loest keine Apple-Token ein
/// (kein Server), darum kann die App die Verknuepfung "Mit Apple anmelden" nicht selbst widerrufen; der Nutzer loest
/// sie in den Einstellungen des iPads.
enum DeleteAccountText {
    static func removed(ownServer: Bool) -> String {
        "Deine Anmeldung mit Apple, die Kontodaten und alle Schlüsselbund-Einträge von StudiNow (Stud.IP-Sitzung, "
            + (ownServer ? "Server-PIN, " : "") + (UFReleaseUniversities.isShipped(.hildesheim) ? "Learnweb-Schlüssel, " : "") + UFDevice.adapt("gemerkte Hochschul-Passwörter) werden von diesem iPad entfernt. Danach siehst du wieder die Begrüßung. ")
            + "Was iOS selbst gesichert hat, bleibt unter „Passwörter“."
    }

    static let appleID = UFDevice.adapt("Die Verknüpfung „Mit Apple anmelden“ widerruft StudiNow beim Löschen auch bei Apple. Prüfen oder selbst lösen kannst du sie in den Einstellungen des iPads: dein Name → Anmelden und Sicherheit → Mit Apple anmelden → StudiNow.")

    /// Seit 12.11.2026 (eine Anmeldung fuer alles): "Konto löschen" loescht zuerst das Konto beim StudiNow-Dienst
    /// (`AccountDeletion`, Dienst: sofort gesperrt, nach 30 Tagen endgueltig, Widerruf bei Apple), dann alles auf dem iPad.
    /// Vorher (P35-01) blieb das Konto beim Dienst bestehen und liess sich nur in der Karte StudiNow-Konto loeschen.
    static let service = "Dein StudiNow-Konto beim StudiNow-Dienst wird ebenfalls gelöscht – auf allen Geräten, unter Windows und im Web: sofort gesperrt, nach 30 Tagen endgültig mit allem, was dorthin abgeglichen wurde."

    /// Ohne Anmeldung beim Dienst auf diesem Geraet (z. B. offline beim Start): ehrlich sagen, was dann gilt
    static let serviceUnknown = "Auf diesem Gerät bist du gerade nicht beim StudiNow-Dienst angemeldet. Hast du dort ein Konto (z. B. von einem anderen Gerät), lösche es dort oder schreib an support@studinow.app."

    /// Saetze unter der Rueckfrage, die vom Stand abhaengen (StudiNow-Konto angemeldet)
    static func shows(serviceSignedIn: Bool) -> [String] {
        [appleID] + [serviceSignedIn ? service : serviceUnknown]
    }

    /// Nur mit iCloud-Container im Build (Community ueber CloudKit, docs/release/DATENSCHUTZ.md Abschnitt 8b): was in der
    /// oeffentlichen Datenbank liegt, entfernt "Konto loeschen" auf dem iPad nicht von selbst - ehrlich sagen, wie es geht
    static let community = "Was du in der Community veröffentlicht hast (Lösungen, Kommentare, Korrekturen), liegt verschlüsselt in Apples iCloud und bleibt unter deinem Pseudonym, bis du es zurückziehst. Zieh es vorher unter „Meine geteilten Lösungen“ zurück oder schreib an support@studinow.app – dann löschen wir es für dich."
}

/// Rueckfrage "Konto loeschen" (Richtlinie 5.1.1(v)) mit Hinweis auf die Abo-Verwaltung bei Apple. Seit 12.11.2026
/// zuerst das Konto beim StudiNow-Dienst (`AccountDeletion`), dann alles auf dem iPad; scheitert der Dienst, bleibt alles
/// stehen und der Dialog sagt warum (Passwort, Netz) – mit "Nur auf diesem iPad löschen" als bewusstem Ausweg.
private struct DeleteAccountDialog: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var busy = false
    @State private var servicePassword = ""
    @State private var problem: AccountDeletion.Outcome?

    var body: some View {
        UFDialog("Konto löschen?", icon: "trash") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(DeleteAccountText.removed(ownServer: Session.ownServerAvailable))
                Text(UFDevice.adapt("Ebenso werden alle Daten deines Kontos auf diesem iPad gelöscht, für jede Hochschule: heruntergeladene Dateien, eigene Dokumente, Notizen, Lernplan, Einstellungen und die Anmeldungen in den Webansichten. Das lässt sich nicht rückgängig machen."))
                    .font(.uf(13.12, 600)).foregroundStyle(UF.bad)
                Text("Ein Abo wird dadurch nicht gekündigt. Abos kündigst du bei Apple:").font(.uf(13.12, 700)).foregroundStyle(UF.text)
                Link("Abos verwalten", destination: AccountStore.manageSubscriptionsURL)
                    .ufFont(13.12, 600).foregroundStyle(UF.accentText)
                ForEach(DeleteAccountText.shows(serviceSignedIn: containers.account.user != nil), id: \.self) { Text($0) }
                if SolutionSharing.community.isConnected { Text(DeleteAccountText.community) }
                if let problem { ServiceDeletionProblem(outcome: problem, password: $servicePassword) }
                ContainerSyncGate { syncing in
                    if syncing { ContainerSyncNotice() }
                }
            }
            .ufFont(13.12).foregroundStyle(UF.text2)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { close() }
            if problem != nil {
                UFButton(UFDevice.adapt("Nur auf diesem iPad löschen"), kind: .ghost) { start(onlyThisDevice: true) }
                    .disabled(busy)
            }
            // gesperrt, solange ein Abgleich laeuft (deleteAllData haelt ihn sonst an und wartet auf ihn)
            ContainerSyncGate { syncing in
                UFButton(problem == nil ? "Konto löschen" : "Erneut versuchen", icon: "trash", kind: .danger) { start(onlyThisDevice: false) }
                    .disabled(busy || syncing)
            }
        }
    }

    private func start(onlyThisDevice: Bool) {
        busy = true
        Task {
            let steps = account.account.map {
                AccountStore.deletionSteps(containers: containers, session: session, userID: $0.userID)
            } ?? []
            let out = await AccountDeletion.run(service: containers.account, password: servicePassword.isEmpty ? nil : servicePassword,
                                                onlyThisDevice: onlyThisDevice) {
                // RootView zeigt danach die Begruessung
                await account.deleteAccount(also: steps) {
                    overlay.closeAll()
                    router.go(.dashboard)
                }
            }
            if out != .done {
                problem = out
                busy = false
            }
        }
    }
}

/// Warum das Konto beim Dienst nicht geloescht wurde; mit Passwortfeld, wenn das Konto eins hat
private struct ServiceDeletionProblem: View {
    let outcome: AccountDeletion.Outcome
    @Binding var password: String

    var body: some View {
        if case .serviceFailed(let message, let needsPassword) = outcome {
            VStack(alignment: .leading, spacing: 7.2) {
                Text(message).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("delete.serviceProblem")
                if needsPassword {
                    UFField(AccountDeletion.passwordLabel) {
                        UFTextField("Passwort", text: $password, secure: true).textContentType(.password)
                    }
                }
            }
        }
    }
}

/// Bereich "Uni-Zugang & Abgleich" ohne Server: Uni-Zugang, Stud.IP und QIS (LUH) bzw. Learnweb und LSF (Uni
/// Hildesheim), Abgleich im Hintergrund, Semester (lokales Backend), Erinnerungen und zuletzt die Hochschule
/// (Wechsel, Daten loeschen: selten gebraucht)
private struct LocalUniArea: View {
    /// aktives Semester aus /api/terms; nil, solange nicht geladen
    var term: JSONValue?
    var reload: () async -> Void = {}
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hildesheim) private var hildesheim

    var body: some View {
        UFGridLayout(spacing: 16, minWidth: 340) {
            UniAutoLoginCard()                                       // Uni-Zugang speichern (gemeinsam oder je Portal), automatisch anmelden
            if studip.offersStudIP {
                LUHSourcesCard()                                     // Stud.IP und QIS der LUH (Views/QISViews.swift)
                UniMailSourcesCard()                                 // Uni-Mail und Uni-Kalender (SOGo der LUH)
            } else {
                HildesheimSourcesCard()                              // Learnweb und LSF der Uni Hildesheim
                HsHSourcesCard()                                     // Moodle und Campusmanagement der HsH
            }
            BackgroundSyncCard()                                     // Abgleich im Hintergrund (S8)
            SyncNotificationsCard()                                  // Mitteilungen bei Neuem (17.11.2026)
            if let term { UFCard { SemesterFields(term: term, reload: reload) } }
            if !studip.offersStudIP && hildesheim != nil {
                StudyProgramSettingsCard(university: "Universität Hildesheim")   // Studiengang (14.11.2026)
            }
            DueReminderCard()                                        // Erinnerungen an Abgaben und Prüfungen
            UniversitySettingsCard()                                 // Hochschule: Wechsel, Daten loeschen
        }
        .environment(\.ufFillsCell, true)
    }
}

/// Bereich "Darstellung & Stift" ohne Server (Einstellungen dieses Geraets): Darstellung; mit Editor (iPad, Mac) dazu
/// die Karte mit Stift bzw. Zeiger, Schreibhand, Glättung, Formen und Werkzeugleiste
private struct LocalLookArea: View {
    @AppStorage("theme") private var theme = UFThemeMode.standardRaw
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true
    @AppStorage("uniflow.hand") private var hand = "right"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UFCard {
                SettingsRow("Darstellung", icon: "sun") {
                    UFSegmented(options: [("auto", "Wie \(UFDevice.textName)"), ("light", "Hell"), ("dark", "Dunkel")], selection: $theme)
                }
                .padding(.vertical, -12)
            }
            if UFEditorAvailability.available {
                UFCard {
                    SettingsRow(EditorPointer.settingsTitle(isMac: PDFEditorController.isMac), icon: "pen") {
                        UFSelect(options: EditorPointer.settingsOptions(isMac: PDFEditorController.isMac),
                                 selection: Binding(get: { pencilOnly ? "pen_only" : "all" }, set: { pencilOnly = $0 == "pen_only" }))
                    }
                    .padding(.top, -12)
                    SettingsDivider()
                    SettingsRow("Schreibhand", icon: "hand", note: SettingsSections.handNote) {
                        UFSegmented(options: [("right", "Rechtshänder"), ("left", "Linkshänder")], selection: $hand)
                    }
                    SettingsDivider()
                    PencilFeelSettingsRows()                         // Glättung, Formen erkennen (13.11.2026)
                    SettingsDivider()
                    EditorToolbarPlacementRow()                      // Werkzeugleiste oben/unten/schwebend (12.11.2026)
                    .padding(.bottom, -12)
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

/// Texte in den Einstellungen (die Namen und Saetze der Bereiche stehen bei `SettingsArea`)
enum SettingsSections {
    /// Erklaerung unter "Schreibhand" (unveraendert)
    static let handNote = "Seitenleiste und Skript in der geteilten Ansicht liegen auf der Seite der freien Hand; die Stiftpalette lässt sich an jeden Rand ziehen."
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
                    UFCardHead("Eigener StudiNow-Server", icon: "layers") {
                        error == nil ? UFBadge("verbunden", tone: .ok) : UFBadge("nicht erreichbar", tone: .warn)
                    }
                    VStack(alignment: .leading, spacing: 7.2) {
                        (Text("Server: ").font(.uf(13.12, 700)) + Text(api.base.absoluteString))
                        Text(UFDevice.adapt("Die Daten kommen von deinem StudiNow-Server. Die PIN liegt im Schlüsselbund dieses iPads. Nach „Verbindung trennen“ kommen die Daten wieder vom iPad selbst; Notizen beider Quellen bleiben getrennt erhalten."))
                            .foregroundStyle(UF.muted)
                    }
                    .ufFont(13.12).foregroundStyle(UF.text)
                    UFFlexWrap(gap: 9.6) {
                        UFButton("Verbindung trennen", icon: "log-out", kind: .danger, size: .small) {
                            Task { if await overlay.confirm("Verbindung zum StudiNow-Server trennen?") { session.disconnect() } }
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
            UFCardHead("Mit eigenem StudiNow-Server verbinden", icon: "layers") { UFBadge("Entwicklung", tone: .neutral) }
            Text(UFDevice.adapt("Nur für die Entwicklung: verbindet dieses iPad mit deinem StudiNow-Server im WLAN. Am PC Start-iPad.cmd starten; Adresse und PIN stehen in der Web-App unter Einstellungen → Zugang & Darstellung → Auf dem iPad benutzen."))
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

/// "Erweitert" ohne Server: "Eigenes ChatGPT" ueber den eigenen OpenAI-Schluessel (OpenAIKeyCard, in jedem Tarif,
/// 07.11.2026), dazu KI ueber das ChatGPT-Abo nur mit `ChatGPTLink.isEnabled` (solange OpenAI die Anmeldung nicht
/// freigibt, gibt es dazu keine Karte - auch keinen Hinweis "bald verfügbar", App-Pruefung 07.11.2026: nichts
/// versprechen, Richtlinie 2.1) und der Schalter "Vorab einordnen" (Erklaerungsspeicher); keine Demo-Inhalte (nur fuer
/// Pruefer, Views/DemoViews.swift)
private struct LocalAdvancedTab: View {
    /// gespeicherter Server antwortet nicht (fuer "Eigener Server")
    var error: String?
    /// Sprungziel "dev": "Eigener Server" gleich aufgeklappt
    var openDev = false
    @Environment(\.ufChatGPTLink) private var chatgpt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if ChatGPTLink.available, let chatgpt {
                if OpenAIKeyLink.isOffered { OpenAIKeyCard(link: chatgpt.apiKey) }      // „Eigenes ChatGPT“ aus (11.11.2026)
                // Anmelden mit dem ChatGPT-Abo erst nach der Freigabe durch OpenAI (`ChatGPTLink.isEnabled`); bis dahin
                // keine Karte
                if ChatGPTLink.isEnabled { ChatGPTCard(link: chatgpt) }
                DocIndexPrewarmCard()
            }
            DevelopmentFold(error: error, open: openDev)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

/// "Eigener Server (Entwicklung)" zugeklappt am Ende von "Erweitert" (vorher ein eigener Reiter "Entwicklung"
/// zwischen den Alltagseinstellungen); nur in Debug-Builds (`Session.ownServerAvailable`)
private struct DevelopmentFold: View {
    var error: String?
    var open = false

    static let title = "Eigener Server (Entwicklung)"
    static let sub = UFDevice.adapt("Nur für die Entwicklung: dieses iPad mit dem eigenen StudiNow-Server verbinden.")

    var body: some View {
        if Session.ownServerAvailable {
            SettingsFold(Self.title, icon: "layers", sub: Self.sub, identifier: "settings.fold.dev", open: open) {
                DevelopmentTab(error: error)
            }
        }
    }
}

/// KI-Bereich: "Vorab einordnen" (Entscheidung des Inhabers 04.11.2026, docs/ERKLAERUNGSSPEICHER-2026-11-04.md).
/// Standard: nach dem Abgleich nur Zusammenfassung und Begriffe (Dokument-Index). "Alles": dazu Erklaerungen und
/// Loesungen fuer alle mit derselben Datei - mit ehrlichem Kostenhinweis. Gilt nur im WLAN und beim Laden.
struct DocIndexPrewarmCard: View {
    @AppStorage(DocIndexPrewarmSetting.key) private var raw = DocIndexPrewarmSetting.defaultRaw

    private var level: Binding<DocIndexPrewarmLevel> {
        Binding(get: { DocIndexPrewarmSetting.level(raw: raw) }, set: { raw = $0.rawValue })
    }

    var body: some View {
        UFCard {
            UFCardHead("Vorab einordnen", icon: "book")
            Text("Nach dem Abgleich ordnet StudiNow bis zu drei Dateien der laufenden Woche vorab ein – nur im WLAN und beim Laden, einmal für alle mit derselben Datei.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            UFSegmented(options: DocIndexPrewarmLevel.allCases.map { (value: $0, label: DocIndexPrewarmSetting.label($0)) }, selection: level)
                .padding(.top, 8)
                .accessibilityIdentifier("docIndex.prewarmLevel")
            Text(DocIndexPrewarmSetting.costNote)
                .ufFont(12.5).foregroundStyle(level.wrappedValue == .full ? UF.bad : UF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityIdentifier("docIndex.prewarmCost")
        }
    }
}

/// "Erweitert" am eigenen Server (nur Entwicklung): Sync-Protokoll, Diagnose, PDF-Anzeige testen und der eigene
/// Server, alles zugeklappt. Nicht privat, damit ein Test den Schalter "Lernkalender … auffüllen" pruefen kann.
struct SettingsServerAdvancedTab: View {
    let d: SettingsPage.Loaded
    /// Sprungziele "dev" und "diag": der Teil ist gleich aufgeklappt
    var openDev = false
    var openDiag = false
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufWindowWidth) private var windowWidth
    @AppStorage("theme") private var theme = UFThemeMode.standardRaw
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
        // selten Gebrauchtes zugeklappt (17.11.2026): Sync-Protokoll, Diagnose, PDF-Anzeige testen, eigener Server
        VStack(alignment: .leading, spacing: 12) {
            SettingsFold("Sync-Protokoll", icon: "sync", sub: "Die letzten Abgleiche mit Zeit und Ergebnis.", identifier: "settings.fold.synclog") {
            UFCard {
                UFCardHead("Sync-Protokoll", icon: "sync") {
                    // nur mit Lernkalender (`LearnCalendar.enabled`); der gespeicherte Wert bleibt unberuehrt
                    if LearnCalendar.enabled {
                    Button {
                        autoPlan.toggle()
                        let v = autoPlan
                        Task { await SettingsAPI(api: session.api, toast: toast, router: router).put(["auto_plan": .bool(v)]) }
                    } label: {
                        HStack(spacing: 4.8) {
                            Image(systemName: autoPlan ? "checkmark.square.fill" : "square").foregroundStyle(autoPlan ? UF.accent : UF.muted)
                            Text("Lernkalender nach dem Sync automatisch auffüllen").ufFont(13.12).foregroundStyle(UF.text)
                        }
                        .ufHitArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.autoPlan")
                    }
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
            }
            SettingsFold("Diagnose", icon: "info", sub: "Gerät, Fenster, App-Version und Zustand der Daten – zum Kopieren für den Support.",
                         identifier: "settings.fold.diag", open: openDiag) {
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
                    .padding(.top, 13.12)
                    .textSelection(.enabled)
            }
            }
            SettingsFold("PDF-Anzeige testen", icon: "file-text", sub: "Prüft, ob dieses Gerät eine PDF aus der Bibliothek zeichnen kann.",
                         identifier: "settings.fold.pdftest") {
            UFCard {
                UFCardHead("PDF-Anzeige testen", icon: "file-text") {
                    UFButton("Test starten", kind: .primary, size: .small) { Task { await runPDFTest() } }.disabled(testing)
                }
                Text(UFDevice.adapt("Lädt eine PDF aus deiner Bibliothek, liest sie mit PDFKit und zeichnet Seite 1 – genau wie der Editor. Wenn hier ein Bild erscheint, funktioniert die Anzeige auf diesem iPad."))
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
            DevelopmentFold(open: openDev)
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
            "Gerät: \(StudoraAccountLink.deviceName), \(AccountDevice.systemLabel(version: UIDevice.current.systemVersion, isMac: ProcessInfo.processInfo.isiOSAppOnMac, isPhone: UFDevice.isPhone))",
            "Fenster: \(Int(windowWidth))×\(Int(UIScreen.main.bounds.height)), Pixelverhältnis \(Self.js(scale))",
            "Design: \(theme)",
            "Adresse: \(Diagnostics.address(session.api?.base))",
            "App-Version: \(diag?.appVersion ?? "…")",
        ]
        if let d = diag { lines += d.reportLines }
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
