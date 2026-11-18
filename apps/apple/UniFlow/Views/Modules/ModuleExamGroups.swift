import SwiftUI
import UniFlowCore

/// Block "Klausuren & Altklausuren" geordnet (Wunsch des Inhabers 17.11.2026: zu jeder Klausur genau ihre Loesung):
/// nach Jahrgang, neuester zuerst; jede Klausur mit ihrer Loesung direkt darunter (eingerueckt), Sammel-Loesungen und
/// Loesungen ohne erkannte Klausur am Ende des Jahrgangs. Die Ordnung kommt fertig aus dem Moduldetail
/// (`exam_groups`, Kern `ExamPairs.groups`, PC-Server app/exam_pairs.py); hier wird nur gezeichnet. Dieselbe Ansicht
/// auf iPad, iPhone und Mac.
struct ModuleExamGroups: View {
    let moduleID: Int
    let groups: [JSONValue]
    let targets: [JSONValue]
    let open: (String) -> Void

    /// Gruppen nach Art, die diese Ansicht im Block ersetzt
    static let covered: Set<String> = ["klausuren", "loesungen"]

    /// Gruppen nach Jahrgang eines Wochenblocks; leer bei allen anderen Wochen und bei einem Server ohne die Ordnung
    /// (dann zeichnet der Block wie bisher nach Art)
    static func groups(of w: JSONValue) -> [JSONValue] {
        w.i("week") == -2 ? w.list("exam_groups").filter { !$0.list("files").isEmpty } : []
    }

    /// Steht die Datei als Loesung direkt unter ihrer Klausur?
    static func isPaired(_ f: JSONValue) -> Bool { f.s("exam_role") == "loesung" }

    /// "2 Klausuren, 1 Lösung" hinter dem Jahrgang
    static func summary(_ files: [JSONValue]) -> String {
        let exams = files.filter { $0.s("exam_role") == "klausur" }.count, sols = files.count - exams
        return [exams == 0 ? nil : exams == 1 ? "1 Klausur" : "\(exams) Klausuren",
                sols == 0 ? nil : sols == 1 ? "1 Lösung" : "\(sols) Lösungen"].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
            let files = g.list("files")
            (Text(g.s("label") ?? "") + Text(" · \(Self.summary(files))").font(.uf(12.8, 400)).foregroundColor(UF.muted))
                .ufFont(12.8, 600).foregroundStyle(UF.text2)
                .padding(.top, 12).padding(.bottom, 2).padding(.leading, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(Row.rows(files)) { row in
                let paired = Self.isPaired(row.value)
                HStack(spacing: 2) {
                    if paired {
                        // die Loesung gehoert zur Klausur darueber
                        Text("↳").ufFont(14.5).foregroundStyle(UF.muted).frame(width: 22).accessibilityHidden(true)
                    }
                    ModuleWeekFileRow(moduleID: moduleID, f: row.value, targets: targets) { open(row.value.s("id") ?? "") }
                }
                .accessibilityHint(paired ? "Lösung zur Klausur darüber" : "")
            }
        }
    }
}
