import Combine
import SwiftUI
import UniFlowCore

// Fruehere Semester (Wunsch des Inhabers 03.11.2026): Der Abgleich laedt nur die Dateien des aktuellen Semesters.
// Nach dem ersten Abgleich, der Kurse frueherer Semester findet, fragt die App einmal ruhig "Auch frühere Semester
// laden?"; in der Bibliothek stehen die frueheren Semester als eigene Ordner (zugeklappt) mit "Dateien laden" je Kurs
// und je Semester. Daten: `GET /api/older-semesters` (`OlderSemesters` im Kern, nur lokal), geladen wird ueber den
// Abgleich der Hochschule (`StudIPSync.loadOlderFiles`, `HildesheimConnection.loadOlderFiles`).

/// "Dateien laden": Kurse vormerken, dann den Abgleich der Hochschule nur fuer sie starten
@MainActor
enum OlderSemesterLoad {
    static func run(_ courseIDs: [String], api: APIClient, studip: StudIPSync, hildesheim: HildesheimConnection?) async throws -> String? {
        _ = try await api.value("/api/older-semesters/request", method: "POST", body: ["course_ids": .array(courseIDs.map(JSONValue.string))])
        return try await start(studip: studip, hildesheim: hildesheim)
    }

    /// Abgleich der Hochschule fuer die vorgemerkten Kurse (auch nach der Wahl "Frühere Semester auch laden")
    static func start(studip: StudIPSync, hildesheim: HildesheimConnection?) async throws -> String? {
        if studip.offersStudIP { return await studip.loadOlderFiles() }
        return await hildesheim?.loadOlderFiles()
    }

    /// Text zum Stand eines Kurses
    static func status(_ c: JSONValue) -> String {
        let files = c.i("files") ?? 0, done = c.i("downloaded") ?? 0
        if c["requested"]?.bool == true { return "Vorgemerkt, kommt mit dem nächsten Abgleich" }
        if files == 0 { return c["loaded"]?.bool == true ? "Keine Dateien" : "Dateien noch nicht geladen" }
        if done >= files { return "\(files) \(files == 1 ? "Datei" : "Dateien") geladen" }
        if done == 0 { return "\(files) \(files == 1 ? "Datei" : "Dateien") bekannt, nicht geladen" }
        return "\(done) von \(files) Dateien geladen"
    }

    /// Ist bei diesem Kurs noch etwas zu laden? (nie geladen oder nicht alle Dateien da)
    static func needsLoad(_ c: JSONValue) -> Bool {
        c["loaded"]?.bool != true || (c.i("downloaded") ?? 0) < (c.i("files") ?? 0)
    }
}

// MARK: - Frage nach dem ersten Abgleich

/// Zeigt die Frage einmal je Container: nach einem Abgleich (oder beim Oeffnen), wenn noch nie entschieden wurde und
/// es Kurse frueherer Semester gibt. Schon beim Zeigen gilt "Nur aktuelles Semester" als Wahl, die Frage kommt also
/// nie wieder; "Frühere Semester auch laden" aendert sie. Nicht unter XCTest (Logik: `shouldAsk`).
struct OlderSemestersQuestionHost: ViewModifier {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hildesheim) private var hildesheim
    /// eine Pruefung zur Zeit (Oeffnen und Ende eines Abgleichs koennen zusammenfallen: sonst zwei Fragen)
    @State private var checking = false

    func body(content: Content) -> some View {
        content
            .task { await check() }
            .onChange(of: studip.finishedRuns) { _, _ in Task { await check() } }
            .onReceive(hildesheim?.$finishedRuns.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in Task { await check() } }
    }

    /// Frage zeigen? Nur ohne gespeicherte Wahl und mit mindestens einem Kurs eines frueheren Semesters
    static func shouldAsk(_ overview: JSONValue) -> Bool {
        (overview["choice"]?.isNull ?? true) && !(overview["semesters"]?.array ?? []).isEmpty
    }

    private func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard !StudIPSync.isUnderTest(), let api = session.api, api.isLocal, !studip.isRunning, hildesheim?.isRunning != true,
              let overview = try? await api.value("/api/older-semesters"), Self.shouldAsk(overview) else { return }
        // als gefragt merken, bevor die Frage erscheint (ein zweiter Abgleich zeigt sie nicht noch einmal)
        guard (try? await api.value("/api/older-semesters/choice", method: "POST", body: ["choice": "current"])) != nil else { return }
        let courses = (overview["semesters"]?.array ?? []).reduce(0) { $0 + ($1["courses"]?.array?.count ?? 0) }
        overlay.modal { OlderSemestersQuestion(current: overview.s("current") ?? "", courses: courses) }
    }
}

