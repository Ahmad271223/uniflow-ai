import SwiftUI
import UniFlowCore

// "Frueheres Studium" (07.11.2026): nennt der Notenspiegel mehrere Abschluesse (Studiengangwechsel, Master nach dem
// Bachelor), plant der Studienverlauf nur den aktuellen (`StudyPlanEngine.currentAbschluss`); die Leistungen der
// frueheren stehen hier, eingeklappt, und stoeren den neuen Verlauf nicht. `previous_studies` aus GET /api/study-plan.

/// Ein frueherer Studiengang mit seinen Leistungen
struct StudyPlanPreviousStudy: Equatable, Identifiable {
    struct Grade: Equatable, Identifiable {
        let id: String
        let text: String
        let note: String?
        let status: String?
        let credits: String?
        let semester: String?
        /// trifft ein Modul des aktuellen Katalogs (zaehlt dort als anerkannt)
        let counted: Bool
    }

    let abschluss: String
    let program: String?
    let degree: String?
    let po: String?
    let count: Int
    let passed: Int
    let credits: Double
    let counted: Int
    let grades: [Grade]

    var id: String { abschluss }

    init?(_ v: JSONValue) {
        guard let a = v.s("abschluss"), !a.isEmpty else { return nil }
        abschluss = a
        program = v.s("program").flatMap { $0.isEmpty ? nil : $0 }
        degree = v.s("degree").flatMap { $0.isEmpty ? nil : $0 }
        po = v.s("po") ?? v.i("po").map(String.init)
        grades = v.list("grades").enumerated().compactMap { i, g in
            guard let text = g.s("text"), !text.isEmpty else { return nil }
            func str(_ k: String) -> String? {
                (g.s(k) ?? g.n(k).map { $0 == $0.rounded() ? String(Int($0)) : String($0) }).flatMap { $0.isEmpty ? nil : $0 }
            }
            return Grade(id: "\(i)-\(text)", text: text, note: str("note"), status: str("status"), credits: str("credits"),
                         semester: str("semester"), counted: g["counted"]?.bool ?? false)
        }
        count = v.i("count") ?? grades.count
        passed = v.i("passed") ?? 0
        credits = v.n("credits") ?? 0
        counted = v.i("counted") ?? grades.filter(\.counted).count
    }

    /// "Erziehungswissenschaft (Bachelor, PO 2022)"; ohne Namen die Zeile des Notenspiegels
    var title: String {
        guard let program else { return abschluss }
        let extra = [degree, po.map { "PO \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return extra.isEmpty ? program : "\(program) (\(extra))"
    }

    /// "12 Leistungen · 9 bestanden · 54 LP · 2 im neuen Verlauf angerechnet"
    var summary: String {
        var parts = ["\(count) \(count == 1 ? "Leistung" : "Leistungen")", "\(passed) bestanden"]
        if credits > 0 { parts.append(StudyPlanText.lp(credits)) }
        if counted > 0 { parts.append("\(counted) im aktuellen Verlauf berücksichtigt") }
        return parts.joined(separator: " · ")
    }

    static func list(_ v: JSONValue) -> [StudyPlanPreviousStudy] { v.list("previous_studies").compactMap(StudyPlanPreviousStudy.init) }
}

/// Karte "Früheres Studium": je frueherem Studiengang eine aufklappbare Liste der Leistungen
struct StudyPlanPreviousStudiesCard: View {
    let studies: [StudyPlanPreviousStudy]
    @State private var open: Set<String> = []

    var body: some View {
        UFCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    StudyPlanIconTile(icon: "folder", pair: CommunityPalette.lavender)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(StudyPlanText.previousStudies).ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                            .accessibilityAddTraits(.isHeader)
                        Text(StudyPlanText.previousStudiesSub).ufFont(13.12, lh: 1.45).foregroundStyle(UF.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(studies) { s in study(s) }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .accessibilityIdentifier("studyplan.previous")
    }

    @ViewBuilder private func study(_ s: StudyPlanPreviousStudy) -> some View {
        let isOpen = open.contains(s.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isOpen { open.remove(s.id) } else { open.insert(s.id) }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).ufFont(14.5, 600, lh: 1.3).foregroundStyle(UF.text)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Text(s.summary).ufFont(12.48, lh: 1.35).foregroundStyle(UF.muted)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    UFIcon("chevron-down", size: 16).foregroundStyle(UF.muted).rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(s.title), \(s.summary)")
            .accessibilityValue(isOpen ? "aufgeklappt" : "zugeklappt")
            .accessibilityHint(isOpen ? "Leistungen ausblenden" : "Leistungen zeigen")
            .accessibilityIdentifier("studyplan.previous.toggle")
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(s.grades.enumerated()), id: \.element.id) { i, g in
                        row(g).ufBorderBottom(i < s.grades.count - 1)
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
                .accessibilityIdentifier("studyplan.previous.list")
            }
        }
    }

    private func row(_ g: StudyPlanPreviousStudy.Grade) -> some View {
        let meta = [g.semester, g.credits.map { "\($0) LP" }, g.status].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(g.text).ufFont(13.12, 500, lh: 1.35).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                if !meta.isEmpty {
                    Text(meta).ufFont(12, lh: 1.3).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if g.counted { UFBadge("angerechnet", tone: .ok) }
            if let n = g.note { Text(n).ufFont(13.12, 600).foregroundStyle(UF.text) }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
