import SwiftUI
import UniFlowCore

/// Blatt "In Stud.IP abgeben" (docs/ABGEBEN-STUDIP-2026-11-05.md): Kurs, Zielordner (nur beschreibbare, Abgabeordner
/// hervorgehoben), Dateiname, Schalter "Notizen und Blätter mitschicken", Vorschau, deutlicher Hinweis aufs Hochladen,
/// "Jetzt abgeben"; danach "In Stud.IP öffnen" und der Verlauf des Dokuments.
struct StudIPSubmitSheet: View {
    @StateObject private var model: StudIPSubmitModel
    /// Anmeldung im Blatt (abgelaufen und still nicht zu erneuern); nil = keine Anmeldung moeglich (Tests)
    let login: ((@escaping () -> Void) -> AnyView)?
    @State private var showingLogin = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(model: @autoclosure @escaping () -> StudIPSubmitModel, login: ((@escaping () -> Void) -> AnyView)? = nil) {
        _model = StateObject(wrappedValue: model())
        self.login = login
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("In Stud.IP abgeben")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isDone ? "Fertig" : "Abbrechen") { dismiss() }
                            .disabled(model.phase == .uploading)
                            .accessibilityIdentifier("submit.close")
                    }
                }
        }
        .interactiveDismissDisabled(model.phase == .uploading)
        .task { await model.start() }
        .sheet(isPresented: $showingLogin) {
            if let login {
                login {
                    showingLogin = false
                    Task { await model.signedIn() }
                }
            }
        }
    }

    private var isDone: Bool { if case .done = model.phase { return true }; return false }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Stud.IP wird geprüft …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("submit.loading")
        case .notConnected:
            message(icon: "link.badge.plus", title: "Stud.IP ist nicht verbunden",
                    text: "Melde dich in den Einstellungen unter Stud.IP an. Danach kannst du direkt aus dem Dokument abgeben.",
                    id: "submit.notConnected")
        case .needsLogin:
            VStack(spacing: 16) {
                message(icon: "person.badge.key", title: "Bitte bei Stud.IP anmelden",
                        text: "Deine Stud.IP-Anmeldung ist abgelaufen und ließ sich nicht still erneuern. Nach der Anmeldung geht es hier weiter.",
                        id: "submit.needsLogin")
                if login != nil {
                    Button("Bei Stud.IP anmelden") { showingLogin = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("submit.login")
                }
            }
        case .done(let record):
            doneView(record)
        case .ready, .uploading:
            form
        }
    }

    private func message(icon: String, title: String, text: String, id: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(UF.accent)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(UF.muted).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: Formular

    private var form: some View {
        Form {
            Section {
                Label {
                    Text("Die Datei wird an deine Hochschule hochgeladen (Stud.IP). Lehrende sehen sie; in normalen Ordnern auch andere Teilnehmende des Kurses.")
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UF.warn) }
                .font(.callout)
                .accessibilityIdentifier("submit.warning")
            }

            Section("Kurs") {
                if model.courses.isEmpty {
                    Text("Keine Stud.IP-Kurse gefunden. Gleiche zuerst Stud.IP ab.").foregroundStyle(UF.muted)
                } else {
                    Picker("Kurs", selection: $model.selectedCourseID) {
                        Text("Kurs wählen").tag(String?.none)
                        ForEach(model.courses) { c in Text(c.title).tag(Optional(c.id)) }
                    }
                    .accessibilityIdentifier("submit.course")
                }
            }

            Section {
                folderList
            } header: {
                Text("Zielordner")
            } footer: {
                if !model.folders.closedSubmissionFolders.isEmpty {
                    Text(closedText).accessibilityIdentifier("submit.closedFolders")
                }
            }

            Section("Datei") {
                TextField("Dateiname", text: $model.fileName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("submit.fileName")
                Toggle("Notizen und Blätter mitschicken", isOn: $model.withNotes)
                    .accessibilityIdentifier("submit.withNotes")
                HStack {
                    if model.preparing { ProgressView().controlSize(.small) }
                    Text(model.preparing ? "PDF wird erstellt …" : (model.previewLine ?? "–"))
                        .foregroundStyle(UF.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("submit.preview")
                if let notice = model.sizeNotice {
                    Label(notice, systemImage: "scalemass").font(.footnote).foregroundStyle(UF.warn)
                        .accessibilityIdentifier("submit.sizeNotice")
                }
            }

            if let err = model.errorMessage {
                Section {
                    Label(err, systemImage: "xmark.octagon").foregroundStyle(.red)
                        .accessibilityIdentifier("submit.error")
                    if let f = model.selectedFolder, let c = model.selectedCourse {
                        Button("Ordner in Stud.IP öffnen") {
                            openURL(StudIPSubmit.folderWebURL(base: StudIPSync.base, courseID: c.id, folderID: f.id))
                        }
                        .accessibilityIdentifier("submit.openFolder")
                    }
                }
            }

            Section {
                Button {
                    Task { await model.submit() }
                } label: {
                    HStack {
                        Spacer()
                        if model.phase == .uploading { ProgressView().padding(.trailing, 6) }
                        Text(model.phase == .uploading ? "Wird abgegeben …" : "Jetzt abgeben").bold()
                        Spacer()
                    }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("submit.confirm")
            }

            historySection
        }
    }

    private var closedText: String {
        let names = model.folders.closedSubmissionFolders.map(\.label).joined(separator: ", ")
        return "Derzeit geschlossen (Frist vorbei oder noch nicht offen): \(names)"
    }

    @ViewBuilder
    private var folderList: some View {
        switch model.folderState {
        case .idle:
            Text(model.selectedCourseID == nil ? "Zuerst einen Kurs wählen." : "–").foregroundStyle(UF.muted)
        case .loading:
            HStack { ProgressView(); Text("Ordner werden geladen …").foregroundStyle(UF.muted) }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).foregroundStyle(.red)
                Button("Erneut versuchen") { Task { await model.loadFolders() } }
            }
            .accessibilityIdentifier("submit.foldersFailed")
        case .loaded:
            if model.folders.writable.isEmpty {
                Text("In diesem Kurs gibt es keinen Ordner, in den du hochladen darfst.")
                    .foregroundStyle(UF.muted)
                    .accessibilityIdentifier("submit.noFolder")
            } else {
                ForEach(model.folders.writable) { f in folderRow(f) }
            }
        }
    }

    private func folderRow(_ f: StudIPUploadFolder) -> some View {
        let selected = model.selectedFolderID == f.id
        return Button {
            model.selectedFolderID = f.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? UF.accent : UF.muted)
                Image(systemName: f.isHomework ? "tray.and.arrow.down.fill" : "folder")
                    .foregroundStyle(f.looksLikeSubmission ? UF.accent : UF.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.label).foregroundStyle(UF.text)
                    if f.isHomework {
                        Text("Abgabeordner – nur du und die Lehrenden sehen deine Datei").font(.caption).foregroundStyle(UF.accentText)
                    } else if f.looksLikeSubmission {
                        Text("Abgabeordner").font(.caption).foregroundStyle(UF.accentText)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(f.isHomework ? UF.accentSoft : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("submit.folder.\(f.id)")
    }

    @ViewBuilder
    private var historySection: some View {
        if !model.history.isEmpty {
            Section("Bisher abgegeben") {
                ForEach(model.history) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.line())
                        Text(r.fileName).font(.caption).foregroundStyle(UF.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("submit.history")
        }
    }

    // MARK: Ergebnis

    private func doneView(_ r: StudIPSubmissionRecord) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(UF.ok)
            Text("Abgegeben").font(.title2.bold())
            Text("\(r.fileName) liegt jetzt in \(r.courseTitle) › \(r.folderLabel).")
                .multilineTextAlignment(.center).foregroundStyle(UF.text2)
            Text("Prüfe in Stud.IP, ob alles angekommen ist.").font(.footnote).foregroundStyle(UF.muted)
            if let url = URL(string: r.url) {
                Button { openURL(url) } label: { Label("In Stud.IP öffnen", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("submit.openInStudIP")
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Einstieg aus dem Dokument: Blatt mit dem Abgleich des Containers (Sitzung, stille Erneuerung, Anmeldung) und der
/// PDF aus `NotesExport` (dieselbe Funktion wie "PDF exportieren", docs/NOTIZEN-MITSCHICKEN-2026-11-05.md 4.2)
struct StudIPSubmitEntry: View {
    let store: DocumentStore
    let api: APIClient
    @EnvironmentObject private var studip: StudIPSync

    var body: some View {
        let store = self.store, api = self.api, studip = self.studip
        let defaults = ActiveContainer.current?.defaults ?? .standard
        StudIPSubmitSheet(
            model: StudIPSubmitModel(
                documentID: store.file.id, documentTitle: store.file.displayTitle,
                documentCourseID: store.file.course_id, moduleID: store.file.module_id,
                dependencies: .live(studip: studip, api: api, defaults: defaults) { withNotes in
                    let r = try await NotesExport.pdf(for: store, api: api,
                                                      options: .init(includeSideNotes: withNotes, fileStem: "Abgabe", folder: "abgabe"))
                    return .init(data: try Data(contentsOf: r.url), pages: r.payload.pageCount)
                }),
            login: { done in
                AnyView(StudIPLoginView(base: StudIPSync.base, dataStore: studip.websiteDataStore) { cookies in
                    studip.signedIn(cookies: cookies)
                    done()
                })
            })
    }

    /// Angebot im Teilen-Menue: nur auf dem Geraet (lokales Backend) an einer Hochschule mit Stud.IP
    static func offered(api: APIClient, readOnly: Bool) -> Bool {
        !readOnly && api.isLocal && ActiveContainer.current?.key.university.profile.studipBase != nil
    }

    /// Letzte Abgabe dieses Dokuments ("Abgegeben am … in …") fuer das Menue; nil ohne Abgabe
    static func lastLine(documentID: String) -> String? {
        let defaults = ActiveContainer.current?.defaults ?? .standard
        return StudIPSubmissionLog.decode(defaults.data(forKey: StudIPSubmissionLog.defaultsKey)).records(for: documentID).first?.line()
    }
}
