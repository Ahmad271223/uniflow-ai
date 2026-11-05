import SwiftUI
import UIKit
import XCTest
@testable import UniFlow
import UniFlowCore

/// Abgeben aus der App (docs/ABGEBEN-STUDIP-2026-11-05.md): schreibender Transport ueber `UniStubProtocol` (nichts geht
/// ins Netz), Ablauf des Blatts mit Vorauswahl, Neuanmeldung und Verlauf, Blatt selbst mit Bedienungshilfen.
/// Nur erfundene Kurse, Ordner und Namen.
@MainActor
final class StudIPSubmitAppTests: XCTestCase {

    nonisolated private static let course = "0123456789abcdef0123456789abcdef"
    nonisolated private static let lecture = "fedcba9876543210fedcba9876543210"
    nonisolated private static let host = UniversityKey.luh.profile.studipBase?.host ?? ""

    override func tearDown() {
        UniStubProtocol.reset()
        super.tearDown()
    }

    private func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-abgeben-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return d
    }

    nonisolated private static func cookie() -> HTTPCookie {
        HTTPCookie(properties: [.name: "Seminar_Session", .value: "erfunden", .domain: host, .path: "/", .secure: "TRUE"])!
    }

    /// Erfundenes Stud.IP: users/me, Ordner, Lizenzen; POST antwortet `upload`
    nonisolated private static func install(upload: @escaping @Sendable (UniStubProtocol.Seen) -> UniStubProtocol.Reply) {
        UniStubProtocol.install { seen in
            let p = seen.url.absoluteString.removingPercentEncoding ?? seen.url.absoluteString
            if seen.method != "GET" { return upload(seen) }
            if p.contains("/users/me") {
                return .text(#"{"data":{"type":"users","id":"u1","attributes":{"family-name":"Mustermann","given-name":"Erika"}}}"#,
                             headers: ["Content-Type": "application/vnd.api+json"])
            }
            if p.contains("/courses/\(course)/folders") {
                return .text("""
                {"data":[
                 {"type":"folders","id":"root","attributes":{"name":"Analysis I Übung","folder-type":"RootFolder","is-visible":true,"is-writable":false}},
                 {"type":"folders","id":"ue","attributes":{"name":"Übungen","folder-type":"StandardFolder","is-visible":true,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}},
                 {"type":"folders","id":"hw3","attributes":{"name":"Abgabe Blatt 3","folder-type":"HomeworkFolder","is-visible":true,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"ue"}}}},
                 {"type":"folders","id":"hw2","attributes":{"name":"Abgabe Blatt 2","folder-type":"TimedFolder","is-visible":true,"is-writable":false},"relationships":{"parent":{"data":{"type":"folders","id":"ue"}}}}
                ]}
                """, headers: ["Content-Type": "application/vnd.api+json"])
            }
            if p.contains("/terms-of-use") {
                return .text(#"{"data":[{"type":"terms-of-use","id":"SELFMADE_NONPUB","attributes":{"name":"Selbst verfasstes, nicht publiziertes Werk"}}]}"#,
                             headers: ["Content-Type": "application/vnd.api+json"])
            }
            return UniStubProtocol.Reply(status: 404)
        }
    }

    nonisolated private static func created(_ seen: UniStubProtocol.Seen) -> UniStubProtocol.Reply {
        if seen.method == "PATCH" { return UniStubProtocol.Reply(status: 204) }
        return UniStubProtocol.Reply(status: 201, headers: ["Location": "https://\(host)/jsonapi.php/v1/file-refs/neu1",
                                                           "Content-Type": "application/vnd.api+json"])
    }

    private func client() -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: URLSessionStudIPWriter(cookies: [Self.cookie()], host: Self.host,
                                                                             configuration: UniStubProtocol.configuration()),
                     pauseMillis: 0)
    }

    nonisolated private static let pdf = Data("%PDF-1.4\nerfundene Abgabe\n%%EOF".utf8)

    /// Ablauf mit festen Abhaengigkeiten; `readiness` liefert die Antworten von `ensureSession` nacheinander
    private func model(defaults: UserDefaults, readiness: [StudIPSync.SessionReadiness] = [.ready], connected: Bool = true,
                       courseID: String? = nil) -> (StudIPSubmitModel, () -> [Bool]) {
        var answers = readiness
        var pdfCalls: [Bool] = []
        let deps = StudIPSubmitModel.Dependencies(
            connected: { connected },
            ensureSession: { _ in answers.count > 1 ? answers.removeFirst() : (answers.first ?? .ready) },
            client: { self.client() },
            courses: {
                [.init(id: Self.lecture, title: "Analysis I", moduleID: 7, kind: "vorlesung"),
                 .init(id: Self.course, title: "Analysis I Übung", moduleID: 7, kind: "uebung"),
                 .init(id: "abcdefabcdefabcdefabcdefabcdefab", title: "Lineare Algebra", moduleID: 8, kind: "vorlesung")]
            },
            makePDF: { withNotes in
                pdfCalls.append(withNotes)
                return .init(data: Self.pdf + Data(repeating: 0x20, count: withNotes ? 2048 : 0), pages: withNotes ? 6 : 4)
            },
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_793_890_000) })
        let m = StudIPSubmitModel(documentID: "doc1", documentTitle: "Übungsblatt 03", documentCourseID: courseID, moduleID: 7, dependencies: deps)
        return (m, { pdfCalls })
    }

    // MARK: Transport

    /// Multipart kommt mit Cookie, Methode POST und Feld `file` an; Lizenz per PATCH; nichts verlaesst den Stub
    func testWriterSendsMultipartWithSessionCookie() throws {
        Self.install(upload: Self.created)
        let folder = StudIPUploadFolder(id: "hw3", courseID: Self.course, name: "Abgabe Blatt 3", path: "Übungen/Abgabe Blatt 3",
                                        folderType: "HomeworkFolder", isWritable: true)
        let result = try awaiting { try await self.client().upload(Self.pdf, fileName: "Mustermann_Blatt3.pdf", folder: folder) }
        XCTAssertEqual(result.fileRefID, "neu1")
        XCTAssertTrue(result.licenseSet)
        XCTAssertEqual(result.webURL.absoluteString, "https://\(Self.host)/dispatch.php/course/files/index/hw3?cid=\(Self.course)")

        let post = try XCTUnwrap(UniStubProtocol.requests.first { $0.method == "POST" })
        XCTAssertEqual(post.url.path, "/jsonapi.php/v1/folders/hw3/file-refs")
        XCTAssertTrue(post.cookie.contains("Seminar_Session=erfunden"))
        let type = try XCTUnwrap(post.headers.first { $0.key.lowercased() == "content-type" }?.value)
        let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        XCTAssertTrue(post.bodyText.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"Mustermann_Blatt3.pdf\"\r\nContent-Type: application/pdf\r\n\r\n"))
        XCTAssertNotNil(post.body.range(of: Self.pdf))
        XCTAssertTrue(post.bodyText.hasSuffix("\r\n--\(boundary)--\r\n"))
        XCTAssertEqual(UniStubProtocol.requests.filter { $0.method == "PATCH" }.map(\.url.path),
                       ["/jsonapi.php/v1/file-refs/neu1/relationships/terms-of-use"])
        XCTAssertTrue(UniStubProtocol.requests.allSatisfy { $0.url.host == Self.host })
    }

    /// Weiterleitung auf die Anmeldung beim Hochladen = Sitzung abgelaufen (nicht verfolgt, kein zweites POST)
    func testRedirectToLoginOnUploadMeansSessionExpired() throws {
        Self.install { _ in .redirect(302, to: "https://\(Self.host)/dispatch.php/login") }
        let folder = StudIPUploadFolder(id: "hw3", courseID: Self.course, name: "A", path: "A", folderType: "HomeworkFolder", isWritable: true)
        XCTAssertThrowsError(try awaiting { try await self.client().upload(Self.pdf, fileName: "a.pdf", folder: folder) }) { e in
            XCTAssertEqual(e as? StudIPError, .sessionExpired)
        }
        XCTAssertEqual(UniStubProtocol.requests.filter { $0.method == "POST" }.count, 1)
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.path.contains("/login") && $0.method == "POST" })
    }

    /// Der Lese-Transport des Abgleichs kann nicht schreiben
    func testSyncTransportCannotWrite() {
        let t: StudIPTransport = URLSessionStudIPTransport(cookies: [], host: Self.host, configuration: UniStubProtocol.configuration())
        XCTAssertNil(t as? StudIPWritingTransport)
        XCTAssertNotNil(URLSessionStudIPWriter(cookies: [], host: Self.host) as StudIPTransport as? StudIPWritingTransport)
    }

    // MARK: Ablauf

    func testFlowPreselectsCourseFolderAndNameThenRecordsHistory() throws {
        Self.install(upload: Self.created)
        let d = try defaults()
        let (m, pdfCalls) = model(defaults: d)
        try awaiting { await m.start() }
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.courses.map(\.id).prefix(2), [Self.course, Self.lecture], "Übung des Moduls zuerst")
        XCTAssertEqual(m.selectedCourseID, Self.course)
        XCTAssertEqual(m.selectedFolderID, "hw3", "Hausaufgabenordner vorausgewählt")
        XCTAssertEqual(m.folders.writable.map(\.id), ["hw3", "ue"])
        XCTAssertEqual(m.folders.closedSubmissionFolders.map(\.label), ["Übungen/Abgabe Blatt 2"])
        XCTAssertEqual(m.fileName, "Mustermann_Blatt3.pdf")
        XCTAssertEqual(m.previewLine, "6 Seiten · 0,0 MB")
        XCTAssertEqual(pdfCalls(), [true], "Standard: Notizen und Blätter mitschicken")
        XCTAssertTrue(m.canSubmit)

        try awaiting { await m.submit() }
        guard case .done(let record) = m.phase else { return XCTFail("nicht abgegeben: \(m.phase) \(m.errorMessage ?? "")") }
        XCTAssertEqual(record.folderLabel, "Übungen/Abgabe Blatt 3")
        XCTAssertEqual(record.courseTitle, "Analysis I Übung")
        XCTAssertEqual(record.pages, 6)
        XCTAssertTrue(record.withNotes)
        XCTAssertEqual(m.history.count, 1)
        XCTAssertEqual(StudIPSubmissionLog.decode(d.data(forKey: StudIPSubmissionLog.defaultsKey)).records(for: "doc1").count, 1)
        XCTAssertEqual(UniStubProtocol.requests.filter { $0.method == "POST" }.count, 1)
    }

    /// Abgelaufen beim Hochladen: still erneuern, dann genau ein zweiter Versuch
    func testExpiredOnUploadRenewsAndRetriesOnce() throws {
        let posts = Counter()
        Self.install { seen in
            if seen.method == "POST", posts.next() == 1 { return UniStubProtocol.Reply(status: 401) }
            return Self.created(seen)
        }
        let d = try defaults()
        let (m, _) = model(defaults: d, readiness: [.ready, .renewed])
        try awaiting { await m.start() }
        try awaiting { await m.submit() }
        guard case .done = m.phase else { return XCTFail("nicht abgegeben: \(m.phase)") }
        XCTAssertEqual(UniStubProtocol.requests.filter { $0.method == "POST" }.count, 2)
    }

    /// Abgelaufen und still nicht zu erneuern: Anmeldung im Blatt, kein Hochladen
    func testNeedsLoginWhenRenewalFails() throws {
        Self.install(upload: Self.created)
        let (m, _) = model(defaults: try defaults(), readiness: [.needsUser])
        try awaiting { await m.start() }
        XCTAssertEqual(m.phase, .needsLogin)
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.method == "POST" })
        let (n, _) = model(defaults: try defaults(), connected: false)
        try awaiting { await n.start() }
        XCTAssertEqual(n.phase, .notConnected)
    }

    /// Ordner geschlossen (403): Meldung, Abgabe bleibt moeglich nach Wechsel; nichts im Verlauf
    func testClosedFolderShowsMessageAndNoHistory() throws {
        Self.install { _ in .text(#"{"errors":[{"status":"403"}]}"#, status: 403, headers: ["Content-Type": "application/vnd.api+json"]) }
        let d = try defaults()
        let (m, pdfCalls) = model(defaults: d)
        try awaiting { await m.start() }
        try awaiting { await m.submit() }
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.errorMessage, StudIPUploadError.notWritable.errorDescription)
        XCTAssertTrue(m.history.isEmpty)
        XCTAssertNil(d.data(forKey: StudIPSubmissionLog.defaultsKey))
        m.withNotes = false
        try awaiting { while m.preparing || pdfCalls().count < 2 { try await Task.sleep(nanoseconds: 20_000_000) } }
        XCTAssertEqual(pdfCalls(), [true, false])
        XCTAssertEqual(m.previewLine, "4 Seiten · 0,0 MB")
    }

    func testCoursesFromLocalBackendKeepOnlyStudIPCourses() throws {
        let rows = try JSONValue.parse(Data("""
        [{"id":"__user__","title":"Eigene Dokumente","active":1},
         {"id":"lw-55","title":"Learnweb","active":1},
         {"id":"\(Self.course)","title":"Analysis I Übung","module_id":7,"kind":"uebung","active":1},
         {"id":"\(Self.lecture)","title":"Alt","active":0}]
        """.utf8))
        XCTAssertEqual(StudIPSubmitModel.courses(from: rows).map(\.id), [Self.course])
        XCTAssertEqual(StudIPSubmitModel.preselect([], documentCourseID: nil, moduleID: nil), nil)
    }

    // MARK: Blatt

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        let frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    private func pump(_ seconds: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func elements(_ root: UIView) -> [NSObject] {
        root.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = e as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                if o.accessibilityLabel?.isEmpty == false || !id.isEmpty { out.append(o) }
                for c in o.accessibilityElements ?? [] { visit(c, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 600) { if let c = o.accessibilityElement(at: i) { visit(c, depth: depth + 1) } } }
            }
            if let v = e as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    private func labels(_ root: UIView) -> [String] { elements(root).compactMap(\.accessibilityLabel) }

    private func find(_ root: UIView, label: String) -> NSObject? {
        elements(root).first { ($0.accessibilityLabel ?? "").hasPrefix(label) }
    }

    private func waitFor(_ root: UIView, label: String, seconds: Double = 8) -> NSObject? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let e = find(root, label: label) { return e }
            pump(0.2)
        }
        return nil
    }

    /// Blatt mit Hinweis, Kurs, Ordnern (Abgabeordner oben, geschlossener nicht waehlbar), Name, Schalter, Vorschau;
    /// "Jetzt abgeben" laedt genau einmal hoch, danach "In Stud.IP öffnen". Formularzeilen findet die Bedienungshilfe
    /// ueber ihre Namen (die Kennungen `submit.*` reicht SwiftUI in diesem Testaufbau nicht an die Elemente weiter).
    func testSheetShowsChoicesWarningAndSubmits() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        Self.install(upload: Self.created)
        let (m, _) = model(defaults: try defaults())
        let root = host(StudIPSubmitSheet(model: m))
        XCTAssertNotNil(waitFor(root, label: "Übungen/Abgabe Blatt 3"), "Ordner fehlen: \(labels(root))")
        let all = labels(root)
        let order = all.firstIndex { $0.hasPrefix("Übungen/Abgabe Blatt 3") } ?? .max
        XCTAssertLessThan(order, all.firstIndex { $0 == "Übungen" } ?? .max, "Abgabeordner vor anderen Ordnern")
        XCTAssertTrue(all.contains { $0.contains("Abgabeordner – nur du und die Lehrenden") }, "\(all)")
        XCTAssertFalse(all.contains { $0.hasPrefix("Übungen/Abgabe Blatt 2") }, "geschlossener Abgabeordner nicht wählbar")
        XCTAssertTrue(all.contains { $0.hasPrefix("Derzeit geschlossen") && $0.contains("Abgabe Blatt 2") })
        XCTAssertTrue(all.contains { $0.hasPrefix("Die Datei wird an deine Hochschule hochgeladen") }, "Hinweis fehlt")
        XCTAssertTrue(all.contains { $0.contains("Analysis I Übung") }, "Kurs vorausgewählt")
        XCTAssertTrue(all.contains("Notizen und Blätter mitschicken"))
        XCTAssertTrue(all.contains("6 Seiten · 0,0 MB"))
        XCTAssertEqual(m.fileName, "Mustermann_Blatt3.pdf")
        let confirm = try XCTUnwrap(find(root, label: "Jetzt abgeben"))
        XCTAssertTrue(confirm.accessibilityTraits.contains(.button))
        XCTAssertTrue(confirm.accessibilityActivate())
        XCTAssertNotNil(waitFor(root, label: "In Stud.IP öffnen"), "Ergebnis ohne Link: \(labels(root))")
        XCTAssertTrue(labels(root).contains("Abgegeben"))
        XCTAssertEqual(UniStubProtocol.requests.filter { $0.method == "POST" }.count, 1)
    }
}

/// Zaehler fuer Stub-Antworten (Lade-Thread von URLSession)
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
