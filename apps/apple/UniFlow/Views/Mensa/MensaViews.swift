import SwiftUI
import UniFlowCore

// Mensa (05.11.2026, docs/MENSA-2026-11-05.md): Seite "Mensa" mit Auswahl der Mensa (Standard der Hochschule, gemerkt,
// Favoriten), Heute/Morgen/Woche, Gerichte als Karten mit dem Preis der eigenen Gruppe, Filter (vegan, vegetarisch, ohne
// Schwein, Allergene meiden), Oeffnungszeiten und Quelle; Karte "Heute in der Mensa" auf der Uebersicht. Daten aus
// GET /api/mensa/canteens und /api/mensa/menu (lokal: Mensa/LocalMensa.swift holt direkt beim Studentenwerk, mit Cache;
// am eigenen PC app/mensa_api.py). Frei in jedem Tarif. Gleiche Regeln wie mensa-logic.js im Web.

// MARK: - Einstellungen (auf dem Geraet)

struct MensaPrefs: Codable, Equatable {
    var canteen: String?
    var favorites: [String] = []
    /// student, employee oder guest
    var role = "student"
    var vegan = false
    var vegetarian = false
    var noPork = false
    var allergens: [String] = []
    /// Reihenfolge der Liste: line, price, kcal, protein (`Mensa.sort`)
    var sort = "line"

    static let key = "mensa.prefs"

    static func load(_ d: UserDefaults = .standard) -> MensaPrefs {
        guard let data = d.data(forKey: key), var p = try? JSONDecoder().decode(MensaPrefs.self, from: data) else { return MensaPrefs() }
        if !["student", "employee", "guest"].contains(p.role) { p.role = "student" }
        return p
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }

    var filter: Mensa.Filter { Mensa.Filter(vegan: vegan, vegetarian: vegetarian, noPork: noPork, allergens: Set(allergens)) }

    /// gemerkt (wenn es die Mensa gibt), sonst erster Favorit, sonst Standard der Hochschule
    func chosen(in list: JSONValue) -> String {
        let ids = Set(list.list("canteens").compactMap { $0.s("id") })
        if let c = canteen, ids.contains(c) { return c }
        return favorites.first(where: ids.contains) ?? list.s("default") ?? "hauptmensa"
    }

