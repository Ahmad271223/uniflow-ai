import Foundation
import XCTest
@testable import UniFlowCore

/// Notenspiegel des LSF Hildesheim im Aufbau des echten Kontos (gesehen 26.11.2026, hier mit erfundenen Faechern, Nummern
/// und Noten): die Uebersicht nennt jede Leistung kurz (5 Spalten), der Reiter des Studiengangs ausfuehrlich (9 Spalten
/// mit Semester, Pruefungsart, Versuch, Datum); Konto-Zeilen (LP-Summe je Fach, Gesamtnote aller Faecher) haben auf dem
/// Reiter eine Zelle weniger. Vorher zaehlten beide Fassungen: am echten Konto 105 statt 51 LP.
final class LSFRealLayoutTests: XCTestCase {
    private let first = "Abschluss: [B5] Zwei-Fächer-Bachelor Studiengang: [105] Erstfach PO-Version: 2025"
    private let second = "Abschluss: [B5] Zwei-Fächer-Bachelor Studiengang: [011] Zweitfach PO-Version: 2014"
    private let short = ["Prüfungsnr.", "Bezeichnung der Leistung / der Lehrveranstaltung", "Note", "Status", "Bonus"]
    private let long = ["Prüfungsnr.", "Bezeichnung der Leistung / der Lehrveranstaltung", "Semester", "Note", "Status", "Bonus",
                        "Prüfungsart", "Versuch", "Prüfungsdatum"]

    /// Uebersicht: kurz, ohne Semester; das Konto des Zweitfachs hat weder Note noch Status und wird nicht gelesen
    private var overview: [[String]] {
        [[first], short,
         ["10", "Erstfach", "0,0", "", "12"],
         ["4010", "BM 1: Grundlagen", "2,3", "bestanden", "6"],
         ["4011", "TM: Grundlagen I (V) / 3200 Grundlagen 1", "2,3", "bestanden", "3"],
         ["4012", "TM: Grundlagen II (Ü) / 3201 Grundlagen 2", "", "bestanden", "3"],
         ["4032", "TM: Rechnen 2 / 3300 Rechnen", "5,0", "nicht bestanden", "0"],
         ["5021", "TM: Einführung / 5100 Einführung", "", "bestanden", "3"],
         ["8992", "Vorläufige Gesamtnote aller Fächer", "2,3", "", "16"],
         [second], short,
         ["10", "Zweitfach", "", "", "4"],
         ["7011", "TM: Psychologie / 0810 Grundlagen", "", "bestanden", "4"]]
    }

    /// Reiter: ausfuehrlich; Konto-Zeilen mit einer Zelle weniger (die Bezeichnung reicht ueber zwei Spalten)
    private var tabs: [[String]] {
        [[first], long,
         ["10", "Erstfach", "0,0", "", "12", "", "", ""],
         ["4010", "BM 1: Grundlagen", "WiSe 25/26", "2,3", "bestanden", "6", "", "", ""],
         ["4011", "TM: Grundlagen I (V) / 3200 Grundlagen 1", "WiSe 25/26", "2,3", "bestanden", "3", "(Klausur)", "1", "09.02.2026"],
         ["4012", "TM: Grundlagen II (Ü) / 3201 Grundlagen 2", "WiSe 25/26", "", "bestanden", "3", "(Klausur)", "1", "09.02.2026"],
         ["4032", "TM: Rechnen 2 / 3300 Rechnen", "SoSe 26", "5,0", "nicht bestanden", "0", "(Klausur)", "1", "03.08.2026"],
         ["4032", "TM: Rechnen 2 / 3300 Rechnen", "SoSe 26", "4,0", "bestanden", "3", "(Klausur)", "2", "23.10.2026"],
         ["5021", "TM: Einführung / 5100 Einführung", "SoSe 26", "", "bestanden", "3", "(Hausarbeit)", "1", "31.08.2026"],
         ["8992", "Vorläufige Gesamtnote aller Fächer", "2,3", "", "16", "", "", ""],
         [second], long,
         ["10", "Zweitfach", "", "", "4", "", "", ""],
         ["7011", "TM: Psychologie / 0810 Grundlagen", "WiSe 25/26", "", "bestanden", "4", "(Klausur)", "1", "10.02.2026"]]
    }

