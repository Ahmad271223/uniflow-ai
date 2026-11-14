import SwiftUI
import UniFlowCore

// Frage "Was studierst du?" im Einstieg (Auftrag des Inhabers 14.11.2026, Universitaet Hildesheim): Suchfeld und alle
// Studiengaenge des Registers (`GET /api/study-catalog/programs`, 112 der Universitaet Hildesheim), Mehrfachwahl fuer
// Haupt- und Neben- bzw. Begleitfach (Testkonto: B.A. Erziehungswissenschaft mit BWL als Begleitfach). Die Wahl gilt
// vor dem Studiengang aus dem LSF (`POST /api/study-plan/settings {po, minors}`) und ist im Studienverlauf aenderbar.

/// Ein Studiengang zur Wahl
struct IntroProgram: Identifiable, Equatable {
    let id: String
    let program: String
    let degree: String?
    let faculty: String?
    /// Kuerzel der neuesten Pruefungsordnung mit Katalog; nil: StudiNow kennt noch keinen Modulkatalog
    let code: String?
    /// Schreibweisen aus der LSF-Uebersicht (Suche)
    var lsfNames: [String] = []

    /// "Sozialpädagogik (B.A.)"
    var name: String { degree.map { "\(program) (\($0))" } ?? program }

    /// Schluessel zum Speichern: Kuerzel, sonst die ID des Studiengangs
    var key: String { code ?? id }

    /// Liste aus `GET /api/study-catalog/programs`: je Studiengang die neueste PO
    static func list(_ v: JSONValue) -> [IntroProgram] {
        v.list("programs").compactMap { p in
            guard let name = p.s("program"), !name.isEmpty else { return nil }
            let newest = p.list("pos").filter { $0.s("code") != nil }.max { ($0.s("po") ?? "") < ($1.s("po") ?? "") }
            return IntroProgram(id: p.s("id") ?? name, program: name, degree: p.s("degree"), faculty: p.s("faculty"),
                                code: newest?.s("code"), lsfNames: p.list("lsf_names").compactMap(\.string))
        }
    }

    /// Suche wie im Kern (`StudySources.programMatches`: Woerter, Kurzformen wie IMIT, IIM, DaZ/DaF, HRS)
    static func filter(_ all: [IntroProgram], _ q: String) -> [IntroProgram] {
        StudySources.filterPrograms(all, query: q) {
            ["program": .string($0.program), "degree": $0.degree.map { .string($0) } ?? .null,
             "faculty": $0.faculty.map { .string($0) } ?? .null, "lsf_names": .array($0.lsfNames.map(JSONValue.string))]
        }
    }
}

/// Antwortflaeche: gewaehlte Studiengaenge oben (der erste ist das Hauptfach), darunter Suche und Liste
struct IntroProgramAnswer: View {
    @Binding var model: IntroSetupModel
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.chosenPrograms.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.chosenPrograms.enumerated()), id: \.element.id) { i, p in
                        IntroChosenProgramRow(program: p, main: i == 0) { model.toggleProgram(p) }
                    }
                }
            }
            TextField("Studiengang suchen, z. B. Sozialpädagogik", text: $query)
                .ufFont(16, 500)
                .foregroundStyle(UF.text)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.vertical, 12).padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UF.surface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? UF.accent : UF.lineStrong, lineWidth: focused ? 2 : 1))
                .accessibilityIdentifier("intro.program.search")
            if model.programs.isEmpty {
                Text("Die Liste der Studiengänge lädt …").ufFont(13.12).foregroundStyle(UF.muted)
            } else {
                let items = IntroProgram.filter(model.programs, query)
                VStack(spacing: 8) {
                    ForEach(items.prefix(query.isEmpty ? 12 : 40)) { p in
                        IntroProgramToggle(program: p, chosen: model.chosenPrograms.contains(p)) { model.toggleProgram(p) }
                    }
                }
                if items.isEmpty {
                    Text("Kein Studiengang gefunden. Prüfe die Schreibweise.").ufFont(13.12).foregroundStyle(UF.muted)
                } else if query.isEmpty {
                    Text("\(model.programs.count) Studiengänge – tippe den Namen ein, um zu suchen.").ufFont(12.8).foregroundStyle(UF.muted)
                }
            }
            Text("Der erste ist dein Hauptfach, weitere zählen als Neben- oder Begleitfach. Du kannst das später im Studienverlauf ändern.")
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Gewaehlter Studiengang mit Rolle und "Entfernen"
struct IntroChosenProgramRow: View {
    let program: IntroProgram
    let main: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.name).ufFont(15.5, 600).foregroundStyle(UF.text)
                Text(main ? "Hauptfach" : "Neben- oder Begleitfach").ufFont(12.8).foregroundStyle(UF.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) {
                UFIcon("x", size: 14).foregroundStyle(UF.text2).frame(width: 28, height: 28).ufHitArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(program.name) entfernen")
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UF.accentSoft))
    }
}

/// Zeile der Liste: antippen waehlt bzw. entfernt
struct IntroProgramToggle: View {
    let program: IntroProgram
    let chosen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.name).ufFont(15, 600).foregroundStyle(UF.text)
                    Text(program.code == nil ? "ohne Modulkatalog" : (program.faculty ?? "")).ufFont(12.48).foregroundStyle(UF.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                UFIcon(chosen ? "check" : "plus", size: 15)
                    .foregroundStyle(chosen ? Color.white : UF.text2)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chosen ? UF.accentFill : UF.surface2))
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(chosen ? UF.accent : UF.line, lineWidth: chosen ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(program.name)
        .accessibilityValue(chosen ? "gewählt" : (program.code == nil ? "ohne Modulkatalog" : ""))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
