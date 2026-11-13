import Foundation
import XCTest
@testable import UniFlowCore

/// "Im QIS zur Prüfung anmelden" fuehrt direkt zum Modul (13.11.2026, `QISRegistrationGuide`). Ein nachgebautes QIS
/// (erfunden, Aufbau wie die echten Seiten qis-echt-*.html: Startseite ohne asi, "Mein Studium", Menuepunkt
/// "Prüfungsanmeldung/-abmeldung" -> Hinweisseite qis-anm-hinweise-*.html -> Baum mit nodeID/expand, Zustand des Baums
/// in der Sitzung des Servers). Keine echte Anmeldung, keine Namen.
final class QISRegistrationGuideTests: XCTestCase {
    static let base = "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet"
    static let start = URL(string: base + "?state=user&type=0")!
    static let menu = URL(string: base + "?state=change&type=1&moduleParameter=studyPOSMenu&next=menu.vm")!

    static func fixture(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/exam-registration/\(name)"), encoding: .utf8)
    }

    /// Nachgebautes QIS: merkt sich offene Zweige wie der echte Server; jede Handlung (anmelden, abmelden, Logout,
    /// Formular) ist ein Fehler des Tests
    final class FakeQIS {
        struct Node { let id: String; let label: String; var children: [Node] = []; var exams: [(nr: String, text: String)] = [] }
        var expanded: Set<String> = []
        var requests: [URL] = []
        var actions: [URL] = []
        var loggedIn = true
        var hints = "qis-anm-hinweise-link.html"
        let tree: Node

        init() {
            let a = "auswahlBaum|abschluss:abschl=82,stgnr=1"
            let s = a + "|studiengang:stg=104"
            let p = s + "|kontoOnTop:labnrzu=1000"
            let k = s + "|kontoOnTop:labnrzu=2000"
            tree = Node(id: a, label: "Abschluss 82 Bachelor of Science", children: [
                Node(id: s, label: "Maschinenbau  (PO-Version 2017)", children: [
                    Node(id: p, label: "Pflichtmodule", children: [
                        Node(id: p + "|konto:labnrzu=1200", label: "1200 Technische Mechanik III", exams: [("1201", "Technische Mechanik III (Klausur)")]),
                        Node(id: p + "|konto:labnrzu=1300", label: "1300 Thermodynamik I", exams: [("1301", "Thermodynamik I (Klausur)")]),
                        Node(id: p + "|konto:labnrzu=1310", label: "1310 Grundzüge der Chemie", exams: [("1311", "Grundzüge der Chemie (Studienleistung)")]),
                    ]),
                    Node(id: k, label: "Schlüsselkompetenzen", children: [
                        Node(id: k + "|konto:labnrzu=2500", label: "2500 Studium Generale", exams: [("2501", "Studium Generale")]),
                    ]),
                ]),
            ])
        }

        static func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~="))) ?? s
        }

        func nodeLink(_ n: Node, open: Bool) -> String {
            let e = Self.enc(n.id)
            return #"<a class="regular" href="\#(base)?state=prfAnmStudent&amp;struct=auswahlBaum&amp;navigation=Y&amp;next=tree.vm&amp;nextdir=qispos/prfAnm/student&amp;nodeID=\#(e)&amp;expand=\#(open ? 1 : 0)&amp;lastState=prfAnmStudent&amp;asi=S1abcDEF#\#(e)" title="Diesen Zweig \#(open ? "zuklappen" : "aufklappen")">\#(n.label)</a>"#
        }