/// "Auch frühere Semester laden?" – ruhig, Vorgabe "Nur aktuelles Semester"
struct OlderSemestersQuestion: View {
    let current: String
    let courses: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.ufClose) private var close

    static func text(current: String, courses: Int) -> String {
        "StudiNow hat die Dateien deines aktuellen Semesters\(current.isEmpty ? "" : " (\(current))") geladen. "
            + "Dazu gibt es \(courses) \(courses == 1 ? "Kurs" : "Kurse") aus früheren Semestern. "
            + "Du kannst ihre Dateien jederzeit später in der Bibliothek laden, je Semester oder je Kurs."
    }

    var body: some View {
        UFDialog("Auch frühere Semester laden?", icon: "folder") {
            Text(Self.text(current: current, courses: courses))
                .ufFont(14.08).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Nur aktuelles Semester", kind: .primary) { close() }
                .frame(minHeight: 44)
            UFButton("Frühere Semester auch laden") {
                close()
                Task {
                    guard let api = session.api,
                          await toast.attempt("Frühere Semester laden", {
                              _ = try await api.value("/api/older-semesters/choice", method: "POST", body: ["choice": "all"])
                          }) else { return }
                    if let note = try? await OlderSemesterLoad.start(studip: studip, hildesheim: hildesheim) { toast.show(note, seconds: 4) }
                }
            }
            .frame(minHeight: 44)
        }
    }
}

// MARK: - Bibliothek: Semester-Ordner

/// Unter den Ordnern des aktuellen Semesters: je frueheres Semester ein zugeklappter Ordner mit seinen Kursen,
/// "Alle laden" fuer das ganze Semester und "Dateien laden" je Kurs. Ein Kurs mit geladenen Dateien oeffnet seinen
/// Kursordner (`c<Kurs-ID>`). Nur lokal; ohne fruehere Semester unsichtbar.
struct LibrarySemestersSection: View {
    let overview: JSONValue
    let reload: () async -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hildesheim) private var hildesheim
    @State private var open: Set<String> = []
    @State private var loading: Set<String> = []

    var body: some View {
        let semesters = overview["semesters"]?.array ?? []
        if !semesters.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Frühere Semester").ufFont(16.32, 700).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
                Text(overview["choice"]?.string == "all"
                     ? "StudiNow lädt die Dateien früherer Semester mit. Einzelne Kurse kannst du hier erneut laden."
                     : "StudiNow lädt nur Dateien des aktuellen Semesters. Frühere Semester kannst du hier je Semester oder je Kurs laden.")
                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(semesters.indices, id: \.self) { i in semester(semesters[i]) }
            }
            .padding(.top, 22.4)
        }
    }

    private func semester(_ s: JSONValue) -> some View {
        let label = s.s("label") ?? "Früheres Semester"
        let courses = s["courses"]?.array ?? []
        let isOpen = open.contains(label)
        let files = courses.reduce(0) { $0 + ($1.i("files") ?? 0) }, done = courses.reduce(0) { $0 + ($1.i("downloaded") ?? 0) }
        let todo = courses.filter(OlderSemesterLoad.needsLoad).compactMap { $0.s("id") }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if isOpen { open.remove(label) } else { open.insert(label) }
                } label: {
                    HStack(spacing: 10) {
                        UFIcon(isOpen ? "chevron-down" : "chevron-right", size: 16).foregroundStyle(UF.text2)
                        RoundedRectangle(cornerRadius: 8).fill(UF.surface2).frame(width: 36, height: 36)
                            .overlay(UFIcon("folder", size: 18).foregroundStyle(UF.text2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).ufFont(15.2, 650).foregroundStyle(UF.text)
                            Text("\(courses.count) \(courses.count == 1 ? "Kurs" : "Kurse")"
                                 + (files > 0 ? " · \(done) von \(files) Dateien geladen" : ""))
                                .ufFont(12.8).foregroundStyle(UF.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label), \(isOpen ? "aufgeklappt" : "zugeklappt")")
                if !todo.isEmpty {
                    UFButton(loading.contains(label) ? "Lädt …" : "Alle laden", icon: "download", size: .small) {
                        load(todo, key: label)
                    }
                    .disabled(!loading.isEmpty)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Dateien aller Kurse aus \(label) laden")
                }
            }
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(courses.indices, id: \.self) { j in course(courses[j]) }
                }
                .padding(.top, 6).padding(.leading, 26)
            }
        }
        .padding(.vertical, 8 + ufB).padding(.horizontal, 14.4 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
    }

    private func course(_ c: JSONValue) -> some View {
        let id = c.s("id") ?? ""
        let hasFiles = (c.i("files") ?? 0) > 0
        return HStack(spacing: 10) {
            Button { router.go(.files(path: LibraryCourses.path(id))) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.s("title") ?? "Kurs").ufFont(14.08, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    Text(OlderSemesterLoad.status(c)).ufFont(12.8).foregroundStyle(UF.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasFiles)
            if OlderSemesterLoad.needsLoad(c) {
                UFButton(loading.contains(id) ? "Lädt …" : "Dateien laden", icon: "download", size: .small) { load([id], key: id) }
                    .disabled(!loading.isEmpty)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Dateien von \(c.s("title") ?? "Kurs") laden")
            }
        }
        .padding(.vertical, 4)
        .ufBorderBottom()
    }

    private func load(_ ids: [String], key: String) {
        guard let api = session.api, !ids.isEmpty else { return }
        loading.insert(key)
        Task {
            defer { loading.remove(key) }
            do {
                if let note = try await OlderSemesterLoad.run(ids, api: api, studip: studip, hildesheim: hildesheim) { toast.show(note, seconds: 4) }
            } catch {
                toast.show("Dateien laden fehlgeschlagen: \(error.localizedDescription)", seconds: 4)
            }
            await reload()
        }
    }
}