    private func stored(_ g: [QISGrade]) -> [[String: JSONValue]] {
        func t(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
        return g.map { ["pruefungsnr": t($0.pruefungsnr), "text": .string($0.text), "semester": t($0.semester), "note": t($0.note),
                        "status": t($0.status), "credits": t($0.credits), "versuch": t($0.versuch), "datum": t($0.datum),
                        "abschluss": t($0.abschluss), "raw": .string($0.raw)] }
    }

    private func lp(_ m: [[String: JSONValue]], _ abschluss: String) -> Double {
        m.filter { $0["abschluss"]?.string == abschluss }.reduce(0) { $0 + ($1["lp_counted"]?.double ?? 0) }
    }

    func testOnlyTheDetailedRowOfEachAchievementRemains() {
        let read = GradeRows.parse(rows: overview) + GradeRows.parse(rows: tabs)
        XCTAssertEqual(read.count, 8 + 10, "Uebersicht 8 (Konto des Zweitfachs ohne Note/Status entfaellt schon beim Lesen), Reiter 10")
        let rows = QISParser.merge(QISParser.numberAttempts(GradeRows.accounts(GradeRows.preferDetailed(read))))
        XCTAssertEqual(rows.count, 10, "jede Leistung einmal, beide Versuche von 4032, drei Konten")
        XCTAssertTrue(rows.filter { !$0.text.hasPrefix(GradeRows.accountPrefix) }.allSatisfy(GradeRows.isDetailed), "keine Kurzfassung mehr")

        // Konto-Zeilen: Felder zurechtgerueckt, als Summe erkennbar
        let accounts = rows.filter { $0.text.hasPrefix(GradeRows.accountPrefix) }
        XCTAssertEqual(accounts.map(\.text), ["Gesamtkonto: Erstfach", "Gesamtkonto: Vorläufige Gesamtnote aller Fächer", "Gesamtkonto: Zweitfach"])
        XCTAssertEqual(accounts.map(\.credits), ["12", "16", "4"])
        XCTAssertEqual(accounts.map(\.note), ["0,0", "2,3", nil])
        XCTAssertTrue(accounts.allSatisfy { $0.semester == nil && $0.status == nil && $0.pruefungsnr == nil })

        // die Rechenlogik zaehlt jetzt, was das LSF selbst als Konto nennt, und jede zaehlende Leistung hat ihr Semester
        let m = GradesModel.model(stored(rows))
        XCTAssertEqual(GradesModel.countedLP(m), 16)
        XCTAssertEqual(m.filter { ($0["text"]?.string ?? "").hasPrefix(GradeRows.accountPrefix) }.count, 3,
                       "beide Faecher haben die Konto-Nummer 10: keines faellt als Doppelte weg")
        XCTAssertEqual(lp(m, first), 12, "BM 1 (6, seine Teilmodule nicht noch einmal) + Rechnen 2 (3, zweiter Versuch) + Einführung (3)")
        XCTAssertEqual(lp(m, second), 4)
        let counted = m.filter { $0["counted"] == .bool(true) }
        XCTAssertEqual(Set(counted.compactMap { $0["semester_norm"]?.string }), ["WiSe 25/26", "SoSe 26"], "bestanden in welchem Semester")
        XCTAssertFalse(counted.contains { ($0["semester_norm"]?.string ?? "").isEmpty })
        XCTAssertTrue(m.filter { ($0["text"]?.string ?? "").hasPrefix(GradeRows.accountPrefix) }
            .allSatisfy { $0["level"]?.string == "bereich" && $0["counted"] == .bool(false) }, "Konten zaehlen nie als Leistung")
        XCTAssertFalse(m.contains { ($0["modul_text"]?.string ?? "").hasPrefix(GradeRows.accountPrefix) }, "ein Konto ist nie das Modul einer Pruefung")

        // so war es vorher: beide Fassungen zusammen zaehlen mehrfach
        let before = GradesModel.model(stored(QISParser.merge(QISParser.numberAttempts(read))))
        XCTAssertGreaterThan(GradesModel.countedLP(before), 16, "Kurz- und Langfassung zusammen")
    }

    func testOverviewAloneStaysAsItWas() {
        // gibt es nur die Uebersicht (kein Reiter gelesen), bleibt jede Leistung; die beiden Konten (Note 0,0 ohne Status,
        // "Gesamtnote") werden auch in dieser geraden Form als Summe erkannt
        let read = GradeRows.parse(rows: overview)
        let kept = GradeRows.accounts(GradeRows.preferDetailed(read))
        XCTAssertEqual(kept.count, read.count)
        XCTAssertEqual(kept.filter { $0.text.hasPrefix(GradeRows.accountPrefix) }.map(\.text),
                       ["Gesamtkonto: Erstfach", "Gesamtkonto: Vorläufige Gesamtnote aller Fächer"])
        XCTAssertEqual(kept.filter { !$0.text.hasPrefix(GradeRows.accountPrefix) }, read.filter { !["10", "8992"].contains($0.pruefungsnr ?? "") })
        // aufgefaecherte Zellen (colspan): das Konto steht gerade unter der Kopfzeile des Reiters und wird genauso erkannt
        let straight = GradeRows.parse(rows: [[first], long, ["10", "Erstfach", "", "0,0", "", "12", "", "", ""],
                                              ["8992", "Vorläufige Gesamtnote aller Fächer", "", "2,3", "", "16", "", "", ""]])
        XCTAssertEqual(GradeRows.accounts(straight).map { [$0.text, $0.note ?? "-", $0.credits ?? "-", $0.status ?? "-"] },
                       [["Gesamtkonto: Erstfach", "0,0", "12", "-"], ["Gesamtkonto: Vorläufige Gesamtnote aller Fächer", "2,3", "16", "-"]])
        // Uebersicht und gerader Reiter zusammen (so kommt es mit aufgefaecherten Zellen vom echten LSF): jedes Konto einmal
        let both = QISParser.merge(QISParser.numberAttempts(GradeRows.accounts(GradeRows.preferDetailed(read + straight))))
        XCTAssertEqual(both.filter { $0.text.hasPrefix(GradeRows.accountPrefix) }.map(\.text),
                       ["Gesamtkonto: Erstfach", "Gesamtkonto: Vorläufige Gesamtnote aller Fächer"])
        // eine Leistung ohne Status mit echter Note bleibt eine Leistung
        let graded = QISGrade(pruefungsnr: "4011", text: "TM: Grundlagen I", note: "2,3", credits: "3", abschluss: first)
        XCTAssertEqual(GradeRows.accounts([graded]), [graded])
        // andere Studiengaenge beruehren sich nicht: gleiche Nummer und Bezeichnung in einem anderen Studiengang bleibt
        let other = QISGrade(pruefungsnr: "4010", text: "BM 1: Grundlagen", note: "2,3", status: "bestanden", credits: "6", abschluss: second)
        let detailed = QISGrade(pruefungsnr: "4010", text: "BM 1:  Grundlagen", semester: "WiSe 25/26", note: "2,3", status: "bestanden",
                                credits: "6", abschluss: first)
        let short = QISGrade(pruefungsnr: "4010", text: "BM 1: Grundlagen", note: "2,3", status: "bestanden", credits: "6", abschluss: first)
        XCTAssertEqual(GradeRows.preferDetailed([short, other, detailed]), [other, detailed])
        // eine echte Leistung mit Versuch oder Datum ist nie ein Konto, auch mit Zahl im Status
        let odd = QISGrade(pruefungsnr: "1", text: "Leistung", status: "5", versuch: "1", abschluss: first)
        XCTAssertEqual(GradeRows.accounts([odd]), [odd])
    }

    // MARK: Ganze Seiten wie vom LSF (Uebersicht mit Reitern; Konto-Zeilen fassen zwei Spalten zusammen)

    private func table(_ header: [String], _ rows: [String]) -> String {
        "<tr>" + header.map { "<th>\($0)</th>" }.joined() + "</tr>" + rows.joined()
    }

    private func tr(_ cells: [String]) -> String { "<tr>" + cells.map { "<td>\($0)</td>" }.joined() + "</tr>" }

    /// Konto-Zeile des Reiters: Nummer, Bezeichnung ueber zwei Spalten, dann Note, Status, Bonus und drei leere Zellen
    private func account(_ nr: String, _ name: String, note: String = "", lp: String) -> String {
        "<tr><td>\(nr)</td><td colspan=\"2\">\(name)</td><td>\(note)</td><td></td><td>\(lp)</td><td></td><td></td><td></td></tr>"
    }

    private var signedIn: String { #"<a href="rds?state=user&amp;type=4&amp;category=auth.logout">Abmelden</a>"# }

    private var overviewPage: String {
        signedIn + #"<a href="rds?state=notenspiegelStudent&amp;nodeID=fach1">Erstfach</a><a href="rds?state=notenspiegelStudent&amp;nodeID=fach2">Bildung</a>"#
            + "<table><tr><td colspan=\"5\">\(first)</td></tr>" + table(short, [
                tr(["10", "Erstfach", "0,0", "", "12"]), tr(["4010", "BM 1: Grundlagen", "2,3", "bestanden", "6"]),
                tr(["4011", "TM: Grundlagen I (V) / 3200 Grundlagen 1", "2,3", "bestanden", "3"]),
                tr(["4012", "TM: Grundlagen II (Ü) / 3201 Grundlagen 2", "", "bestanden", "3"]),
                tr(["5020", "BM 2: Anwendung", "", "Prüfung vorhanden", "6"]),
                tr(["5021", "TM: Einführung / 5100 Einführung", "", "bestanden", "3"]),
                tr(["5022", "TM: Anwendung / 5101 Anwendung", "", "bestanden", "3"]),
                tr(["8992", "Vorläufige Gesamtnote aller Fächer", "2,3", "", "23"])]) + "</table>"
    }

    private var firstTab: String {
        signedIn + "<table><tr><td colspan=\"9\">\(first)</td></tr>" + table(long, [
            account("10", "Erstfach", note: "0,0", lp: "12"),
            tr(["4010", "BM 1: Grundlagen", "WiSe 25/26", "2,3", "bestanden", "6", "", "", ""]),
            tr(["4011", "TM: Grundlagen I (V) / 3200 Grundlagen 1", "WiSe 25/26", "2,3", "bestanden", "3", "(Klausur)", "1", "09.02.2026"]),
            tr(["4012", "TM: Grundlagen II (Ü) / 3201 Grundlagen 2", "WiSe 25/26", "", "bestanden", "3", "(Klausur)", "1", "09.02.2026"]),
            tr(["5020", "BM 2: Anwendung", "SoSe 26", "", "Prüfung vorhanden", "6", "", "", ""]),
            tr(["5021", "TM: Einführung / 5100 Einführung", "SoSe 26", "", "bestanden", "3", "(Hausarbeit)", "1", "31.08.2026"]),
            tr(["5022", "TM: Anwendung / 5101 Anwendung", "SoSe 26", "", "bestanden", "3", "(Klausur)", "1", "20.07.2026"]),
            account("8992", "Vorläufige Gesamtnote aller Fächer", note: "2,3", lp: "23")]) + "</table>"
    }

    /// Zweiter Studiengang mit zwei Teilfaechern: nach dem bestandenen Modul des ersten folgt das Konto des zweiten,
    /// dessen Teilleistungen (andere Nummern, frueheres Semester) nicht zu jenem Modul gehoeren
    private var secondTab: String {
        let bildung = "Abschluss: [B5] Zwei-Fächer-Bachelor Studiengang: [ESW] Bildung PO-Version: 2022"
        return signedIn + "<table><tr><td colspan=\"9\">\(bildung)</td></tr>" + table(long, [
            account("700", "Pädagogik", lp: "7"),
            tr(["6210", "VM 1: Handeln", "SoSe 26", "", "bestanden", "7", "", "", ""]),
            tr(["6211", "TM: Praktikum / 0401 Praktikum", "SoSe 26", "", "bestanden", "7", "(Bericht)", "1", "01.07.2026"]),
            account("800", "Psychologie", lp: "4"),
            tr(["8011", "TM: Grundlagen der Psychologie / 0810 Grundlagen", "WiSe 25/26", "", "bestanden", "2", "(Klausur)", "1", "10.02.2026"]),
            tr(["8012", "TM: Lehren und Lernen / 0811 Lernen", "SoSe 26", "", "bestanden", "2", "(Klausur)", "1", "15.07.2026"])]) + "</table>"
    }

    private func lsf() -> FakeUniTransport {
        let start = signedIn + #"<a href="rds?state=notenspiegelStudent&amp;next=list.vm">Studien-/Prüfungsleistungen (Notenspiegel)</a>"#
        return FakeUniTransport { [overviewPage, firstTab, secondTab] request in
            let u = request.url.absoluteString
            let html = u.contains("nodeID=fach1") ? firstTab : u.contains("nodeID=fach2") ? secondTab
                : u.contains("notenspiegelStudent") ? overviewPage : start
            return UniResponse(status: 200, body: Data(html.utf8))
        }
    }

    func testWholeNotenspiegelCountsWhatTheLSFAccountsSay() async throws {
        let rows = try await LSFClient(transport: lsf(), retry: .none).grades()
        let accounts = rows.filter { $0.text.hasPrefix(GradeRows.accountPrefix) }
        XCTAssertEqual(accounts.map { "\($0.text) \($0.credits ?? "-")" },
                       ["Gesamtkonto: Erstfach 12", "Gesamtkonto: Vorläufige Gesamtnote aller Fächer 23",
                        "Gesamtkonto: Pädagogik 7", "Gesamtkonto: Psychologie 4"], "jedes Konto einmal, auch ohne Note")
        XCTAssertTrue(rows.filter { !$0.text.hasPrefix(GradeRows.accountPrefix) }.allSatisfy(GradeRows.isDetailed))
        let m = GradesModel.model(stored(rows))
        XCTAssertEqual(GradesModel.countedLP(m), 23, "12 + 7 + 4 wie die Konten des LSF")
        XCTAssertEqual(m.filter { ($0["text"]?.string ?? "").hasPrefix(GradeRows.accountPrefix) }.count, 4, "kein Konto faellt als Doppelte weg")
        XCTAssertEqual(lp(m, first), 12)
        let psychology = m.filter { ["8011", "8012"].contains($0["pruefungsnr"]?.string ?? "") }
        XCTAssertEqual(psychology.map { $0["lp_counted"]?.double ?? -1 }, [2, 2], "zaehlen selbst, nicht unter dem Modul des anderen Teilfachs")
        XCTAssertTrue(psychology.allSatisfy { $0["modul_text"] == .null || $0["modul_text"] == nil })
        XCTAssertFalse(m.contains { $0["counted"] == .bool(true) && ($0["semester_norm"]?.string ?? "").isEmpty }, "jede zaehlende Leistung mit Semester")
        // Modulzeile "Prüfung vorhanden" (26.11.2026): bleibt einmal (die kurze Fassung der Uebersicht faellt weg) und ist das
        // Modul der Teilmodule darunter; sie zaehlt nicht selbst
        XCTAssertEqual(rows.filter { $0.pruefungsnr == "5020" }.map { "\($0.text) \($0.status ?? "-") \($0.semester ?? "-")" },
                       ["BM 2: Anwendung Prüfung vorhanden SoSe 26"])
        XCTAssertEqual(m.filter { ["5021", "5022"].contains($0["pruefungsnr"]?.string ?? "") }.compactMap { $0["modul_text"]?.string },
                       ["BM 2: Anwendung", "BM 2: Anwendung"])
        XCTAssertEqual(m.first { $0["pruefungsnr"]?.string == "5020" }?["counted"], .bool(false))
    }

    /// Modulzeilen "Prüfung vorhanden" (echter Notenspiegel 26.11.2026): nur beim LSF (`modules`), nur mit Nummer und nie
    /// eine Bereichszeile; ohne `modules` (QIS der LUH, Anmeldungen) bleibt es wie vorher
    func testPendingModuleRowsStayOnlyInTheLSF() {
        let rows = [[first], long,
                    ["25010", "BM 1: Aufbau der Zahlbereiche", "SoSe 26", "", "Prüfung vorhanden", "14", "", "", ""],
                    ["10010", "Pflichtmodule (mindestens 12 LP)", "", "", "Prüfung vorhanden", "6", "", "", ""],
                    ["", "Vorläufige Gesamtnote aller Fächer", "", "3,45", "Prüfung vorhanden", "", "", "", ""],
                    ["", "Ohne Nummer", "SoSe 26", "", "Prüfung vorhanden", "3", "", "", ""],
                    ["22040", "M 4: Praktische Philosophie", "SoSe 26", "2,7", "Prüfung vorhanden", "3", "", "", ""]]
        XCTAssertEqual(GradeRows.parse(rows: rows, modules: true).map(\.text),
                       ["BM 1: Aufbau der Zahlbereiche", "Vorläufige Gesamtnote aller Fächer", "M 4: Praktische Philosophie"])
        XCTAssertEqual(GradeRows.parse(rows: rows).map(\.text), ["Vorläufige Gesamtnote aller Fächer", "M 4: Praktische Philosophie"],
                       "mit Note blieb die Zeile schon immer")
    }
}