        func render(_ n: Node) -> String {
            let open = expanded.contains(n.id)
            var out = #"<li class="treelist">\#(nodeLink(n, open: open))"#
            if open {
                out += #"<ul class="treelist">"# + n.children.map(render).joined() + "</ul>"
                for x in n.exams {
                    // Pruefung mit Handlungen: nie folgen
                    out += #"<table><tr><td>\#(x.nr)</td><td>\#(x.text)</td><td><a href="\#(base)?state=prfAnmStudent&amp;next=wait.vm&amp;nextdir=qispos/prfAnm/student&amp;prfnr=\#(x.nr)&amp;asi=S1abcDEF">Prüfung anmelden</a></td><td><a href="\#(base)?state=prfAnmStudent&amp;struct=auswahlBaum&amp;next=tree.vm&amp;nodeID=\#(Self.enc(n.id))&amp;expand=0&amp;prfnr=\#(x.nr)&amp;asi=S1abcDEF">\#(x.text)</a></td></tr></table>"#
                }
            }
            return out + "</li>"
        }

        static let navi = #"<a href="\#(base)?state=user&amp;type=4&amp;re=last&amp;category=auth.logout" class="links3"><u>L</u>ogout</a>"#
            + #"<a class="regular" href="\#(base)?state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;nextdir=change&amp;next=menu.vm">Mein Studium</a>"#