    mutating func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
    }

    /// "vegan · ohne Schwein · ohne Gluten"
    func summary(names: [String: String]) -> String {
        var parts: [String] = []
        if vegan { parts.append("vegan") } else if vegetarian { parts.append("vegetarisch") }
        if noPork { parts.append("ohne Schwein") }
        if !allergens.isEmpty { parts.append("ohne " + allergens.map { names[$0] ?? $0 }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

extension MensaPrefs {
    /// fehlende Schluessel (aeltere Fassung) mit Standardwerten statt alles zu verwerfen
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canteen = try c.decodeIfPresent(String.self, forKey: .canteen)
        favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? []
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "student"
        vegan = try c.decodeIfPresent(Bool.self, forKey: .vegan) ?? false
        vegetarian = try c.decodeIfPresent(Bool.self, forKey: .vegetarian) ?? false
        noPork = try c.decodeIfPresent(Bool.self, forKey: .noPork) ?? false
        allergens = try c.decodeIfPresent([String].self, forKey: .allergens) ?? []
        sort = try c.decodeIfPresent(String.self, forKey: .sort) ?? "line"
        if !Mensa.sorts.contains(sort) { sort = "line" }
    }
}

// MARK: - Reine Regeln der Oberflaeche (MensaAppTests)

enum MensaUI {
    static let roles: [(value: String, label: String)] = [("student", "Studierende"), ("employee", "Bedienstete"), ("guest", "Gäste")]
    static let labelNames = ["vegan": "vegan", "vegetarisch": "vegetarisch", "fisch": "Fisch", "fleisch": "Fleisch",
                             "gefluegel": "Geflügel", "schwein": "Schwein", "rind": "Rind", "alkohol": "Alkohol"]

    enum Mode: String, CaseIterable { case today, tomorrow, week }

    static let noNutrition = "Keine Nährwertangaben vom Studentenwerk"
    static let sortLabels: [String: String] = ["line": "Menülinie", "price": "Preis (günstig zuerst)", "kcal": "Kalorien (wenig zuerst)",
                                               "protein": "Eiweiß (viel zuerst)"]
    static let nutrients: [(key: String, label: String)] = [("fat", "Fett"), ("saturated_fat", "davon gesättigte Fettsäuren"),
        ("carbohydrates", "Kohlenhydrate"), ("sugar", "davon Zucker"), ("fiber", "Ballaststoffe"), ("protein", "Eiweiß"), ("salt", "Salz")]

    /// Sortierungen, fuer die es Daten gibt (Kalorien/Eiweiss nur mit Naehrwerten), wie `availableSorts` im Web
    static func sorts(for meals: [JSONValue]) -> [String] {
        func has(_ k: String) -> Bool { meals.contains { $0["nutrition"]?[k]?.double != nil } }
        return Mensa.sorts.filter { $0 == "line" || $0 == "price" || ($0 == "kcal" && has("energy_kcal")) || ($0 == "protein" && has("protein")) }
    }

    /// "35,2" / "1.354" wie toLocaleString("de-DE")
    static func num(_ v: Double, digits: Int = 1) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func basisLabel(_ meal: JSONValue) -> String { meal["nutrition"]?.s("basis") == "100g" ? "pro 100 g" : "pro Portion" }

    /// Zeilen der Naehrwerte wie `nutritionRows` im Web: Brennwert "615 kJ / 147 kcal", dann Gramm; leer ohne Angaben
    static func nutritionRows(_ meal: JSONValue) -> [(label: String, value: String, sub: Bool)] {
        guard let n = meal["nutrition"], n.object != nil else { return [] }
        var rows: [(String, String, Bool)] = []
        let energy = [n["energy_kj"]?.double.map { "\(num($0, digits: 0)) kJ" }, n["energy_kcal"]?.double.map { "\(num($0, digits: 0)) kcal" }]
            .compactMap { $0 }
        if !energy.isEmpty { rows.append(("Brennwert", energy.joined(separator: " / "), false)) }
        for (k, label) in nutrients { if let v = n[k]?.double { rows.append((label, "\(num(v)) g", label.hasPrefix("davon"))) } }
        return rows.map { (label: $0.0, value: $0.1, sub: $0.2) }
    }

    /// "811 kcal · 53,6 g Eiweiß" bzw. "93 kcal/100 g · 3,3 g Eiweiß/100 g"
    static func nutritionShort(_ meal: JSONValue) -> String {
        guard let n = meal["nutrition"], let kcal = n["energy_kcal"]?.double else { return "" }
        let per = n.s("basis") == "100g" ? "/100 g" : ""
        return "\(num(kcal, digits: 0)) kcal\(per)" + (n["protein"]?.double.map { " · \(num($0)) g Eiweiß\(per)" } ?? "")
    }

    static func climateRows(_ meal: JSONValue) -> [String] {
        guard let c = meal["climate"], c.object != nil else { return [] }
        var out: [String] = []
        if c["klimateller"]?.bool == true { out.append("KlimaTeller") }
        if let g = c["co2_g"]?.double { out.append("CO₂e \(num(g, digits: 0)) g pro Portion") }
        if let r = c.s("rating"), !r.isEmpty { out.append("CO₂-Bewertung \(r)") }
        return out
    }

    static func price(_ v: Double?) -> String {
        guard let v else { return "–" }
        return String(format: "%.2f €", v).replacingOccurrences(of: ".", with: ",")
    }

    static func statusText(_ status: String) -> String {
        status == "closed" ? "Geschlossen – an diesem Tag gibt es kein Essen." : "Für diesen Tag gibt es noch keinen Speiseplan."
    }

    /// Kennzeichen ohne Doppelungen: "Fleisch" nur ohne Tierart, "vegetarisch" nur ohne "vegan"
    static func shownLabels(_ meal: JSONValue) -> [String] {
        let l = meal.list("labels").compactMap(\.string)
        return l.filter { k in
            if k == "fleisch" { return !l.contains { ["gefluegel", "schwein", "rind"].contains($0) } }
            if k == "vegetarisch" { return !l.contains("vegan") }
            return true
        }
    }

    static func tone(_ label: String) -> UFTone {
        switch label {
        case "vegan", "vegetarisch": return .ok
        case "fisch": return .info
        case "alkohol": return .bad
        default: return .warn
        }
    }

    static func isWeekend(_ iso: String) -> Bool {
        guard let d = Fmt.date(iso) else { return false }
        let wd = Fmt.calendar.component(.weekday, from: d)
        return wd == 1 || wd == 7
    }

    /// Karte "Heute in der Mensa": drei Hauptgerichte; nichts am Wochenende, an geschlossenen Tagen und ohne Plan
    static func dashboardMeals(menu: JSONValue?, today: String, prefs: MensaPrefs) -> [JSONValue] {
        guard let menu, !isWeekend(today), let day = menu.list("days").first(where: { $0.s("date") == today }),
              day.s("status") == "open" else { return [] }
        return Mensa.top(day.list("meals"), 3, prefs.filter)
    }

    /// Auswahlliste: Favoriten, deine Hochschule, weitere in der Naehe, andere Orte
    static func groups(_ list: JSONValue, favorites: [String]) -> [(title: String, items: [JSONValue])] {
        let all = list.list("canteens"), fav = Set(favorites), region = list.s("region")
        let g: [(String, [JSONValue])] = [
            ("Favoriten", all.filter { fav.contains($0.s("id") ?? "") }),
            ("Deine Hochschule", all.filter { !fav.contains($0.s("id") ?? "") && $0["own"]?.bool == true }),
            ("Weitere in der Nähe", all.filter { !fav.contains($0.s("id") ?? "") && $0["own"]?.bool != true && $0.s("region") == region }),
            ("Andere Orte", all.filter { !fav.contains($0.s("id") ?? "") && $0["own"]?.bool != true && $0.s("region") != region }),
        ]
        return g.filter { !$0.1.isEmpty }.map { (title: $0.0, items: $0.1) }
    }

    /// "Mo 9.11.", "Heute", "Morgen"
    static func dayLabel(_ iso: String, today: String) -> String {
        if iso == today { return "Heute" }
        if iso == Mensa.addDays(today, 1) { return "Morgen" }
        guard let d = Fmt.date(iso) else { return iso }
        let wd = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][Fmt.calendar.component(.weekday, from: d) - 1]
        let c = Fmt.calendar.dateComponents([.day, .month], from: d)
        return "\(wd) \(c.day ?? 0).\(c.month ?? 0)."
    }

    /// VoiceOver einer Gerichtkarte: "Chili con Carne, 3,80 €, Rind, Menülinie Fleisch & Meer"
    static func accessibility(_ meal: JSONValue, role: String) -> String {
        var parts = [meal.s("name") ?? "", price(Mensa.price(meal, role: role))]
        let l = shownLabels(meal).map { labelNames[$0] ?? $0 }
        if !l.isEmpty { parts.append(l.joined(separator: ", ")) }
        if let c = meal.s("category"), !c.isEmpty { parts.append("Menülinie \(c)") }
        if meal.s("time") == "abend" { parts.append("abends") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Seite

struct MensaPage: View {
    @EnvironmentObject private var session: Session
    @Environment(\.ufWindowWidth) private var windowWidth
    /// iPhone (docs/IPHONE-2026-11-04.md): Mensa-Wahl und Tage in voller Breite, Filter als Blatt, eine Spalte
    @Environment(\.ufCompact) private var compact
    @Environment(\.openURL) private var openURL
    @State private var list: JSONValue?
    @State private var menu: JSONValue?
    @State private var error: String?
    @State private var mode: MensaUI.Mode = .today
    @State private var prefs = MensaPrefs.load()
    @State private var loading = false
    @State private var detail: MensaMealItem?
    /// kompakt: Filter, Preisgruppe und Sortierung als Blatt von unten
    @State private var showFilters = false

    private var today: String { UFFmt.todayISO() }
    private var cid: String { list.map { prefs.chosen(in: $0) } ?? prefs.canteen ?? "hauptmensa" }
    private var start: String { mode == .tomorrow ? Mensa.addDays(today, 1) : today }
    private var token: String { "\(cid)|\(mode.rawValue)|\(today)|\(session.api?.base.absoluteString ?? "")" }

    var body: some View {
        UFContent(maxWidth: 1120) {
            UFPageHead("Mensa", sub: subtitle)
            if let list {
                if compact {
                    compactControls(list)
                } else {
                    controls(list)
                    filters(list)
                }
            }
            if let msg = menu?.s("message") {
                HStack(spacing: 8) { UFIcon("alert", size: 16); Text(msg).ufFont(14) }
                    .foregroundStyle(UF.warnText).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.warnSoft))
                    .padding(.bottom, 12).accessibilityElement(children: .combine)
            }
            if let error {
                UFCard {
                    UFEmpty(icon: "alert", text: error) { UFButton("Erneut versuchen", icon: "refresh") { Task { await load() } } }
                }
            } else if let menu {
                if windowWidth > 900 {
                    HStack(alignment: .top, spacing: 16) {
                        days(menu).frame(maxWidth: .infinity, alignment: .topLeading)
                        info(menu).frame(width: 280)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) { days(menu); info(menu) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
        .task(id: token) { await load() }
        .ufReload { await load() }
        .sheet(item: $detail) { item in
            MensaMealDetail(meal: item.meal, canteen: menu?["canteen"]?.s("name"), source: menu?["source"]?.s("attribution"))
                .ufHalfSheet(when: compact)                 // iPhone: von unten, halb (Preise, Naehrwerte) und ganz
        }
        .sheet(isPresented: $showFilters) {
            if let list { filterSheet(list).ufHalfSheet(when: compact) }
        }
        .accessibilityIdentifier("mensa.page")
    }

    private var subtitle: String {
        let name = list?.list("canteens").first { $0.s("id") == cid }?.s("name") ?? "Mensa"
        if mode == .week { return "\(name) · diese Woche" }
        return "\(name) · \(MensaUI.dayLabel(start, today: today))"
    }

    private func load() async {
        guard let api = session.api else { error = "Keine Verbindung zur App-Datenquelle."; return }
        loading = true
        defer { loading = false }
        do {
            if list == nil { list = try await api.value("/api/mensa/canteens") }
            let c = list.map { prefs.chosen(in: $0) } ?? "hauptmensa"
            menu = try await api.value("/api/mensa/menu?canteen=\(c)&date=\(start)&days=\(mode == .week ? 7 : 1)")
            error = nil
        } catch {
            self.error = "Der Speiseplan konnte nicht geladen werden. \((error as? LocalizedError)?.errorDescription ?? "")"
        }
    }

    private func update(_ change: (inout MensaPrefs) -> Void) {
        change(&prefs)
        prefs.save()
    }

    // MARK: Bedienung

    @ViewBuilder private func controls(_ list: JSONValue) -> some View {
        UFFlexWrap(gap: 10) {
            canteenMenu(list)

            favoriteButton

            UFSegmented(options: [(MensaUI.Mode.today, "Heute"), (.tomorrow, "Morgen"), (.week, "Woche")], selection: $mode)
                .accessibilityIdentifier("mensa.mode")

            HStack(spacing: 6) {
                Text("Preis für").ufFont(13).foregroundStyle(UF.muted)
                UFSelect(options: MensaUI.roles, selection: Binding(get: { prefs.role }, set: { r in update { $0.role = r } }))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mensa.role")

            let sorts = MensaUI.sorts(for: menu?.list("days").flatMap { $0.list("meals") } ?? [])
            HStack(spacing: 6) {
                Text("Sortieren").ufFont(13).foregroundStyle(UF.muted)
                UFSelect(options: sorts.map { (value: $0, label: MensaUI.sortLabels[$0] ?? $0) },
                         selection: Binding(get: { sorts.contains(prefs.sort) ? prefs.sort : "line" }, set: { v in update { $0.sort = v } }))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mensa.sort")
        }
        .padding(.bottom, 10)
    }

    /// Mensa waehlen (Favoriten zuerst, dann je Standort); kompakt in voller Breite
    private func canteenMenu(_ list: JSONValue) -> some View {
        let name = list.list("canteens").first { $0.s("id") == cid }?.s("name")
        return Menu {
            ForEach(MensaUI.groups(list, favorites: prefs.favorites), id: \.title) { g in
                Section(g.title) {
                    ForEach(g.items, id: \.self) { c in
                        Button { update { $0.canteen = c.s("id") } } label: {
                            if c.s("id") == cid { Label(c.s("name") ?? "", systemImage: "checkmark") } else { Text(c.s("name") ?? "") }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                UFIcon("utensils", size: 16)
                let title = Text(name ?? "Mensa wählen").ufFont(14.5, 600).lineLimit(2)
                if compact { title.frame(maxWidth: .infinity, alignment: .leading) } else { title }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(UF.text)
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(UF.lineStrong, lineWidth: 1))
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Mensa: \(name ?? "")")
        .accessibilityHint("Andere Mensa wählen")
        .accessibilityIdentifier("mensa.picker")
    }

    private var favoriteButton: some View {
        let fav = prefs.favorites.contains(cid)
        return Button { update { $0.toggleFavorite(cid) } } label: {
            Image(systemName: fav ? "star.fill" : "star").font(.system(size: 18)).foregroundStyle(fav ? UF.warn : UF.text2)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fav ? "Aus den Favoriten entfernen" : "Zu den Favoriten")
        .accessibilityAddTraits(fav ? .isSelected : [])
        .accessibilityIdentifier("mensa.favorite")
    }

    // MARK: Bedienung kompakt (iPhone)

    /// iPhone: Mensa-Wahl mit Stern, darunter Heute/Morgen/Woche in voller Breite, dann "Filter" (Blatt) mit Zusammenfassung
    @ViewBuilder private func compactControls(_ list: JSONValue) -> some View {
        let names = Dictionary(list.list("allergens").compactMap { a in a.s("key").map { ($0, a.s("name") ?? $0) } }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                canteenMenu(list)
                favoriteButton
            }
            dayPicker
            HStack(spacing: 10) {
                Button { showFilters = true } label: {
                    let n = [prefs.vegan, prefs.vegetarian, prefs.noPork].filter { $0 }.count + prefs.allergens.count
                    HStack(spacing: 6) {
                        UFIcon("filter", size: 15)
                        Text(n > 0 ? "Filter (\(n))" : "Filter").ufFont(14, 600)
                    }
                    .foregroundStyle(n > 0 ? UF.accentText : UF.text)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(n > 0 ? UF.accentSoft : UF.surface))
                    .overlay(Capsule().strokeBorder(n > 0 ? Color.clear : UF.line, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Filter, Preis und Sortierung")
                .accessibilityIdentifier("mensa.filters")
                Text(prefs.filter.isEmpty ? "Preis: \(MensaUI.roles.first { $0.value == prefs.role }?.label ?? "")" : prefs.summary(names: names))
                    .ufFont(12.8).foregroundStyle(UF.muted).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mensa.filters.summary")
            }
        }
        .padding(.bottom, 14)
    }

    /// Heute / Morgen / Woche: drei gleich breite Felder, mindestens 44 pt hoch
    private var dayPicker: some View {
        let options: [(MensaUI.Mode, String)] = [(.today, "Heute"), (.tomorrow, "Morgen"), (.week, "Woche")]
        return HStack(spacing: 2) {
            ForEach(options, id: \.0) { m, label in
                let on = mode == m
                Button { mode = m } label: {
                    Text(label).ufFont(14, on ? 650 : 500)
                        .foregroundStyle(on ? UF.text : UF.text2)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: UF.rSm - 2).fill(on ? UF.surface : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("mensa.mode.\(m.rawValue)")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mensa.mode")
    }

    /// Blatt "Filter" (iPhone): Kennzeichen, Allergene, Preisgruppe, Sortierung; wirkt sofort, "Fertig" schliesst
    private func filterSheet(_ list: JSONValue) -> some View {
        let sorts = MensaUI.sorts(for: menu?.list("days").flatMap { $0.list("meals") } ?? [])
        return NavigationStack {
            Form {
                Section("Essen") {
                    Toggle("vegan", isOn: Binding(get: { prefs.vegan }, set: { on in update { $0.vegan = on; if on { $0.vegetarian = false } } }))
                        .accessibilityIdentifier("mensa.sheet.vegan")
                    Toggle("vegetarisch", isOn: Binding(get: { prefs.vegetarian }, set: { on in update { $0.vegetarian = on; if on { $0.vegan = false } } }))
                        .accessibilityIdentifier("mensa.sheet.vegetarian")
                    Toggle("ohne Schwein", isOn: Binding(get: { prefs.noPork }, set: { on in update { $0.noPork = on } }))
                        .accessibilityIdentifier("mensa.sheet.nopork")
                }
                Section("Preis und Reihenfolge") {
                    Picker("Preis für", selection: Binding(get: { prefs.role }, set: { r in update { $0.role = r } })) {
                        ForEach(MensaUI.roles, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .accessibilityIdentifier("mensa.sheet.role")
                    Picker("Sortieren", selection: Binding(get: { sorts.contains(prefs.sort) ? prefs.sort : "line" }, set: { v in update { $0.sort = v } })) {
                        ForEach(sorts, id: \.self) { Text(MensaUI.sortLabels[$0] ?? $0).tag($0) }
                    }
                    .accessibilityIdentifier("mensa.sheet.sort")
                }
                Section("Allergene meiden") {
                    ForEach(list.list("allergens"), id: \.self) { a in
                        let k = a.s("key") ?? ""
                        Toggle(a.s("name") ?? k, isOn: Binding(get: { prefs.allergens.contains(k) }, set: { on in
                            update { p in p.allergens.removeAll { $0 == k }; if on { p.allergens.append(k) } }
                        }))
                    }
                }
                if !prefs.filter.isEmpty {
                    Section {
                        Button("Filter zurücksetzen", role: .destructive) {
                            update { $0.vegan = false; $0.vegetarian = false; $0.noPork = false; $0.allergens = [] }
                        }
                        .accessibilityIdentifier("mensa.sheet.reset")
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showFilters = false }.accessibilityIdentifier("mensa.sheet.done") } }
        }
        .accessibilityIdentifier("mensa.filterSheet")
    }

    @ViewBuilder private func filters(_ list: JSONValue) -> some View {
        let names = Dictionary(list.list("allergens").compactMap { a in a.s("key").map { ($0, a.s("name") ?? $0) } }, uniquingKeysWith: { a, _ in a })
        UFFlexWrap(gap: 6) {
            UFChip(text: "vegan", on: prefs.vegan) { update { $0.vegan.toggle(); if $0.vegan { $0.vegetarian = false } } }
                .accessibilityAddTraits(prefs.vegan ? .isSelected : []).accessibilityIdentifier("mensa.filter.vegan")
            UFChip(text: "vegetarisch", on: prefs.vegetarian) { update { $0.vegetarian.toggle(); if $0.vegetarian { $0.vegan = false } } }
                .accessibilityAddTraits(prefs.vegetarian ? .isSelected : []).accessibilityIdentifier("mensa.filter.vegetarian")
            UFChip(text: "ohne Schwein", on: prefs.noPork) { update { $0.noPork.toggle() } }
                .accessibilityAddTraits(prefs.noPork ? .isSelected : []).accessibilityIdentifier("mensa.filter.nopork")
            Menu {
                ForEach(list.list("allergens"), id: \.self) { a in
                    let k = a.s("key") ?? ""
                    Toggle(a.s("name") ?? k, isOn: Binding(get: { prefs.allergens.contains(k) }, set: { on in
                        update { p in p.allergens.removeAll { $0 == k }; if on { p.allergens.append(k) } }
                    }))
                }
            } label: {
                let n = prefs.allergens.count
                Text(n > 0 ? "Allergene meiden (\(n))" : "Allergene meiden").ufFont(12.8, n > 0 ? 600 : 400)
                    .foregroundStyle(n > 0 ? UF.accentText : UF.text2)
                    .padding(.vertical, 5).padding(.horizontal, 11)
                    .background(Capsule().fill(n > 0 ? UF.accentSoft : UF.surface))
                    .overlay(Capsule().strokeBorder(n > 0 ? Color.clear : UF.line, lineWidth: 1))
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("mensa.filter.allergens")
            if !prefs.filter.isEmpty {
                Text("Filter: " + prefs.summary(names: names)).ufFont(12.8).foregroundStyle(UF.muted)
                    .frame(minHeight: 44)
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: Tage und Gerichte

    @ViewBuilder private func days(_ menu: JSONValue) -> some View {
        let ds = menu.list("days")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ds, id: \.self) { d in
                if mode == .week {
                    Text("\(MensaUI.dayLabel(d.s("date") ?? "", today: today)) · \(UFFmt.longToday(Fmt.date(d.s("date")) ?? Date()))")
                        .ufFont(17, 650).foregroundStyle(UF.text).padding(.top, 10).accessibilityAddTraits(.isHeader)
                }
                day(d)
            }
        }
    }

    @ViewBuilder private func day(_ d: JSONValue) -> some View {
        if d.s("status") != "open" {
            UFCard(flat: true) {
                HStack(spacing: 8) { UFIcon("clock", size: 16); Text(MensaUI.statusText(d.s("status") ?? "none")).ufFont(14.5) }
                    .foregroundStyle(UF.text2)
            }
        } else {
            let all = d.list("meals")
            let shown = Mensa.sort(Mensa.filter(all, prefs.filter), by: prefs.sort, role: prefs.role)
            let main = shown.filter { $0["main"]?.bool == true }, side = shown.filter { $0["main"]?.bool != true }
            if shown.isEmpty {
                UFCard(flat: true) { HStack(spacing: 8) { UFIcon("filter", size: 16); Text("Kein Gericht passt zum Filter.").ufFont(14.5) }.foregroundStyle(UF.text2) }
            } else {
                grid(main, min: 240)
                if !side.isEmpty {
                    Text("Beilagen, Salate und Desserts").ufFont(14, 600).foregroundStyle(UF.text2).padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                    grid(side, min: 200)
                }
                if all.count > shown.count {
                    let h = all.count - shown.count
                    Text(h == 1 ? "1 Gericht durch den Filter ausgeblendet." : "\(h) Gerichte durch den Filter ausgeblendet.")
                        .ufFont(12.8).foregroundStyle(UF.muted)
                }
            }
        }
    }

    @ViewBuilder private func grid(_ meals: [JSONValue], min: CGFloat) -> some View {
        if compact {
            // iPhone: eine Spalte, Karten untereinander
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(meals, id: \.self) { m in MensaMealCard(meal: m, role: prefs.role) { detail = MensaMealItem(meal: m) } }
            }
        } else {
            gridColumns(meals, min: min)
        }
    }

    private func gridColumns(_ meals: [JSONValue], min: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: windowWidth < 520 ? 260 : min), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(meals, id: \.self) { m in MensaMealCard(meal: m, role: prefs.role) { detail = MensaMealItem(meal: m) } }
        }
    }

    @ViewBuilder private func info(_ menu: JSONValue) -> some View {
        let c = menu["canteen"] ?? .null
        UFCard {
            UFCardHead("Öffnungszeiten", icon: "clock")
            ForEach(c.list("hours"), id: \.self) { h in
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.s("label") ?? "").ufFont(12.8).foregroundStyle(UF.muted)
                    ForEach(h.list("lines").compactMap(\.string), id: \.self) { Text($0).ufFont(14.5).foregroundStyle(UF.text) }
                }
                .padding(.bottom, 8)
                .accessibilityElement(children: .combine)
            }
            if let a = c.s("address") { Text(a).ufFont(12.8).foregroundStyle(UF.muted).padding(.bottom, 6) }
            Text(sourceLine(menu)).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
            if let u = c.s("url").flatMap(URL.init(string:)) {
                Button("Seite der Mensa öffnen") { openURL(u) }.ufFont(13.5, 600).foregroundStyle(UF.accentText)
                    .frame(minHeight: 44).buttonStyle(.plain)
            }
        }
    }

    private func sourceLine(_ menu: JSONValue) -> String {
        var s = menu["source"]?.s("attribution") ?? ""
        if let at = menu.s("fetched_at"), at.count >= 16 { s += " · Stand \(at.dropFirst(11).prefix(5)) Uhr" }
        return s + ". Angaben ohne Gewähr; verbindlich ist der Aushang vor Ort."
    }
}

/// Gericht fuer das Blatt mit allen Angaben
struct MensaMealItem: Identifiable {
    let meal: JSONValue
    var id: String { meal.s("id") ?? meal.s("name") ?? "" }
}

/// Eine Gerichtkarte: immer sichtbar, was es gibt (Menuelinie, Preis der eigenen Gruppe, Name, Kennzeichen, kcal);
/// Antippen oeffnet alle Angaben (`MensaMealDetail`)
struct MensaMealCard: View {
    let meal: JSONValue
    let role: String
    let open: () -> Void

    /// VoiceOver: Gericht, Preis, Kennzeichen, Linie und Kurzangaben
    private var spoken: String {
        let short = MensaUI.nutritionShort(meal)
        return MensaUI.accessibility(meal, role: role) + (short.isEmpty ? "" : ", " + short)
    }

    var body: some View {
        let main = meal["main"]?.bool == true
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(((meal.s("category") ?? "") + (meal.s("time") == "abend" ? " · abends" : "")).uppercased())
                        .ufFont(11.5, 600, em: 0.03).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(MensaUI.price(Mensa.price(meal, role: role))).ufFont(15, 700).foregroundStyle(UF.text).fixedSize()
                }
                Text(meal.s("name") ?? "").ufFont(main ? 16 : 15, main ? 600 : 500).foregroundStyle(UF.text)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                let labels = MensaUI.shownLabels(meal)
                if !labels.isEmpty {
                    UFFlexWrap(gap: 4) { ForEach(labels, id: \.self) { UFBadge(MensaUI.labelNames[$0] ?? $0, tone: MensaUI.tone($0)) } }
                }
                let short = MensaUI.nutritionShort(meal)
                if !short.isEmpty { Text(short).ufFont(12.8).foregroundStyle(UF.text2) }
                HStack(spacing: 3) { Text("Alle Angaben").ufFont(12.8, 500); UFIcon("chevron-right", size: 12) }.foregroundStyle(UF.accentText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(main ? UF.surface : UF.surface2))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: UF.r))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Alle Angaben zeigen")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { open() }          // zusammengefasstes Element: Aktivieren oeffnet das Blatt
        .accessibilityIdentifier("mensa.meal")
    }
}

/// Alle Angaben zu einem Gericht wie auf der Seite der Mensa: Preise (alle Gruppen), Bestandteile und Beilagen,
/// Naehrwerte (je Portion bzw. je 100 g) oder "Keine Nährwertangaben vom Studentenwerk", Kennzeichnungen (mit Klima),
/// Allergene und Zusatzstoffe mit vollen Namen
struct MensaMealDetail: View {
    let meal: JSONValue
    var canteen: String?
    var source: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meal.s("name") ?? "").ufFont(22, 700).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text([meal.s("category"), meal.s("time") == "abend" ? "abends" : nil, canteen].compactMap { $0 }.filter { !$0.isEmpty }
                            .joined(separator: " · ")).ufFont(13.5).foregroundStyle(UF.muted)
                    }
                    section("Preise") {
                        ForEach(MensaUI.roles, id: \.value) { r in row(r.label, MensaUI.price(Mensa.price(meal, role: r.value))) }
                    }
                    let comps = meal.list("components").compactMap(\.string)
                    if !comps.isEmpty { section("Bestandteile und Beilagen") { bullets(comps) } }
                    section("Nährwerte") {
                        let rows = MensaUI.nutritionRows(meal)
                        if rows.isEmpty {
                            Text(MensaUI.noNutrition).ufFont(14.5).foregroundStyle(UF.text2)
                        } else {
                            Text("\(MensaUI.basisLabel(meal)) (Angabe des Studentenwerks)").ufFont(12.8).foregroundStyle(UF.muted)
                            ForEach(rows.indices, id: \.self) { i in row(rows[i].label, rows[i].value, sub: rows[i].sub) }
                        }
                    }
                    let labels = meal.list("labels").compactMap(\.string).filter { $0 != "vegetarisch" || !meal.list("labels").contains("vegan") }
                        .map { MensaUI.labelNames[$0] ?? $0 }
                    let marks = labels + MensaUI.climateRows(meal) + meal.list("notes").compactMap(\.string)
                    section("Kennzeichnungen") { marks.isEmpty ? AnyView(empty("Keine Kennzeichnungen angegeben.")) : AnyView(bullets(marks)) }
                    let all = meal.list("allergens").compactMap { $0.s("name") }
                    section("Allergene") { all.isEmpty ? AnyView(empty("Keine Allergene angegeben.")) : AnyView(bullets(all)) }
                    let add = meal.list("additives").compactMap { $0.s("name") }
                    section("Zusatzstoffe") { add.isEmpty ? AnyView(empty("Keine Zusatzstoffe angegeben.")) : AnyView(bullets(add)) }
                    Text((source ?? "") + ". Angaben ohne Gewähr; verbindlich ist der Aushang vor Ort.")
                        .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(UF.bg)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.accessibilityIdentifier("mensa.detail.done") } }
        }
        .accessibilityIdentifier("mensa.detail")
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).ufFont(16, 650).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
    }

    private func row(_ label: String, _ value: String, sub: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).ufFont(14.5).foregroundStyle(sub ? UF.text2 : UF.text).padding(.leading, sub ? 14 : 0)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value).ufFont(14.5, 650).foregroundStyle(UF.text).fixedSize()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { x in
                HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(UF.muted); Text(x).ufFont(14.5).foregroundStyle(UF.text) }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func empty(_ text: String) -> some View { Text(text).ufFont(14.5).foregroundStyle(UF.text2) }
}

// MARK: - Karte auf der Uebersicht

/// "Heute in der Mensa": drei Hauptgerichte der gewaehlten Mensa mit Preis; am Wochenende, an geschlossenen Tagen und
/// ohne Plan keine Karte (kein Platz). Antippen oeffnet die Seite.
struct MensaTodayCard: View {
    let api: APIClient?
    var token: String = ""
    @State private var name = ""
    @State private var meals: [JSONValue] = []
    @State private var stale = false
    @EnvironmentObject private var router: UFRouter
    /// iPhone: "Alle Gerichte" in voller Breite unter den Gerichten statt neben dem Titel
    @Environment(\.ufCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            if !meals.isEmpty {
                let role = MensaPrefs.load().role
                UFCard {
                    if compact {
                        UFCardHead("Heute in der Mensa", icon: "utensils", wrap: true)
                    } else {
                        UFCardHead("Heute in der Mensa", icon: "utensils") {
                            UFButton("Alle Gerichte", size: .small) { router.go(.mensa) }
                        }
                    }
                    Text(name + (stale ? " · letzter Stand" : "")).ufFont(12.8).foregroundStyle(UF.muted).padding(.bottom, 4)
                    ForEach(meals, id: \.self) { m in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(m.s("name") ?? "").ufFont(14.5, 500).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            if let l = MensaUI.shownLabels(m).first(where: { $0 == "vegan" || $0 == "vegetarisch" }) {
                                UFBadge(MensaUI.labelNames[l] ?? l, tone: .ok)
                            }
                            Text(MensaUI.price(Mensa.price(m, role: role))).ufFont(14.5, 700).foregroundStyle(UF.text).fixedSize()
                        }
                        .padding(.vertical, 6)
                        .ufBorderBottom(m != meals.last)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(MensaUI.accessibility(m, role: role))
                    }
                    if compact {
                        UFWideButton("Alle Gerichte", icon: "utensils") { router.go(.mensa) }
                            .padding(.top, 8)
                            .accessibilityIdentifier("mensa.dashboard.all")
                    }
                }
                .accessibilityIdentifier("mensa.dashboard")
                .padding(.bottom, 19.2)
            }
        }
        .task(id: token) { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api else { meals = []; return }
        let today = UFFmt.todayISO()
        if MensaUI.isWeekend(today) { meals = []; return }
        let prefs = MensaPrefs.load()
        guard let list = try? await api.value("/api/mensa/canteens") else { meals = []; return }
        let cid = prefs.chosen(in: list)
        let menu = try? await api.value("/api/mensa/menu?canteen=\(cid)&date=\(today)&days=1")
        name = menu?["canteen"]?.s("name") ?? ""
        stale = menu?["stale"]?.bool == true
        meals = MensaUI.dashboardMeals(menu: menu, today: today, prefs: prefs)
    }
}
