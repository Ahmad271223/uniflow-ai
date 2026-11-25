import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// "Bessere Mitschrift" mit Whisper in der App (docs/WHISPER-MITSCHRIFT.md) ohne Download und ohne Erkennung: Stand der
/// Sprachmodelle auf der Platte, Texte und Knoepfe in jedem Stand, Karte in den Einstellungen, Zuordnung einer Mitschrift
/// zur geladenen Uni-Aufzeichnung. Die echte Erkennung prueft `WhisperLiveTests` (nur auf Wunsch).
@MainActor
final class WhisperViewsAppTests: XCTestCase {

    private nonisolated static let clock = UniFlowClock.fixed(berlin: "2026-11-25T10:20:00")!

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    override func tearDown() {
        WhisperFeature.isEnabled = true
        super.tearDown()
    }

    private func store() throws -> (WhisperModelStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let suite = "whisper.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (WhisperModelStore(base: base, defaults: defaults), base)
    }

    /// Modellordner wie nach einem Download (mit oder ohne Marke "bereit")
    private func fake(_ choice: WhisperModelChoice, in store: WhisperModelStore, ready: Bool, bytes: Int = 4096) throws {
        let folder = store.folder(choice)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: folder.appendingPathComponent("AudioEncoder.bin"))
        if ready { try Data().write(to: folder.appendingPathComponent(WhisperModelStore.marker)) }
    }

    private func api(_ t: AIViewsAppTests.Transport) -> APIClient { APIClient(base: APIClient.localBase, transport: t) }

    // MARK: Texte

    func testTextsSizesAndActionLabels() {
        XCTAssertEqual(WhisperText.size(626), "626 MB")
        XCTAssertEqual(WhisperText.size(1540), "1,5 GB")
        XCTAssertEqual(WhisperText.percent(0.426), "43 %")
        XCTAssertEqual(WhisperText.percent(7), "100 %")
        XCTAssertEqual(WhisperText.confirmDownload(WhisperModels.gross), "Sprachmodell „Genau“ laden? Das sind 626 MB – am besten im WLAN.")
        XCTAssertEqual(WhisperText.status(active: nil, bytes: 0), "Kein Sprachmodell geladen.")
        XCTAssertEqual(WhisperText.status(active: WhisperModels.klein, bytes: 221_000_000), "Sprachmodell „Kompakt“ geladen (221 MB).")
        // Knopf an einer Aufnahme
        XCTAssertEqual(WhisperText.action(sections: 0, status: "none", engine: nil), "Mitschrift erstellen")
        XCTAssertEqual(WhisperText.action(sections: 12, status: "done", engine: nil), "Genauer erkennen")
        XCTAssertEqual(WhisperText.action(sections: 12, status: "done", engine: "apple"), "Genauer erkennen")
        XCTAssertEqual(WhisperText.action(sections: 4, status: "partial", engine: "whisper"), "Weiter erkennen")
        XCTAssertEqual(WhisperText.action(sections: 0, status: "running", engine: "whisper"), "Mitschrift erstellen")
        XCTAssertNil(WhisperText.action(sections: 30, status: "done", engine: "whisper"), "fertig mit Whisper: kein Knopf")
        // die Erklaerung nennt, was das Geraet verlaesst und was nicht – ohne Versprechen zur Fehlerfreiheit
        XCTAssertTrue(WhisperText.long.contains("verlassen das Gerät dabei nicht") && WhisperText.long.contains("Hugging Face")
                      && WhisperText.long.contains("IP-Adresse") && WhisperText.long.contains("kann Fehler enthalten"))
        XCTAssertEqual(VideoTranscriptIndex.label(nil), "Mitschrift erstellen")
        XCTAssertEqual(VideoTranscriptIndex.label("done"), "Mitschrift")
        XCTAssertEqual(VideoTranscriptIndex.label("partial"), "Mitschrift (teilweise)")
    }

    func testSpaceCheckBeforeDownload() {
        XCTAssertTrue(WhisperModelStore.enoughSpace(megabytes: 626, free: 2_000_000_000))
        XCTAssertFalse(WhisperModelStore.enoughSpace(megabytes: 626, free: 700_000_000))
        XCTAssertTrue(WhisperModelStore.enoughSpace(megabytes: 626, free: nil), "ohne Zahl vom System nicht sperren")
    }

    // MARK: Stand der Modelle

    func testStoreReadsModelsFromDiskAndRemembersTheChoice() async throws {
        let (store, base) = try store()
        XCTAssertNil(store.active)
        XCTAssertEqual(store.state(WhisperModels.gross), .missing)
        XCTAssertEqual(store.bytesOnDisk(WhisperModels.gross), 0)
        XCTAssertTrue(store.folder(WhisperModels.klein).path.hasPrefix(base.path))
        XCTAssertTrue(store.folder(WhisperModels.klein).path.hasSuffix("models/argmaxinc/whisperkit-coreml/openai_whisper-small_216MB"))

        // angefangener Download: belegt Platz, zaehlt aber nicht als geladen
        try fake(WhisperModels.gross, in: store, ready: false)
        store.refresh()
        XCTAssertEqual(store.state(WhisperModels.gross), .missing)
        XCTAssertGreaterThan(store.bytesOnDisk(WhisperModels.gross), 0)
        XCTAssertNil(store.active)
        store.use(WhisperModels.gross)
        XCTAssertNil(store.active, "ein unfertiges Modell laesst sich nicht waehlen")

        // fertig: wird benutzt; ein zweites aendert die Wahl erst auf Wunsch
        try fake(WhisperModels.klein, in: store, ready: true)
        store.refresh()
        XCTAssertEqual(store.state(WhisperModels.klein), .ready)
        XCTAssertEqual(store.active, WhisperModels.klein)
        try fake(WhisperModels.gross, in: store, ready: true)
        store.refresh()
        XCTAssertEqual(store.active, WhisperModels.gross, "ohne gemerkte Wahl das erste geladene der Liste")
        store.use(WhisperModels.klein)
        store.refresh()
        XCTAssertEqual(store.active, WhisperModels.klein)

        // loeschen: Ordner weg, das andere Modell uebernimmt
        await store.delete(WhisperModels.klein)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(WhisperModels.klein).path))
        XCTAssertEqual(store.state(WhisperModels.klein), .missing)
        XCTAssertEqual(store.active, WhisperModels.gross)
        await store.delete(WhisperModels.gross)
        XCTAssertNil(store.active)
    }

    func testJobsRefuseWithoutAModel() throws {
        let (store, _) = try store()
        let jobs = WhisperJobs(store: store)
        let t = AIViewsAppTests.Transport()
        jobs.start(id: "r1", url: URL(fileURLWithPath: "/nicht/da.m4a"), language: "de-DE", api: api(t))
        XCTAssertEqual(jobs.state("r1"), .failed("Kein Sprachmodell geladen."))
        XCTAssertFalse(jobs.isActive("r1"))
        XCTAssertEqual(t.count("PATCH", "/api/recordings/own/r1"), 0, "ohne Modell wird nichts geschrieben")
        jobs.clearFailure("r1")
        XCTAssertNil(jobs.state("r1"))
        // ausgeschaltet: gar kein Stand
        WhisperFeature.isEnabled = false
        jobs.start(id: "r2", url: URL(fileURLWithPath: "/nicht/da.m4a"), language: "de-DE", api: api(t))
        XCTAssertNil(jobs.state("r2"))
    }

    // MARK: Ansichten

    func testModelRowShowsTheRightButtonsInEveryState() throws {
        func labels(_ state: WhisperModelStore.State, active: Bool = false, bytes: Int64 = 0, offered: Bool = true, suggested: Bool = false) throws -> [String] {
            let row = WhisperModelRow(choice: WhisperModels.gross, state: state, isActive: active, bytes: bytes, offered: offered, suggested: suggested,
                                      load: {}, cancel: {}, use: {}, delete: {})
            let env = try hostWithEnvironment(row.padding(), size: CGSize(width: 700, height: 260))
            XCTAssertTrue(env.wait { env.labels().contains("Genau") }, "\(env.labels())")
            return env.labels()
        }
        var l = try labels(.missing, suggested: true)
        XCTAssertTrue(l.contains("626 MB") && l.contains("Laden") && l.contains("Empfohlen"), "\(l)")
        XCTAssertFalse(l.contains("Löschen") || l.contains("Benutzen"), "\(l)")
        l = try labels(.missing, bytes: 120_000_000)
        XCTAssertTrue(l.contains("Fortsetzen") && l.contains("Verwerfen") && l.contains("120 MB schon geladen"), "\(l)")
        l = try labels(.missing, offered: false)
        XCTAssertTrue(l.contains("Für dieses Gerät zu groß."), "\(l)")
        XCTAssertFalse(l.contains("Laden"), "\(l)")
        l = try labels(.downloading(0.42))
        XCTAssertTrue(l.contains("42 %") && l.contains("Abbrechen"), "\(l)")
        XCTAssertFalse(l.contains("Laden"), "\(l)")
        l = try labels(.preparing)
        XCTAssertTrue(l.contains { $0.hasPrefix("Wird für dieses Gerät eingerichtet") }, "\(l)")
        l = try labels(.ready, active: true, bytes: 640_000_000)
        XCTAssertTrue(l.contains("In Benutzung") && l.contains("Löschen"), "\(l)")
        XCTAssertFalse(l.contains("Benutzen") || l.contains("Laden"), "\(l)")
        l = try labels(.ready, bytes: 640_000_000)
        XCTAssertTrue(l.contains("Geladen") && l.contains("Benutzen") && l.contains("Löschen"), "\(l)")
        l = try labels(.failed("Keine Internetverbindung."), bytes: 5_000_000)
        XCTAssertTrue(l.contains("Keine Internetverbindung.") && l.contains("Erneut versuchen") && l.contains("Verwerfen"), "\(l)")
    }

    func testJobStatusLines() throws {
        func labels(_ state: WhisperJobs.State) throws -> [String] {
            let env = try hostWithEnvironment(WhisperJobStatus(state: state) {}.padding(), size: CGSize(width: 700, height: 160))
            XCTAssertTrue(env.wait { !env.labels().isEmpty })
            return env.labels()
        }
        var l = try labels(.running(0.5))
        XCTAssertTrue(l.contains("50 %") && l.contains("Anhalten"), "\(l)")
        l = try labels(.waiting)
        XCTAssertTrue(l.contains("Wartet, bis die andere Mitschrift fertig ist.") && l.contains("Abbrechen"), "\(l)")
        l = try labels(.loadingModel)
        XCTAssertTrue(l.contains("Sprachmodell wird geladen …"), "\(l)")
        l = try labels(.failed("Die Datei hat keine Tonspur."))
        XCTAssertEqual(l, ["Mitschrift nicht möglich: Die Datei hat keine Tonspur."])
    }

    func testSettingsCardWithoutAModelAndSwitchedOff() throws {
        // das Geraet der Tests hat kein Sprachmodell geladen
        try XCTSkipIf(WhisperModelStore.shared.active != nil, "auf diesem Simulator liegt ein Sprachmodell")
        let env = try hostWithEnvironment(WhisperSettingsCard().padding(), size: CGSize(width: 700, height: 420))
        XCTAssertTrue(env.wait { env.labels().contains("Bessere Mitschrift") }, "\(env.labels())")
        let l = env.labels()
        XCTAssertTrue(l.contains("Kein Sprachmodell geladen.") && l.contains("Sprachmodell laden"), "\(l)")
        XCTAssertTrue(l.contains { $0.hasPrefix("Genauere Mitschrift für Aufnahmen und Uni-Videos.") }, "\(l)")
        XCTAssertFalse(l.contains("Geladen"), "\(l)")

        WhisperFeature.isEnabled = false
        let off = try hostWithEnvironment(WhisperSettingsCard().padding(), size: CGSize(width: 700, height: 420))
        XCTAssertFalse(off.wait(timeout: 0.6) { off.labels().contains("Bessere Mitschrift") }, "\(off.labels())")
    }

    /// Mitschrift zu einer Uni-Aufzeichnung in der Ansicht: Hinweis statt Player, Abschnitte, Marke "Whisper", kein
    /// Knopf der Erkennung von Apple, Loeschen fragt nur nach der Mitschrift
    func testDetailOfAVideoTranscript() throws {
        let t = AIViewsAppTests.Transport()
        t.answer("/api/recordings/own/v1", ["id": "v1", "module_id": 1, "module_name": "Analysis I", "title": "Analysis I – 3. Vorlesung", "duration": 5400,
                                            "recorded_at": "2026-11-25T10:20:00", "transcript_status": "done", "sections": 2, "audio_path": .null,
                                            "source_video_id": "kurs1|video7", "transcript_engine": "whisper",
                                            "transcript": [["start": 0, "end": 61, "text": "Heute der Mittelwertsatz."], ["start": 61, "end": 130, "text": "Dann Taylor."]]])
        let env = try hostWithEnvironment(OwnRecordingDetail(id: "v1") {}.padding(), api: api(t), size: CGSize(width: 900, height: 900))
        XCTAssertTrue(env.wait { env.labels().contains("Heute der Mittelwertsatz.") }, "\(env.labels())")
        let l = env.labels()
        XCTAssertTrue(l.contains("Whisper"), "\(l)")
        XCTAssertTrue(l.contains(UFDevice.adapt("Das Video ist nicht mehr auf diesem iPad geladen. Die Mitschrift bleibt.")), "ohne Container kein Video: \(l)")
        XCTAssertFalse(l.contains(UFDevice.adapt("Die Audiodatei liegt nicht mehr auf diesem iPad.")), "\(l)")
        XCTAssertFalse(l.contains("Mitschrift nachholen") || l.contains("Abspielen"), "\(l)")
        XCTAssertFalse(l.contains("Genauer erkennen") || l.contains("Weiter erkennen") || l.contains("Bessere Mitschrift …"), "ohne Datei kein Knopf: \(l)")
        XCTAssertEqual(t.count("PATCH", "/api/recordings/own/v1"), 0)
    }

    /// Bilder der neuen Ansichten fuer die Durchsicht (nur mit UF_WHISPER_SHOTS=<Ordner>; xcodebuild:
    /// TEST_RUNNER_UF_WHISPER_SHOTS): Dialog ohne Modell, Zeilen in den Staenden, Karte, Mitschrift zu einem Video –
    /// je einmal breit (iPad) und schmal (iPhone). Ohne die Variable prueft der Test nur, dass alles ohne Absturz zeichnet.
    func testViewsDrawWideAndNarrow() throws {
        let dir = ProcessInfo.processInfo.environment["UF_WHISPER_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        func shot(_ env: HostedEnvironment, _ name: String) {
            guard let dir else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let png = UIGraphicsImageRenderer(bounds: env.view.bounds, format: format).pngData { _ in
                _ = env.view.drawHierarchy(in: env.view.bounds, afterScreenUpdates: true)
            }
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
        }
        let t = AIViewsAppTests.Transport()
        t.answer("/api/recordings/own/v1", ["id": "v1", "module_id": 1, "module_name": "Analysis I", "title": "Analysis I – 3. Vorlesung", "duration": 5400,
                                            "recorded_at": "2026-11-25T10:20:00", "transcript_status": "done", "sections": 3, "audio_path": .null,
                                            "source_video_id": "kurs1|video7", "transcript_engine": "whisper",
                                            "transcript": [["start": 0, "end": 34, "text": "Guten Morgen zusammen, heute geht es in der Analysis um die Ableitung und um den Mittelwertsatz der Differentialrechnung."],
                                                           ["start": 34, "end": 62, "text": "Ein einfaches Beispiel: Die Ableitung von x² ist 2x. Jetzt zum Mittelwertsatz."],
                                                           ["start": 62, "end": 92, "text": "Der Beweis benutzt den Satz von Rolle. In der Informatik begegnet uns das beim Gradient Descent."]]])
        for (name, size) in [("ipad", CGSize(width: 820, height: 900)), ("iphone", CGSize(width: 393, height: 852))] {
            let rows = VStack(alignment: .leading, spacing: 12) {
                WhisperModelRow(choice: WhisperModels.gross, state: .downloading(0.42), isActive: false, bytes: 260_000_000, offered: true, suggested: true,
                                load: {}, cancel: {}, use: {}, delete: {})
                WhisperModelRow(choice: WhisperModels.klein, state: .ready, isActive: true, bytes: 221_000_000, offered: true, suggested: false,
                                load: {}, cancel: {}, use: {}, delete: {})
                WhisperJobStatus(state: .running(0.37)) {}
            }
            let states = try hostWithEnvironment(rows.padding(16).background(UF.bg), size: CGSize(width: size.width, height: 420))
            XCTAssertTrue(states.wait { states.labels().contains("42 %") && states.labels().contains("37 %") }, "\(states.labels())")
            shot(states, "\(name)-1-modelle-staende")

            let dialog = try hostWithEnvironment(WhisperModelDialog().padding(12).background(UF.bg), size: size)
            XCTAssertTrue(dialog.wait { dialog.labels().contains("Kompakt") && dialog.labels().contains("Fertig") }, "\(dialog.labels())")
            shot(dialog, "\(name)-2-dialog")

            let card = try hostWithEnvironment(WhisperSettingsCard().padding(16).background(UF.bg), size: CGSize(width: size.width, height: 300))
            XCTAssertTrue(card.wait { card.labels().contains("Bessere Mitschrift") }, "\(card.labels())")
            shot(card, "\(name)-3-karte")

            let detail = try hostWithEnvironment(OwnRecordingDetail(id: "v1") {}.padding(12).background(UF.bg), api: api(t), size: size)
            XCTAssertTrue(detail.wait { detail.labels().contains { $0.hasPrefix("Guten Morgen zusammen") } }, "\(detail.labels())")
            shot(detail, "\(name)-4-mitschrift-video")

            // Suche in der Mitschrift, Video geladen (Knopf "Video abspielen", Zeitmarken zum Antippen)
            let found = try hostWithEnvironment(OwnRecordingDetail(id: "v1", findVideo: { _ in URL(fileURLWithPath: "/nicht/da/video7.mp4") }) {}
                .padding(12).background(UF.bg), api: api(t), size: size)
            XCTAssertTrue(found.wait { found.labels().contains("Video abspielen") }, "\(found.labels())")
            XCTAssertTrue(type("mittelwertsatz", in: found))
            XCTAssertTrue(found.wait { found.labels().contains("2 Treffer") }, "\(found.labels())")
            shot(found, "\(name)-5-suche")
        }
    }

    func testBodyForANewVideoTranscript() {
        let video = OpencastVideo(id: "video7", title: "Analysis I – 3. Vorlesung", duration: 5400)
        let entry = OpencastEntry(courseID: "kurs1", courseTitle: "Analysis I", moduleID: 4, video: video, week: 3)
        XCTAssertEqual(entry.id, "kurs1|video7")
        let body = VideoTranscriptControl.body(for: entry)
        XCTAssertEqual(body["source_video_id"], "kurs1|video7")
        XCTAssertEqual(body["title"], "Analysis I – 3. Vorlesung")
        XCTAssertEqual(body["module_id"]?.int, 4)
        XCTAssertEqual(body["course_id"], "kurs1")
        XCTAssertEqual(body["duration"]?.int, 5400)
        XCTAssertEqual(body["language"], "de-DE")
        XCTAssertNil(body["transcript"], "angelegt wird ohne Mitschrift")
    }

    /// Die geladene Datei einer Uni-Aufzeichnung findet die Ansicht ueber "Kurs|Video"; ohne geladene Datei nichts
    func testVideoFileOfATranscriptComesFromTheLoadedRecording() async throws {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let layout = DataContainerLayout(base: c, key: DataContainerKey(userID: "001234.erfunden.whisper", university: .luh))
        try layout.prepare(clock: Self.clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: Self.clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        let files = try XCTUnwrap(host.files)
        let path = "recordings/kurs1/video7.mp4"
        _ = try files.write(Data([0, 1, 2, 3]), to: path)
        try await backend.context.database.transaction { c in
            try OpencastStore.ensureTables(c)
            try c.execute("INSERT INTO opencast_videos(course_id, id, title, local_path, local_quality) VALUES ('kurs1', 'video7', 'VL 3', ?, '720p')", [.text(path)])
            try c.execute("INSERT INTO opencast_videos(course_id, id, title) VALUES ('kurs1', 'video8', 'VL 4')")
        }
        let found = await OwnRecordingDetail.videoFile("kurs1|video7", host: host)
        XCTAssertEqual(found?.lastPathComponent, "video7.mp4")
        let notLoaded = await OwnRecordingDetail.videoFile("kurs1|video8", host: host)
        XCTAssertNil(notLoaded)
        let unknown = await OwnRecordingDetail.videoFile("kurs9|x", host: host)
        XCTAssertNil(unknown)
        let broken = await OwnRecordingDetail.videoFile("ohne-trenner", host: host)
        XCTAssertNil(broken)
    }

    // MARK: Fachwoerter-Hilfe und Lizenzen

    /// Antwort der Route zu einer Wortliste; Fehler, leere Antwort und der Schalter ergeben "ohne Vorgabe"
    func testVocabularyAnswerBecomesAWordList() async {
        let terms = await WhisperJobs.terms { ["terms": ["Taylor-Polynom", "Mittelwertsatz", 7], "files": 2] }
        XCTAssertEqual(terms, ["Taylor-Polynom", "Mittelwertsatz"])
        let none = await WhisperJobs.terms { nil }
        XCTAssertEqual(none, [])
        let failed = await WhisperJobs.terms { throw WhisperFailure("kein Netz") }
        XCTAssertEqual(failed, [])
        WhisperFeature.usesVocabulary = false
        defer { WhisperFeature.usesVocabulary = true }
        let off = await WhisperJobs.terms { ["terms": ["Taylor-Polynom"]] }
        XCTAssertEqual(off, [])
    }

    /// Ohne geladenes Modell gibt es keine Vorgabe (und keinen Absturz); die Grenze laesst dem Text genug Platz
    func testPromptWithoutAModelIsEmptyAndTheLimitIsSmall() async {
        await WhisperEngine.shared.unload()
        let tokens = await WhisperEngine.shared.prompt(terms: ["Taylor-Polynom"], language: "de")
        XCTAssertEqual(tokens, [])
        XCTAssertLessThanOrEqual(WhisperEngine.maxPromptTokens, 48, "die Vorgabe teilt sich 224 Wortteile mit dem erkannten Text")
        XCTAssertTrue(WhisperText.long.contains("Fachbegriffe aus den Vorlesungen und Skripten"))
    }

    /// "Lizenzen" unter Hilfe & Rechtliches: Urheberhinweise und der Wortlaut der MIT-Lizenz (Pflicht der Lizenz)
    func testLicensesDialogNamesWhisperKitAndTheModel() throws {
        XCTAssertEqual(UFOpenSource.notices.map(\.name), ["WhisperKit", "Whisper"])
        XCTAssertTrue(UFOpenSource.notices.allSatisfy { $0.copyright.hasPrefix("Copyright (c) 20") && $0.license == "MIT-Lizenz" })
        XCTAssertTrue(UFOpenSource.mit.contains("The above copyright notice and this permission notice shall be included"))
        XCTAssertTrue(UFOpenSource.mit.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        let env = try hostWithEnvironment(OpenSourceDialog(), size: CGSize(width: 620, height: 760))
        XCTAssertTrue(env.wait { env.labels().contains("Lizenzen") }, "\(env.labels())")
        let l = env.labels().joined(separator: "\n")
        for expected in ["WhisperKit", "Copyright (c) 2024 argmax, inc.", "Copyright (c) 2022 OpenAI", "MIT-Lizenz", "Permission is hereby granted", "Fertig"] {
            XCTAssertTrue(l.contains(expected), "\(expected) fehlt:\n\(l)")
        }
        let card = try hostWithEnvironment(LegalSupportCard().padding(), size: CGSize(width: 700, height: 360))
        XCTAssertTrue(card.wait { card.labels().contains("Lizenzen") && card.labels().contains("Impressum") }, "\(card.labels())")
    }

    // MARK: Suche in der Mitschrift und Sprung ins Video

    /// Text wie mit der Tastatur in das letzte Eingabefeld des Fensters
    @discardableResult
    private func type(_ text: String, in env: HostedEnvironment) -> Bool {
        var fields: [UIView] = []
        func visit(_ v: UIView) {
            if v is UITextView || v is UITextField { fields.append(v); return }
            v.subviews.forEach(visit)
        }
        visit(env.window)
        guard let field = fields.last, let input = field as? UIKeyInput else { return false }
        _ = field.becomeFirstResponder()
        input.insertText(text)
        env.pump(0.3)
        return true
    }

    private func tap(_ label: String, in env: HostedEnvironment) -> Bool {
        guard let b = env.accessibleButton(where: { $0.accessibilityLabel == label }) else { return false }
        let ok = b.accessibilityActivate()
        env.pump(0.3)
        return ok
    }

    private func videoTransport() -> AIViewsAppTests.Transport {
        let t = AIViewsAppTests.Transport()
        t.answer("/api/recordings/own/v1", ["id": "v1", "module_id": 1, "module_name": "Analysis I", "title": "Analysis I – 3. Vorlesung", "duration": 180,
                                            "recorded_at": "2026-11-25T10:20:00", "transcript_status": "done", "sections": 3, "audio_path": .null,
                                            "source_video_id": "kurs1|video7", "transcript_engine": "whisper",
                                            "transcript": [["start": 0, "end": 60, "text": "Guten Morgen zusammen, heute geht es in der Analysis um die Ableitung und um den Mittelwertsatz der Differentialrechnung."],
                                                           ["start": 60, "end": 120, "text": "Ein einfaches Beispiel: Die Ableitung von x² ist 2x. Danach die Näherung beim Pendel."],
                                                           ["start": 120, "end": 180, "text": "Zum Schluss: der Mittelwertsatz ist prüfungsrelevant."]]])
        return t
    }

    /// Wort eintippen -> Treffer mit Ausschnitt und Zeitmarke statt der ganzen Mitschrift; "Leeren" zeigt sie wieder
    func testSearchShowsHitsInsteadOfTheWholeTranscript() throws {
        let env = try hostWithEnvironment(OwnRecordingDetail(id: "v1") {}.padding(), api: api(videoTransport()), size: CGSize(width: 900, height: 900))
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Guten Morgen zusammen") } }, "\(env.labels())")
        XCTAssertFalse(env.labels().contains { $0.hasSuffix("Treffer") || $0 == "Keine Treffer." }, "ohne Eingabe keine Trefferzeile")
        XCTAssertTrue(type("MITTELWERTSATZ", in: env))
        XCTAssertTrue(env.wait { env.labels().contains("2 Treffer") }, "\(env.labels())")
        var l = env.labels()
        XCTAssertTrue(l.contains { $0.hasPrefix("… ") && $0.hasSuffix("um die Ableitung und um den Mittelwertsatz der Differentialrechnung.") }, "\(l)")
        XCTAssertFalse(l.contains { $0.hasPrefix("Guten Morgen zusammen") }, "der Ausschnitt ist gekürzt: \(l)")
        XCTAssertTrue(l.contains("Zum Schluss: der Mittelwertsatz ist prüfungsrelevant."), "\(l)")
        XCTAssertFalse(l.contains { $0.hasPrefix("Ein einfaches Beispiel") }, "Abschnitt ohne Treffer ist weg: \(l)")
        XCTAssertFalse(l.contains { $0.hasPrefix("Springe zu") }, "ohne geladenes Video keine Zeitmarke zum Antippen: \(l)")
        // Leeren: die ganze Mitschrift ist wieder da
        XCTAssertTrue(tap("Leeren", in: env), "\(l)")
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Ein einfaches Beispiel") } }, "\(env.labels())")
        XCTAssertFalse(env.labels().contains("2 Treffer"))
        // Umlaute egal; nichts gefunden
        XCTAssertTrue(type("naherung", in: env))
        XCTAssertTrue(env.wait { env.labels().contains("1 Treffer") }, "\(env.labels())")
        XCTAssertTrue(tap("Leeren", in: env))
        XCTAssertTrue(type("Integral", in: env))
        XCTAssertTrue(env.wait { env.labels().contains("Keine Treffer.") }, "\(env.labels())")
        l = env.labels()
        XCTAssertFalse(l.contains { $0.hasPrefix("Guten Morgen") }, "\(l)")
    }

    /// Geladenes Video: Knopf "Video abspielen" und Hinweis; eine Zeitmarke oder ein Treffer oeffnet das Video in der
    /// Ansicht (der Player bleibt oben stehen)
    func testTimestampOpensTheVideoNextToTheTranscript() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("uf-whisper-video-\(UUID().uuidString).mp4")
        try Data([0, 1, 2, 3]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let env = try hostWithEnvironment(OwnRecordingDetail(id: "v1", findVideo: { _ in file }) {}.padding(), api: api(videoTransport()),
                                          size: CGSize(width: 900, height: 900))
        XCTAssertTrue(env.wait { env.labels().contains("Video abspielen") }, "\(env.labels())")
        var l = env.labels()
        XCTAssertTrue(l.contains(OwnRecordingDetail.videoHint), "\(l)")
        XCTAssertTrue(l.contains("Springe zu 00:00") && l.contains("Springe zu 01:00") && l.contains("Springe zu 02:00"), "\(l)")
        XCTAssertFalse(l.contains { $0.hasPrefix("Das Video ist nicht mehr") }, "\(l)")
        func playerViews() -> Int {
            var n = 0
            func visit(_ v: UIView) {
                if String(describing: Swift.type(of: v)).contains("AVPlayerView") { n += 1 }
                v.subviews.forEach(visit)
            }
            visit(env.window)
            return n
        }
        XCTAssertEqual(playerViews(), 0, "der Player entsteht erst beim Abspielen")
        // Treffer der Suche antippen: das Video erscheint, der Knopf "Video abspielen" ist weg
        XCTAssertTrue(type("prüfungsrelevant", in: env))
        XCTAssertTrue(env.wait { env.labels().contains("1 Treffer") }, "\(env.labels())")
        l = env.labels()
        let jump = try XCTUnwrap(l.first { $0.hasPrefix("Springe zu 02:") }, "\(l)")
        XCTAssertTrue(tap(jump, in: env))
        XCTAssertTrue(env.wait { playerViews() > 0 }, "kein Video in der Ansicht")
        XCTAssertFalse(env.labels().contains("Video abspielen"), "\(env.labels())")
    }

    func testVideoPlayerIsCreatedOnDemandAndReleased() {
        let p = TranscriptVideoPlayer()
        XCTAssertNil(p.player)
        let a = URL(fileURLWithPath: "/nicht/da/a.mp4"), b = URL(fileURLWithPath: "/nicht/da/b.mp4")
        p.seek(a, to: 61)
        let first = p.player
        XCTAssertNotNil(first)
        p.seek(a, to: 5)
        XCTAssertTrue(p.player === first, "dieselbe Datei: derselbe Player")
        p.seek(b, to: 0)
        XCTAssertFalse(p.player === first, "andere Datei: neuer Player")
        p.stop()
        XCTAssertNil(p.player)
    }
}