/// Kursordner eines frueheren Semesters: Stand der Dateien, "Dateien laden" und die bekannten, noch nicht geladenen
/// Dateien (die geladenen stehen darunter wie in jedem Kursordner)
struct LibraryOlderCourseHeader: View {
    let courseID: String
    let files: [JSONValue]
    let reload: () async -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hildesheim) private var hildesheim
    @State private var loading = false
    @State private var showAll = false

    var body: some View {
        let missing = files.filter { $0.i("downloaded") != 1 }
        UFCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kurs aus einem früheren Semester").ufFont(14.5, 700).foregroundStyle(UF.text)
                    Text(missing.isEmpty && !files.isEmpty ? "Alle \(files.count) Dateien sind geladen."
                         : files.isEmpty ? "Die Dateiliste ist noch nicht geladen."
                         : "\(files.count - missing.count) von \(files.count) Dateien geladen.")
                        .ufFont(13.12).foregroundStyle(UF.muted)
                }
                Spacer(minLength: 0)
                if files.isEmpty || !missing.isEmpty {
                    UFButton(loading ? "Lädt …" : "Dateien laden", icon: "download", kind: .primary) { load() }
                        .disabled(loading).frame(minHeight: 44)
                }
            }
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach((showAll ? missing : Array(missing.prefix(8))).indices, id: \.self) { i in
                        let f = (showAll ? missing : Array(missing.prefix(8)))[i]
                        HStack(spacing: 8) {
                            UFIcon("file", size: 14).foregroundStyle(UF.muted)
                            Text(f.s("name") ?? "").ufFont(13.12).foregroundStyle(UF.text2).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                    }
                    if missing.count > 8 {
                        Button(showAll ? "Weniger anzeigen" : "Alle \(missing.count) anzeigen") { showAll.toggle() }
                            .ufFont(13.12).foregroundStyle(UF.accentText).buttonStyle(.plain).frame(minHeight: 44)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func load() {
        guard let api = session.api else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                if let note = try await OlderSemesterLoad.run([courseID], api: api, studip: studip, hildesheim: hildesheim) { toast.show(note, seconds: 4) }
            } catch {
                toast.show("Dateien laden fehlgeschlagen: \(error.localizedDescription)", seconds: 4)
            }
            await reload()
        }
    }
}