        func page(_ url: URL) throws -> String {
            requests.append(url)
            let p = QISParser.parameters(of: url.absoluteString)
            let state = p["state"] ?? ""
            guard loggedIn else {
                return #"<html><body><h1>Anmeldung</h1><form action="x" method="post"><input name="asdf"><input type="password" name="fdsa"></form></body></html>"#
            }
            if state == "user", p["type"] == "4" { actions.append(url) }
            switch (state, p["next"] ?? "") {
            case ("user", _):
                return "<html><body>\(Self.navi)<h1>Willkommen</h1></body></html>"
            case ("change", _):
                return try QISRegistrationGuideTests.fixture("qis-echt-studium.html")
            case ("info", _):
                return try QISRegistrationGuideTests.fixture(hints)
            case ("prfAnmStudent", let next) where next.hasPrefix("tree"):
                if p["prfnr"] != nil { actions.append(url) }
                if let node = p["nodeid"] {
                    if p["expand"] == "0" { expanded.insert(node) } else { expanded.remove(node) }
                }
                return #"<html><body>\#(Self.navi)<a name="lese"></a><h1>Prüfungsanmeldung</h1><form method="post" action="\#(base)?state=prfAnmStudent&amp;next=tree.vm&amp;asi=S1abcDEF"><ul class="treelist">\#(render(tree))</ul></form></body></html>"#
            default:
                actions.append(url)
                return "<html><body><h1>Prüfung anmelden</h1></body></html>"
            }
        }
    }

    /// Durchlauf wie der In-App-Browser: Seite laden, Schritt bestimmen, Link laden, bis kein `follow` mehr kommt
    @discardableResult
    static func walk(_ qis: FakeQIS, from url: URL = menu, target: QISRegistrationTarget,
                     progress: inout QISRegistrationGuide.Progress) throws -> QISRegistrationGuide.Step {
        var current = url
        for _ in 0..<100 {
            let html = try qis.page(current)
            let step = QISRegistrationGuide.step(html: html, url: current, target: target, progress: &progress)
            guard case .follow(let next) = step else { return step }
            current = next
        }
        XCTFail("kein Ende")
        return .unknown
    }

    static func walk(_ qis: FakeQIS, from url: URL = menu, target: QISRegistrationTarget) throws -> QISRegistrationGuide.Step {
        var p = QISRegistrationGuide.Progress()
        return try walk(qis, from: url, target: target, progress: &p)
    }

    func testFindsTheModuleThroughMenuNoticeAndTreeAndMarksIt() throws {
        let qis = FakeQIS()
        let step = try Self.walk(qis, from: Self.start, target: QISRegistrationTarget(title: "Thermodynamik I / Chemie"))
        guard case .highlight(let h) = step else { return XCTFail("\(step)") }
        XCTAssertEqual(h.text, "1300 Thermodynamik I", "Teil 'Thermodynamik I' vor 'Grundzüge der Chemie'")
        XCTAssertFalse(h.address.contains("asi="), "Markierung ohne Sitzungsparameter")
        XCTAssertTrue(qis.actions.isEmpty, "nie angemeldet, abgemeldet oder Logout: \(qis.actions)")
        XCTAssertTrue(qis.expanded.contains { $0.hasSuffix("labnrzu=1300") }, "Modul aufgeklappt: Pruefungen zu sehen")
        XCTAssertFalse(qis.expanded.contains { $0.hasSuffix("labnrzu=2000") }, "fremde Bereiche bleiben zu")
        let path = qis.requests.map { QISParser.parameters(of: $0.absoluteString)["state"] ?? "" }
        XCTAssertEqual(Array(path.prefix(4)), ["user", "change", "info", "prfAnmStudent"], "Start -> Mein Studium -> Hinweise -> Baum")
        XCTAssertTrue(qis.requests.dropFirst().allSatisfy { $0.absoluteString.contains("asi=S1abcDEF") || $0.absoluteString.contains("studyPOSMenu") },
                      "Links mit dem asi der Seite (nur fuer den Aufruf)")
    }

    func testSearchesOtherBranchesAndUsesTheExamNumber() throws {
        let qis = FakeQIS()
        let step = try Self.walk(qis, target: QISRegistrationTarget(title: "Tutorien oder Studium Generale"))
        XCTAssertEqual(step, .highlight(.init(address: try XCTUnwrap(Self.address(qis, "2500")), text: "2500 Studium Generale")))
        XCTAssertTrue(qis.actions.isEmpty)
        // Nummer schlaegt den Namen
        let other = FakeQIS()
        guard case .highlight(let h) = try Self.walk(other, target: QISRegistrationTarget(title: "Mechanik", nr: "1310")) else { return XCTFail() }
        XCTAssertEqual(h.text, "1310 Grundzüge der Chemie")
    }

    static func address(_ qis: FakeQIS, _ nr: String) -> String? {
        let html = qis.render(qis.tree)
        let page = QISPage.parse(html: html, url: menu)
        return page.links.first { $0.text.hasPrefix(nr + " ") }?.address
    }

    func testAgainForAnotherModuleInTheSameSessionWithoutLeaving() throws {
        // Fehler (b) des Inhabers: nach einem Modul ein anderes, ohne das QIS zu verlassen. Neuer Durchlauf ab "Mein
        // Studium" mit frischen Links (asi der aktuellen Seite); offene Zweige der Sitzung stoeren nicht
        let qis = FakeQIS()
        _ = try Self.walk(qis, target: QISRegistrationTarget(title: "Thermodynamik I / Chemie"))
        let second = try Self.walk(qis, target: QISRegistrationTarget(title: "Technische Mechanik III"))
        guard case .highlight(let h) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(h.text, "1200 Technische Mechanik III")
        XCTAssertTrue(qis.actions.isEmpty)
        XCTAssertFalse(qis.requests.contains { QISParser.parameters(of: $0.absoluteString)["expand"] == "1" }, "nie zugeklappt")
    }

    func testNoticeWithFormWaitsForTheHumanAndLoginPageAsksForLogin() throws {
        let qis = FakeQIS()
        qis.hints = "qis-anm-hinweise-formular.html"
        XCTAssertEqual(try Self.walk(qis, target: QISRegistrationTarget(title: "Thermodynamik I")), .confirmNotice,
                       "Hinweise bestaetigen tut der Mensch (kein Formular)")
        XCTAssertEqual(qis.requests.count, 2)
        XCTAssertTrue(qis.actions.isEmpty)
        let out = FakeQIS()
        out.loggedIn = false
        XCTAssertEqual(try Self.walk(out, from: Self.start, target: QISRegistrationTarget(title: "Thermodynamik I")), .login)
    }

    func testUnknownModuleEndsAfterTheTreeWithoutActions() throws {
        let qis = FakeQIS()
        XCTAssertEqual(try Self.walk(qis, target: QISRegistrationTarget(title: "Quantenoptik für Fortgeschrittene")), .notFound)
        XCTAssertTrue(qis.actions.isEmpty)
        XCTAssertEqual(qis.expanded.count, 8, "jeder Zweig einmal, keiner doppelt")
        // Schrittgrenze
        var p = QISRegistrationGuide.Progress()
        p.steps = QISRegistrationGuide.maxSteps
        XCTAssertEqual(try Self.walk(FakeQIS(), target: QISRegistrationTarget(title: "Thermodynamik I"), progress: &p), .notFound)
        // anderer Rechner bzw. http
        XCTAssertEqual(QISRegistrationGuide.step(html: "<a href='x'>Mein Studium</a>", url: URL(string: "http://qis.verwaltung.uni-hannover.de/")!,
                                                 target: .init(title: "x"), progress: &p), .unknown)
    }

    func testNeverFollowsActionLinks() {
        func link(_ text: String, _ query: String) -> QISLink {
            let a = Self.base + "?" + query
            return QISLink(text: text, address: a, parameters: QISParser.parameters(of: a))
        }
        let node = "state=prfAnmStudent&struct=auswahlBaum&next=tree.vm&nodeID=auswahlBaum%7Cx&expand=0"
        XCTAssertTrue(QISRegistrationGuide.isTreeNode(link("1300 Thermodynamik I", node)))
        XCTAssertFalse(QISRegistrationGuide.isTreeNode(link("Thermodynamik I anmelden", node)))
        XCTAssertFalse(QISRegistrationGuide.isTreeNode(link("Thermodynamik I", node + "&prfnr=1301")), "Pruefungsparameter: Handlung")
        XCTAssertFalse(QISRegistrationGuide.isTreeNode(link("Thermodynamik I", "state=prfAnmStudent&next=wait.vm&nodeID=x&expand=0")))
        XCTAssertFalse(QISRegistrationGuide.isTreeNode(link("Rücktritt", node)))
        XCTAssertFalse(QISRegistrationGuide.isTreeEntry(link("Prüfung abmelden", "state=prfAnmStudent&next=tree.vm")))
        XCTAssertTrue(QISRegistrationGuide.isTreeEntry(link("Weiter zur Prüfungsanmeldung/-abmeldung", "state=prfAnmStudent&next=tree.vm&struct=auswahlBaum")))
        XCTAssertTrue(QISRegistrationGuide.isRegistrationMenu(link("Prüfungsanmeldung/-abmeldung",
                                                                   "state=info&moduleParameter=prfAnmStudent&next=info.vm")))
        XCTAssertFalse(QISRegistrationGuide.isRegistrationMenu(link("Logout", "state=user&type=4")))
    }

    func testScore() {
        let t = QISRegistrationTarget(title: "Thermodynamik I / Chemie", nr: " 1300 ")
        XCTAssertEqual(t.nr, "1300")
        XCTAssertEqual(QISRegistrationGuide.score("Modul 1300: Thermodynamik I", t), 100)
        let n = QISRegistrationTarget(title: "Thermodynamik I / Chemie")
        XCTAssertEqual(QISRegistrationGuide.score("1350 Thermodynamik I / Chemie", n), 80)
        XCTAssertEqual(QISRegistrationGuide.score("1300 Thermodynamik I", n), 60)
        XCTAssertEqual(QISRegistrationGuide.score("Grundzüge der Chemie (PL)", n), 40)
        XCTAssertEqual(QISRegistrationGuide.score("Thermodynamik II", n), 0)
        XCTAssertEqual(QISRegistrationGuide.score("Biochemie", n), 0)
        XCTAssertEqual(QISRegistrationGuide.score("Pflichtmodule", n), 0)
        XCTAssertEqual(QISRegistrationGuide.score("Technische Mechanik III", QISRegistrationTarget(title: "Technische Mechanik 3")), 80)
    }
}
