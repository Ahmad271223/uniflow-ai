import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Auftrag des Inhabers 12.11.2026: "Alle Funktionen, die in Plus und Pro AI enthalten sind, sollen bei Free ein Schloss
/// haben, und alle, die in Pro AI enthalten sind und Plus nicht hat, bei Plus ein Schloss." Dazu (selber Tag): "mach den
/// Pencil-Kit-Strich kleiner und fest oben oder unten, man kann aussuchen, oder weiterhin schwebend, in Einstellung".
///
/// Geprueft:
/// - je Funktion und Tarif (Free, Plus, Pro AI): sichtbar mit Schloss, Text "ab Plus"/"ab Pro AI", VoiceOver
///   "gesperrt, ab Plus"; Pro AI ohne Schloss; was es nicht gibt (V2, Community ohne iCloud) bleibt unsichtbar
/// - Seitenleiste: "Tests & Wiederholung", "Karteikarten" mit Schloss; Antippen oeffnet die Seite und die Tarifwahl mit
///   dem noetigen Tarif ("Mehr mit StudiNow Plus" bzw. "Mehr mit StudiNow Pro AI")
/// - Editor: ohne Plus die Werkzeugleiste mit Schloss (statt keiner), "KI fragen" mit Schloss ohne KI; Antippen
///   oeffnet die Tarifwahl; Pro AI ohne Schloss
/// - Lage der Leiste: oben fest, unten fest, schwebend (Apples Palette), Wechsel im offenen Dokument, Hoehe 44 pt,
///   jede Trefferflaeche mindestens 44 x 44 pt; schwebend ohne Plus: Hinweis mit Schloss statt Palette
///
/// Bildschirmfotos mit `TEST_RUNNER_UF_LOCK_SHOTS=<Ordner>` (Seitenleiste und Editor je Free/Plus, alle drei Lagen).
@MainActor
final class LockVisibilityAppTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        UserDefaults.standard.removeObject(forKey: EditorToolbarPlacement.key)
        // erster Abruf von StoreKit abwarten: er setzte den Tarif sonst nach `setPlanForTesting` zurueck auf Free
        let ent = Entitlements.shared
        for _ in 0..<200 where ent.loading { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        Entitlements.shared.setPlanForTesting(.free)
        UserDefaults.standard.removeObject(forKey: EditorToolbarPlacement.key)
        try await super.tearDown()
    }

    // MARK: Regeln (ohne Oberflaeche)

    /// Jede Funktion aus Plus bzw. Pro AI hat in jedem kleineren Tarif genau das Schloss ihres Tarifs; Pro AI hat keines
    func testEveryPaidFeatureHasTheLockOfItsPlanInLowerPlans() {
        for f in UFFeature.allCases where !f.isV2 {
            for plan in UFPlan.allCases {
                let lock = UFLock.plan(f, plan: plan)
                if plan >= f.minimumPlan {
                    XCTAssertNil(lock, "\(f.title) in \(plan.name): frei")
                } else {
                    XCTAssertEqual(lock, f.minimumPlan, "\(f.title) in \(plan.name): Schloss des eigenen Tarifs")
                }
            }
            XCTAssertNil(UFLock.plan(f, plan: .proAI), "Pro AI: kein Schloss (\(f.title))")
        }
        // Free: alles aus Plus und Pro AI mit Schloss; Plus: genau das, was nur Pro AI hat
        let freeLocks = UFFeature.allCases.filter { !$0.isV2 && UFLock.plan($0, plan: .free) != nil }
        XCTAssertEqual(Set(freeLocks), Set(UFFeature.allCases.filter { !$0.isV2 && $0.minimumPlan > .free }))
        let plusLocks = UFFeature.allCases.filter { !$0.isV2 && UFLock.plan($0, plan: .plus) != nil }
        XCTAssertEqual(Set(plusLocks), Set(UFFeature.allCases.filter { $0.minimumPlan == .proAI }))
        // V2 (StudiNow-Editor) bleibt unsichtbar statt "kaufbar" (App Review 3.1.2)
        XCTAssertEqual(UFFeatureMatrix.access(.uniflowEditor, plan: .free), .comingSoon)
        XCTAssertNil(UFLock.plan(.uniflowEditor, plan: .free))
        // Ausnahme: Lernplan automatisch mit eigenem ChatGPT auch in Free (kein Schloss)
        XCTAssertNil(UFLock.plan(.autoPlan, plan: .free, ownChatGPT: true))
    }

    /// Einheitliche Texte: Schloss "ab Plus"/"ab Pro AI", VoiceOver "gesperrt, ab Plus", Menuepunkt "Titel (ab Plus)"
    func testLockTextsAreTheSameEverywhere() {
        XCTAssertEqual(UFLock.badge(.plus), "ab Plus")
        XCTAssertEqual(UFLock.badge(.proAI), "ab Pro AI")
        XCTAssertEqual(UFLock.accessibilityValue(.plus), "gesperrt, ab Plus")
        XCTAssertEqual(UFLock.accessibilityValue(.proAI), "gesperrt, ab Pro AI")
        XCTAssertEqual(UFLock.label("Geteilt", .plus), "Geteilt (ab Plus)")
        XCTAssertEqual(DocumentView.lockedLabel("Geteilt", .locked(.plus)), UFLock.label("Geteilt", .plus))
        XCTAssertEqual(UFLock.hint, "Öffnet die Tarifwahl.")
        XCTAssertEqual(EditorLockedToolbar.title(.plus), "Schreiben mit Plus")
        // KI-Stellen: mit verbundener KI frei (eigenes ChatGPT in jedem Tarif), sonst bis Plus "ab Pro AI"
        XCTAssertEqual(UFLock.ai(plan: .free, aiEnabled: false), .proAI)
        XCTAssertEqual(UFLock.ai(plan: .plus, aiEnabled: false), .proAI)
        XCTAssertNil(UFLock.ai(plan: .proAI, aiEnabled: false), "Pro AI ohne Anmeldung: kein Tarif-Schloss")
        XCTAssertNil(UFLock.ai(plan: .free, aiEnabled: true))
        XCTAssertNil(UFLock.ai(plan: .plus, aiEnabled: false, offerHidden: true), "Pro AI nicht zu kaufen: kein Schloss")
        XCTAssertEqual(UFLock.ai(.weeklyTests, plan: .plus, aiEnabled: false), .proAI)
    }

    /// Menue: Free sieht "Tests & Wiederholung" (ab Pro AI), "Karteikarten" und "Community" (ab Plus) mit Schloss, Plus nur
    /// "Tests & Wiederholung", Pro AI keines. Ohne iCloud-Container bleibt die Community weg (technisch, kein Tarif).
    func testNavigationShowsLockedAreasPerPlan() {
        func items(_ plan: UFPlan, ai: Bool = false, community: Bool = true, proAIHidden: Bool = false) -> [String: UFPlan?] {
            Dictionary(uniqueKeysWithValues: UFNavItem.visible(local: true, gradesOnDevice: true, community: community, ai: ai,
                                                               plan: plan, proAIHidden: proAIHidden).map { ($0.id, $0.lock) })
        }
        let free = items(.free)
        XCTAssertEqual(free["exams"], .some(.proAI))
        XCTAssertEqual(free["cards"], .some(.plus))
        XCTAssertEqual(free["community"], .some(.plus))
        XCTAssertEqual(free["plan"], .some(nil), "Lernkalender ist Free")
        let plus = items(.plus)
        XCTAssertEqual(plus["exams"], .some(.proAI))
        XCTAssertEqual(plus["cards"], .some(nil))
        XCTAssertEqual(plus["community"], .some(nil))
        let pro = items(.proAI, ai: true)
        XCTAssertTrue(pro.values.allSatisfy { $0 == nil }, "Pro AI: kein Schloss")
        XCTAssertNotNil(pro["exams"])
        XCTAssertNil(items(.proAI)["exams"], "Pro AI ohne KI-Verbindung (Anmeldung fehlt): kein Schloss, kein Eintrag")
        XCTAssertNil(items(.free, community: false)["community"], "ohne iCloud-Container keine Community")
        XCTAssertNil(items(.free, proAIHidden: true)["exams"], "Pro AI nicht zu kaufen: kein Schloss ab Pro AI")
        XCTAssertEqual(items(.free, ai: true)["exams"], .some(nil), "eigenes ChatGPT: Wochentests ohne Schloss")
        // ohne Tarif (eigener Server, alte Aufrufer): wie bisher ohne Schloesser
        XCTAssertTrue(UFNavItem.visible(local: true, gradesOnDevice: true, community: true).allSatisfy { $0.lock == nil })
        // "Mehr" (untere Leiste) und Logo-Menue tragen das Schloss mit
        let more = UFNavItem.more(visible: UFNavItem.visible(local: true, gradesOnDevice: true, community: true, plan: .free))
        XCTAssertEqual(more.first { $0.id == "cards" }?.lock, .plus)
        XCTAssertEqual(more.first { $0.id == "cards" }?.menuTitle, "Karteikarten (ab Plus)")
    }

    // MARK: Seitenleiste

    func testSidebarLocksOpenThePlanPickerWithTheRequiredPlan() throws {
        for plan in [UFPlan.free, .plus, .proAI] {
            Entitlements.shared.setPlanForTesting(plan)
            let env = try hostWithEnvironment(UFSidebar(collapsed: false, allowCollapse: false).frame(width: UF.sidebar),
                                              size: CGSize(width: 320, height: 900))
            env.window.overrideUserInterfaceStyle = .light
            XCTAssertTrue(env.wait(timeout: 10) { Self.element("nav.cards", in: env.view) != nil }, env.labels().joined(separator: "\n"))
            env.pump(0.4)
            let cards = try XCTUnwrap(Self.element("nav.cards", in: env.view))
            let exams = Self.element("nav.exams", in: env.view)
            switch plan {
            case .free:
                XCTAssertEqual(cards.accessibilityValue, "gesperrt, ab Plus")
                XCTAssertEqual(cards.accessibilityHint, UFLock.hint)
                XCTAssertEqual(exams?.accessibilityValue, "gesperrt, ab Pro AI")
            case .plus:
                XCTAssertEqual(cards.accessibilityValue ?? "", "", "Plus: Karteikarten frei")
                XCTAssertEqual(exams?.accessibilityValue, "gesperrt, ab Pro AI")
            case .proAI:
                XCTAssertFalse(Self.all(in: env.view).contains { ($0.accessibilityValue ?? "").hasPrefix("gesperrt") }, "Pro AI: kein Schloss")
            }
            try shoot(env, "seitenleiste-\(plan.rawValue)")
            // Antippen eines Schlosses: Seite und Tarifwahl mit dem noetigen Tarif
            if plan != .proAI, let exams {
                XCTAssertTrue(exams.accessibilityActivate())
                XCTAssertTrue(env.wait(timeout: 10) { self.presentedLabels(env).contains("Mehr mit \(UFPlan.proAI.name)") },
                              "Tarifwahl mit Pro AI:\n" + presentedLabels(env).joined(separator: "\n"))
                XCTAssertEqual(env.router.route, .exams)
                try shoot(env, "seitenleiste-\(plan.rawValue)-tarifwahl", presented: true)
                dismiss(env)
            }
            if plan == .free {
                XCTAssertTrue(cards.accessibilityActivate())
                XCTAssertTrue(env.wait(timeout: 10) { self.presentedLabels(env).contains("Mehr mit \(UFPlan.plus.name)") },
                              "Tarifwahl mit Plus:\n" + presentedLabels(env).joined(separator: "\n"))
                XCTAssertEqual(env.router.route, .cards, "die Seite darunter zeigt die eigenen Karten zum Lesen")
                dismiss(env)
            }
            env.window.isHidden = true
        }
    }

    // MARK: Editor: Schloesser und Lage der Leiste

    func testEditorShowsLockedToolbarAndAskAIPerPlan() throws {
        for plan in [UFPlan.free, .plus, .proAI] {
            Entitlements.shared.setPlanForTesting(plan)
            let env = try hostDocument()
            XCTAssertTrue(env.wait(timeout: 20) { Self.element("editor.toolbar", in: env.view) != nil },
                          "\(plan.name): Leiste fehlt\n" + env.labels().joined(separator: "\n"))
            env.pump(1.0)
            let ids = Self.identifiers(in: env.view)
            switch plan {
            case .free:
                let bar = try XCTUnwrap(Self.element("editor.toolbar.locked", in: env.view), "Free: Leiste mit Schloss")
                XCTAssertEqual(bar.accessibilityLabel, "Schreiben mit Plus")
                XCTAssertEqual(bar.accessibilityValue, "gesperrt, ab Plus")
                XCTAssertFalse(ids.contains("toolbar.tool.pen"), "Free: keine benutzbaren Werkzeuge")
                XCTAssertEqual(Self.element("toolbar.askAI.locked", in: env.view)?.accessibilityValue, "gesperrt, ab Pro AI")
                try shoot(env, "editor-free")
                XCTAssertTrue(bar.accessibilityActivate())
                XCTAssertTrue(env.wait(timeout: 10) { self.presentedLabels(env).contains("Mehr mit \(UFPlan.plus.name)") },
                              presentedLabels(env).joined(separator: "\n"))
                try shoot(env, "editor-free-tarifwahl", presented: true)
                dismiss(env)
            case .plus:
                XCTAssertTrue(ids.contains("toolbar.tool.pen"), "Plus: Werkzeuge da")
                XCTAssertFalse(ids.contains("editor.toolbar.locked"))
                let ask = try XCTUnwrap(Self.element("toolbar.askAI.locked", in: env.view), "Plus: KI fragen mit Schloss")
                XCTAssertEqual(ask.accessibilityValue, "gesperrt, ab Pro AI")
                try shoot(env, "editor-plus")
                XCTAssertTrue(ask.accessibilityActivate())
                XCTAssertTrue(env.wait(timeout: 10) { self.presentedLabels(env).contains("Mehr mit \(UFPlan.proAI.name)") },
                              presentedLabels(env).joined(separator: "\n"))
                dismiss(env)
            case .proAI:
                XCTAssertTrue(ids.contains("toolbar.tool.pen"))
                XCTAssertFalse(Self.all(in: env.view).contains { ($0.accessibilityValue ?? "").hasPrefix("gesperrt") }, "Pro AI: kein Schloss")
            }
            env.window.isHidden = true
        }
    }

    /// Lage oben, unten, schwebend; Wechsel im offenen Dokument; Hoehe 44 pt; Trefferflaechen 44 x 44 pt
    func testToolbarPlacementTopBottomFloatingSwitchesInTheOpenDocument() throws {
        Entitlements.shared.setPlanForTesting(.plus)
        let env = try hostDocument()
        func bar() -> CGRect? { Self.element("editor.toolbar", in: env.view).map(\.accessibilityFrame) }
        func pen() -> CGRect? { Self.element("toolbar.tool.pen", in: env.view).map(\.accessibilityFrame) }
        func pdf() -> CGRect? { EditorToolbarTests.pdfViews(in: env.view).first.map { $0.convert($0.bounds, to: env.window) } }
        XCTAssertTrue(env.wait(timeout: 20) { pen() != nil && pdf() != nil }, env.labels().joined(separator: "\n"))
        env.pump(1.0)
        let editor = try XCTUnwrap(EditorToolbarTests.pdfViews(in: env.view).first.flatMap(EditorToolbarTests.editor(of:)))

        // oben (Vorgabe): ueber der PDF, 44 pt hoch (vorher 52)
        XCTAssertEqual(EditorToolbar.height, 44)
        XCTAssertEqual(editor.toolbarPlacement, .top)
        let top = try XCTUnwrap(pen())
        let p = try XCTUnwrap(pdf())
        XCTAssertLessThan(top.midY, p.minY, "oben: ueber der PDF")
        XCTAssertEqual(p.minY - top.midY, EditorToolbar.height / 2, accuracy: 2)
        // jede Trefferflaeche der Leiste mindestens 44 x 44 pt
        let buttons = Self.all(in: env.view).filter {
            guard let id = Self.identifier($0) else { return false }
            return id.hasPrefix("toolbar.tool.") || ["toolbar.ruler", "toolbar.attributes", "toolbar.undo", "toolbar.redo",
                                                     "toolbar.askAI.locked", "toolbar.objects"].contains(id)
        }
        // seit 12.11.2026 in der einen Kopfzeile: passt nicht alles, stehen die Objektwerkzeuge in einem Knopf
        let collapsed = buttons.contains { Self.identifier($0) == "toolbar.objects" }
        XCTAssertGreaterThanOrEqual(buttons.count, collapsed ? 11 : 16, "alle Knoepfe gefunden")
        for b in buttons {
            let f = b.accessibilityFrame
            XCTAssertGreaterThanOrEqual(f.height, 43.5, "\(Self.identifier(b) ?? "?"): Hoehe \(f.height)")
            XCTAssertGreaterThanOrEqual(f.width, 43.5, "\(Self.identifier(b) ?? "?"): Breite \(f.width)")
        }
        try shoot(env, "lage-oben-plus")

        // unten: Wechsel in den Einstellungen wirkt sofort im offenen Dokument
        UserDefaults.standard.set(EditorToolbarPlacement.bottom.rawValue, forKey: EditorToolbarPlacement.key)
        XCTAssertTrue(env.wait(timeout: 5) { (pen()?.minY ?? 0) > (pdf()?.midY ?? .infinity) }, "unten: Leiste unter der PDF")
        env.pump(0.5)
        let bottom = try XCTUnwrap(pen())
        let p2 = try XCTUnwrap(pdf())
        XCTAssertEqual(bottom.midY - p2.maxY, EditorToolbar.height / 2, accuracy: 2, "unten: direkt unter der PDF")
        XCTAssertEqual(editor.toolbarPlacement, .bottom)
        try shoot(env, "lage-unten-plus")

        // schwebend: keine feste Leiste, Apples Palette am Editor (Simulator: Palette erscheint mit dem Erstantwortgeber)
        UserDefaults.standard.set(EditorToolbarPlacement.floating.rawValue, forKey: EditorToolbarPlacement.key)
        XCTAssertTrue(env.wait(timeout: 5) { bar() == nil }, "schwebend: keine feste Leiste")
        XCTAssertEqual(editor.toolbarPlacement, .floating)
        XCTAssertTrue(editor.floatingPaletteWanted)
        let palette = try XCTUnwrap(editor.floatingPalette, "Palette angelegt")
        XCTAssertTrue(env.wait(timeout: 5) { palette.isVisible }, "schwebend: Apples Palette sichtbar")
        env.pump(1.0)
        // Palette -> Leiste: Wahl in der Palette kommt als Werkzeug an (alle Seiten)
        if #available(iOS 18.0, *) {
            XCTAssertTrue(palette.picker.toolItems.contains { $0.identifier == EditorPalette.areaID }, "eigene Eintraege in der Palette")
            palette.picker.selectedToolItemIdentifier = "com.apple.ink.marker"
            palette.selectionChanged()
            XCTAssertEqual(editor.tools.tool, .marker)
            // Leiste/Tastatur -> Palette
            editor.tools.select(.fineliner)
            XCTAssertEqual(palette.picker.selectedToolItemIdentifier, "com.apple.ink.monoline")
        }
        try shoot(env, "lage-schwebend-plus")
        holdForSimulatorShot(env, "lage-schwebend-plus-simulator")

        // zurueck nach oben: Palette weg, Leiste wieder da
        UserDefaults.standard.set(EditorToolbarPlacement.top.rawValue, forKey: EditorToolbarPlacement.key)
        XCTAssertTrue(env.wait(timeout: 5) { pen() != nil }, "oben: Leiste wieder da")
        XCTAssertFalse(editor.floatingPaletteWanted)
        XCTAssertFalse(palette.isVisible, "Palette verborgen")
        XCTAssertEqual(try XCTUnwrap(pen()).minY, top.minY, accuracy: 1)
        env.window.isHidden = true
    }

    /// Schwebend ohne Plus: keine Palette, oben ein Hinweis mit Schloss (Antippen: Tarifwahl mit Plus); unten fest ohne
    /// Plus: die Leiste mit Schloss unten
    func testFloatingAndBottomWithoutPlusShowTheLock() throws {
        Entitlements.shared.setPlanForTesting(.free)
        UserDefaults.standard.set(EditorToolbarPlacement.floating.rawValue, forKey: EditorToolbarPlacement.key)
        let env = try hostDocument()
        XCTAssertTrue(env.wait(timeout: 20) { Self.element("editor.palette.locked", in: env.view) != nil },
                      env.labels().joined(separator: "\n"))
        env.pump(1.0)
        let editor = try XCTUnwrap(EditorToolbarTests.pdfViews(in: env.view).first.flatMap(EditorToolbarTests.editor(of:)))
        XCTAssertFalse(editor.floatingPaletteWanted, "ohne Plus keine Palette")
        XCTAssertFalse(editor.floatingPalette?.isVisible ?? false)
        let hint = try XCTUnwrap(Self.element("editor.palette.locked", in: env.view))
        XCTAssertEqual(hint.accessibilityValue, "gesperrt, ab Plus")
        XCTAssertGreaterThanOrEqual(hint.accessibilityFrame.height, 43.5)
        try shoot(env, "lage-schwebend-free")
        XCTAssertTrue(hint.accessibilityActivate())
        XCTAssertTrue(env.wait(timeout: 10) { self.presentedLabels(env).contains("Mehr mit \(UFPlan.plus.name)") })
        dismiss(env)

        UserDefaults.standard.set(EditorToolbarPlacement.bottom.rawValue, forKey: EditorToolbarPlacement.key)
        XCTAssertTrue(env.wait(timeout: 5) { Self.element("editor.toolbar.locked", in: env.view) != nil })
        env.pump(0.5)
        let bar = try XCTUnwrap(Self.element("editor.toolbar.locked", in: env.view)).accessibilityFrame
        let p = try XCTUnwrap(EditorToolbarTests.pdfViews(in: env.view).first.map { $0.convert($0.bounds, to: env.window) })
        XCTAssertGreaterThan(bar.midY, p.maxY, "unten: Leiste mit Schloss unter der PDF")
        try shoot(env, "lage-unten-free")
        env.window.isHidden = true
    }

    /// Wahl je Geraet, am Mac ohne "Schwebend"; Unbekanntes faellt auf die Vorgabe "Oben fest"
    func testPlacementSettingIsRememberedAndMacHasNoFloating() {
        XCTAssertEqual(EditorToolbarPlacement.resolve(nil, isMac: false), .top)
        XCTAssertEqual(EditorToolbarPlacement.resolve("bottom", isMac: false), .bottom)
        XCTAssertEqual(EditorToolbarPlacement.resolve("floating", isMac: false), .floating)
        XCTAssertEqual(EditorToolbarPlacement.resolve("floating", isMac: true), .top)
        XCTAssertEqual(EditorToolbarPlacement.resolve("quer", isMac: false), .top)
        XCTAssertEqual(EditorToolbarPlacement.choices(isMac: false).map(\.title), ["Oben fest", "Unten fest", "Schwebend"])
        XCTAssertEqual(EditorToolbarPlacement.choices(isMac: true), [.top, .bottom])
        UserDefaults.standard.set("bottom", forKey: EditorToolbarPlacement.key)
        XCTAssertEqual(EditorToolbarPlacement.current(), .bottom)
    }

    // MARK: Hilfen

    private func hostDocument() throws -> HostedEnvironment {
        let t = AIViewsAppTests.Transport()
        let id = "f-schloss-\(UUID().uuidString.prefix(8))"
        t.answer("/api/files/\(id)/content", data: Self.makePDF(pages: 2), type: "application/pdf")
        t.answer("/api/files/\(id)/annotations", ["data": AnnotationDocument.emptyRoot, "version": 0, "updated_at": .null])
        t.answer("/api/related", ["results": []])
        let meta: JSONValue = ["id": .string(id), "name": "Übungsblatt 3.pdf", "title": "Übungsblatt 3", "kind": "pdf", "module_id": 1,
                               "downloaded_at": "2026-11-12T09:00:00", "page_count": 2, "doc_type": "uebung"]
        let file = try JSONDecoder().decode(LibFile.self, from: meta.serialized())
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api) }, api: api,
                                          size: CGSize(width: 1180, height: 820))
        env.window.overrideUserInterfaceStyle = .light
        return env
    }

    static func makePDF(pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Übungsblatt 3, Aufgabe \(i)".draw(at: CGPoint(x: 72, y: 90), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func presentedLabels(_ env: HostedEnvironment) -> [String] {
        var out: [String] = []
        var vc = env.hosting.presentedViewController
        while let p = vc {
            if let v = p.view { out += Self.all(in: v).compactMap(\.accessibilityLabel) }
            vc = p.presentedViewController
        }
        return out
    }

    private func dismiss(_ env: HostedEnvironment) {
        env.hosting.presentedViewController?.dismiss(animated: false)
        _ = env.wait(timeout: 5) { env.hosting.presentedViewController == nil }
        env.pump(0.4)
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, presented: Bool = false) throws {
        guard let dir = ProcessInfo.processInfo.environment["UF_LOCK_SHOTS"], !dir.isEmpty else { return }
        env.pump(0.4)
        let w: UIWindow = presented ? (env.hosting.presentedViewController?.view.window ?? env.window) : env.window
        w.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        // alle sichtbaren Fenster der Szene uebereinander (Apples schwebende Palette liegt in einem eigenen Fenster)
        let windows = (w.windowScene?.windows ?? [w]).filter { !$0.isHidden && $0.frame.intersects(w.frame) }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        let img = UIGraphicsImageRenderer(bounds: w.bounds, format: format).image { _ in
            for x in windows where x === w || x.windowLevel.rawValue > w.windowLevel.rawValue || String(describing: type(of: x)).contains("ToolPicker") {
                _ = x.drawHierarchy(in: x.convert(x.bounds, to: w), afterScreenUpdates: true)
            }
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try XCTUnwrap(img.pngData()).write(to: url.appendingPathComponent(name + ".png"))
    }

    /// Apples Palette zeichnet ein anderer Prozess (in `drawHierarchy` fehlt sie): mit Bildordner eine Marke schreiben und
    /// kurz stehen bleiben, damit `xcrun simctl io <Geraet> screenshot` von aussen das echte Bild holt
    private func holdForSimulatorShot(_ env: HostedEnvironment, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_LOCK_SHOTS"], !dir.isEmpty else { return }
        let mark = URL(fileURLWithPath: dir).appendingPathComponent("bereit-\(name)")
        try? Data().write(to: mark)
        env.pump(6)
        try? FileManager.default.removeItem(at: mark)
    }

    static func identifier(_ o: NSObject) -> String? { EditorToolbarTests.identifier(o) }

    static func identifiers(in view: UIView) -> Set<String> { EditorToolbarTests.identifiers(in: view) }

    /// Erstes Element mit dieser Kennung (Bedienungshilfen-Baum)
    static func element(_ id: String, in view: UIView) -> NSObject? {
        all(in: view).first { identifier($0) == id && $0.accessibilityFrame.width > 0 }
    }

    /// Alle Elemente im Bedienungshilfen-Baum
    static func all(in root: UIView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func go(_ element: Any, depth: Int) {
            guard depth < 50, let o = element as? NSObject, seen.insert(ObjectIdentifier(o)).inserted else { return }
            if let v = o as? UIView, v.isHidden { return }
            out.append(o)
            for e in o.accessibilityElements ?? [] { go(e, depth: depth + 1) }
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { go(e, depth: depth + 1) } } }
            if let v = o as? UIView { for s in v.subviews { go(s, depth: depth + 1) } }
        }
        root.layoutIfNeeded()
        go(root, depth: 0)
        return out
    }
}
