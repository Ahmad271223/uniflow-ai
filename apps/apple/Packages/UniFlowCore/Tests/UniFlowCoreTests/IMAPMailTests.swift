import XCTest
@testable import UniFlowCore

/// Uni-Mail ueber IMAP/SMTP (Uni Goettingen, docs/GOETTINGEN-MAIL-2026-11-27.md): reine Funktionen und der ganze Ablauf
/// gegen die Nachbildung des Exchange der GWDG (IMAPFakeServer.swift). Kein Netz.
final class IMAPMailTests: XCTestCase {
    let site = IMAPMailSite.goettingen
    static let now = MailMIME.date("Fri, 27 Nov 2026 10:00:00 +0100")!

    func client(_ fake: IMAPFake, password: String? = "richtig-geheim", user: String = "erika.muster") -> IMAPMailClient {
        IMAPMailClient(site: site, address: site.address(user), opener: fake, now: { Self.now }) {
            password.map { (user, $0) }
        }
    }

    // MARK: Hochschule

    func testGoettingenSite() {
        XCTAssertEqual(site.imapHost, "email.gwdg.de")
        XCTAssertEqual(site.imapPort, 993)
        XCTAssertEqual(site.smtpHost, "email.gwdg.de")
        XCTAssertEqual(site.smtpPort, 587)
        XCTAssertEqual(site.smtpSecurity, .startTLS)
        XCTAssertEqual(site.loginName("erika.muster"), "ug-student\\erika.muster")
        XCTAssertEqual(site.loginName("ug-student\\erika.muster"), "ug-student\\erika.muster")
        XCTAssertEqual(site.loginName(" Erika.Muster@stud.uni-goettingen.de "), "ug-student\\erika.muster", "klein geschrieben")
        XCTAssertEqual(site.address("Erika.Muster"), "erika.muster@stud.uni-goettingen.de")
        XCTAssertEqual(site.account("ug-student\\e.muster"), "e.muster")
        XCTAssertEqual(SOGoSite.for(.goettingen), .goettingen)
        XCTAssertTrue(SOGoSite.goettingen.isIMAP)
        XCTAssertFalse(SOGoSite.luh.isIMAP)
        XCTAssertNil(SOGoSite.for(.hsh))
        XCTAssertEqual(SOGoSite.all, [.luh, .hildesheim], "SOGo-Rechner (Cookies, Webansicht) ohne Göttingen")
        XCTAssertEqual(SOGoSite.goettingen.name, "Uni-Mail (Uni Göttingen)")
    }

    func testOpenerOnlyToUniversityHosts() async {
        let o = SystemMailStreamOpener(site: site)
        do {
            _ = try await o.open(host: "imap.gmail.com", port: 993, tls: true)
            XCTFail("fremder Rechner")
        } catch {
            XCTAssertEqual(error as? MailStreamError, .notAllowed("imap.gmail.com"))
        }
    }

    // MARK: IMAP lesen und schreiben

    func testTokensOfExchangeFetch() throws {
        let raw = Data("3 FETCH (UID 9 FLAGS (\\Seen $Forwarded) RFC822.SIZE 1234 INTERNALDATE \"26-Nov-2026 10:42:00 +0100\" BODY[HEADER.FIELDS (FROM SUBJECT)] {29}\r\nSubject: Hallo (Welt) \"x\"\r\n\r\n)".utf8)
        let t = try IMAP.tokens(raw)
        let f = try XCTUnwrap(IMAP.fetchEntry(t))
        XCTAssertEqual(f["UID"]?.int, 9)
        XCTAssertEqual(f["FLAGS"]?.list?.compactMap(\.text), ["\\Seen", "$Forwarded"])
        XCTAssertEqual(f["RFC822.SIZE"]?.int, 1234)
        XCTAssertEqual(f["INTERNALDATE"]?.text, "26-Nov-2026 10:42:00 +0100")
        XCTAssertEqual(f["BODY[HEADER]"]?.text, "Subject: Hallo (Welt) \"x\"\r\n\r\n")
    }

    func testListStatusSearchAndQuoting() throws {
        let l = try XCTUnwrap(IMAP.listEntry(try IMAP.tokens(Data("LIST (\\HasNoChildren) \"/\" \"Gel&APY-schte Elemente\"".utf8))))
        XCTAssertEqual(l.name, "Gelöschte Elemente")
        XCTAssertEqual(l.delimiter, "/")
        XCTAssertTrue(l.selectable)
        XCTAssertFalse(try XCTUnwrap(IMAP.listEntry(try IMAP.tokens(Data("LIST (\\Noselect) \"/\" Public".utf8)))).selectable)
        XCTAssertEqual(IMAP.statusEntry(try IMAP.tokens(Data("STATUS \"INBOX\" (UNSEEN 4)".utf8)))["UNSEEN"], 4)
        XCTAssertEqual(IMAP.searchEntry(try IMAP.tokens(Data("SEARCH 4 9 12".utf8))), [4, 9, 12])
        XCTAssertEqual(IMAP.searchEntry(try IMAP.tokens(Data("SEARCH".utf8))), [])
        XCTAssertEqual(IMAP.quoted("ug-student\\erika \"x\""), "\"ug-student\\\\erika \\\"x\\\"\"")
        XCTAssertNil(IMAP.quoted("Grüße"), "Nicht-ASCII nur als Literal")
        XCTAssertNil(IMAP.quoted("a\r\nb"), "nie ein Zeilenumbruch in einem Befehl")
        XCTAssertEqual(IMAP.uidSet([9, 1, 2, 3, 7, 3]), "1:3,7,9")
        XCTAssertEqual(IMAP.status("OK [APPENDUID 14 42] APPEND completed.").code, "APPENDUID 14 42")
        XCTAssertEqual(IMAP.appendUID("APPENDUID 14 42"), 42)
        XCTAssertThrowsError(try IMAP.tokens(Data("(UID 9".utf8)))
    }

    func testModifiedUTF7() {
        for (enc, dec) in [("Gel&APY-schte Elemente", "Gelöschte Elemente"), ("Entw&APw-rfe", "Entwürfe"), ("A&-B", "A&B"), ("INBOX", "INBOX"),
                           ("&ZeVnLIqe-", "日本語")] {
            XCTAssertEqual(IMAP.decodeMailbox(enc), dec)
            XCTAssertEqual(IMAP.encodeMailbox(dec), enc)
        }
        XCTAssertEqual(IMAP.decodeMailbox("Kaputt &***-"), "Kaputt &***-")
    }

    // MARK: MIME

    func testMIMEMultipartAlternativeAndAttachment() throws {
        let fake = IMAPFake.goettingen()
        fake.add("INBOX", FakeMails.lecture)
        let data = fake.box("INBOX")!.messages[0].data
        let m = IMAPMailClient.messageJSON(data, folder: "INBOX", uid: 1, flags: [])
        XCTAssertEqual(m["subject"]?.string, "Übungsblatt 3 – Abgabe verschoben")
        XCTAssertEqual(m["from"]?.array?.first?["name"]?.string, "Prof. Dr. Max Müller")
        XCTAssertEqual(m["from"]?.array?.first?["email"]?.string, "max.mueller@uni-goettingen.de")
        XCTAssertEqual(m["cc"]?.array?.first?["email"]?.string, "tutor@uni-goettingen.de")
        XCTAssertEqual(m["date"]?.string, "26.11.2026 10:42")
        let html = try XCTUnwrap(m["html"]?.string)
        XCTAssertTrue(html.contains("<b>Freitag</b>"), "HTML bevorzugt")
        XCTAssertFalse(html.contains("script"), "Skripte entfernt")
        XCTAssertFalse(html.contains(" src="), "keine Bilder aus dem Netz (nur data-blocked-src)")
        XCTAssertEqual(m["remote_blocked"]?.bool, true)
        XCTAssertTrue(m["text"]?.string?.contains("Grüße") == true, "Klartext aus text/plain")
        let att = try XCTUnwrap(m["attachments"]?.array)
        XCTAssertEqual(att.count, 1)
        XCTAssertEqual(att[0]["name"]?.string, "Übungsblatt 3.pdf", "RFC 2231")
        XCTAssertEqual(att[0]["type"]?.string, "application/pdf")
        XCTAssertEqual(IMAPMailClient.parseAttachmentPath(att[0]["path"]?.string ?? "")?.folder, "INBOX")
    }

    func testMIMEPieces() {
        XCTAssertEqual(MailMIME.decodeWords("=?UTF-8?B?w5xidW5n?= =?ISO-8859-1?Q?_f=FCr_alle?="), "Übung für alle")
        XCTAssertEqual(MailMIME.decodeWords("Re: =?utf-8?q?Fr=C3=BChst=C3=BCck?= morgen"), "Re: Frühstück morgen")
        XCTAssertEqual(String(decoding: MailMIME.qp(Data("Gr=C3=BC=C3=9Fe=\r\n weiter".utf8)), as: UTF8.self), "Grüße weiter")
        XCTAssertEqual(MailMIME.decode(Data([0x47, 0x72, 0xFC, 0xDF, 0x65]), charset: "iso-8859-1"), "Grüße")
        XCTAssertEqual(MailMIME.decode(Data([0xA4]), charset: "iso-8859-15"), "€")
        let a = MailMIME.addresses("\"Muster, Erika\" <erika@x.de>, max@y.de, Liste: a@b.de, c@d.de;")
        XCTAssertEqual(a.map { $0["email"]?.string ?? "" }, ["erika@x.de", "max@y.de", "a@b.de", "c@d.de"])
        XCTAssertEqual(a.first?["name"]?.string, "Muster, Erika")
        let p = MailMIME.parameters("attachment; filename*0*=UTF-8''%C3%9Cbung; filename*1=\"sblatt.pdf\"")
        XCTAssertEqual(p.value, "attachment")
        XCTAssertEqual(p.params["filename"], "Übungsblatt.pdf")
        XCTAssertEqual(MailMIME.date("26 Nov 2026 10:42 +0100"), MailMIME.date("Thu, 26 Nov 2026 09:42:00 GMT"))
        XCTAssertNil(MailMIME.date("irgendwann"))
    }

    func testDatesAndSizesLikeSOGo() {
        XCTAssertEqual(IMAPMailClient.relativeDate(MailMIME.date("Fri, 27 Nov 2026 08:15:00 +0100")!, now: Self.now), "08:15")
        XCTAssertEqual(IMAPMailClient.relativeDate(MailMIME.date("Thu, 26 Nov 2026 23:59:00 +0100")!, now: Self.now), "Gestern")
        XCTAssertEqual(IMAPMailClient.relativeDate(MailMIME.date("Mon, 02 Nov 2026 10:00:00 +0100")!, now: Self.now), "02.11.2026")
        XCTAssertEqual(IMAPMailClient.relativeDate(MailMIME.date("Wed, 15 Jul 2026 23:30:00 +0000")!, now: Self.now), "16.07.2026", "Sommerzeit")
        XCTAssertEqual(IMAPMailClient.size(24_000), "24 KB")
        XCTAssertEqual(IMAPMailClient.size(3_500_000), "3,3 MB")
    }

    // MARK: Schreiben

    func testComposeIsSafeAndParsesBack() throws {
        var m = MailCompose.Message(from: "Erika Muster <erika.muster@stud.uni-goettingen.de>", messageID: "abc@studinow.app")
        m.to = ["Prof. Dr. Max Müller <max.mueller@uni-goettingen.de>"]
        m.cc = ["tutor@uni-goettingen.de"]
        m.bcc = ["geheim@stud.uni-goettingen.de"]
        m.subject = "Frage zu Blatt 3\r\nBcc: angreifer@example.org"
        m.text = "Hallo,\n.\nGrüße"
        m.attachments = [.init(name: "Lösung.pdf", mime: "application/pdf", data: Data([1, 2, 3]))]
        m.date = Self.now
        let raw = MailCompose.render(m, boundary: "B")
        let s = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(s.contains("\r\nBcc:"), "Bcc nie im Kopf, auch nicht ueber den Betreff")
        XCTAssertFalse(s.contains("geheim@"), "Bcc-Empfaenger nicht in der Nachricht")
        XCTAssertTrue(s.contains("Date: Fri, 27 Nov 2026 10:00:00 +0100"))
        XCTAssertTrue(s.contains("To: =?UTF-8?B?"), "Name mit Umlaut kodiert")
        XCTAssertTrue(raw.allSatisfy { $0 < 0x80 }, "nur 7 Bit")
        let back = IMAPMailClient.messageJSON(raw, folder: "Gesendete Elemente", uid: 1, flags: [])
        XCTAssertEqual(back["subject"]?.string, "Frage zu Blatt 3 Bcc: angreifer@example.org")
        XCTAssertEqual(back["text"]?.string, "Hallo,\n.\nGrüße")
        XCTAssertEqual(back["to"]?.array?.first?["name"]?.string, "Prof. Dr. Max Müller")
        XCTAssertEqual(back["attachments"]?.array?.first?["name"]?.string, "Lösung.pdf")
        XCTAssertEqual(m.recipients, ["max.mueller@uni-goettingen.de", "tutor@uni-goettingen.de", "geheim@stud.uni-goettingen.de"])
        XCTAssertEqual(MailCompose.subject("AW: Frage", prefix: "Re: "), "AW: Frage")
        XCTAssertEqual(MailCompose.subject("Frage", prefix: "Fwd: "), "Fwd: Frage")
        XCTAssertEqual(String(decoding: SMTPClient.dotStuffed(Data("a\r\n.b\r\n".utf8)), as: UTF8.self), "a\r\n..b\r\n.\r\n")
    }

    // MARK: Ablauf gegen die Nachbildung

    func testMailboxesLikeSOGo() async throws {
        let fake = IMAPFake.goettingen()
        let boxes = try await client(fake).mailboxes()
        XCTAssertEqual(boxes.compactMap { $0["type"]?.string }.prefix(5), ["inbox", "draft", "sent", "trash", "junk"])
        XCTAssertEqual(boxes.compactMap { $0["name"]?.string }, ["Posteingang", "Entwürfe", "Gesendet", "Papierkorb", "Spam", "Archiv", "Uni"])
        XCTAssertEqual(boxes.first { $0["name"]?.string == "Uni" }?["path"]?.string, "INBOX/Uni")
        XCTAssertEqual(boxes.first { $0["name"]?.string == "Uni" }?["level"]?.int, 1)
        XCTAssertFalse(boxes.contains { ($0["path"]?.string ?? "").hasPrefix("Kalender") }, "Kalender, Kontakte usw. von Exchange ausgeblendet")
        XCTAssertEqual(fake.logins, 1)
        XCTAssertEqual(fake.opened.map(\.host), ["email.gwdg.de"])
        XCTAssertEqual(fake.opened.map(\.port), [993])
        XCTAssertTrue(fake.log.contains { $0.contains("AUTHENTICATE ***") }, "AUTH=PLAIN mit SASL-IR")
        XCTAssertNil(fake.wire.range(of: Data("richtig-geheim".utf8)), "Passwort nie im Klartext auf der Leitung")
    }

    func testFolderListingHeadersAndUnseen() async throws {
        let fake = IMAPFake.goettingen()
        fake.add("INBOX", FakeMails.plain, flags: ["\\Seen"], latin1: true)
        for n in 1...55 { fake.add("INBOX", FakeMails.group(n)) }
        fake.add("INBOX", FakeMails.lecture, flags: ["\\Flagged"])
        let c = client(fake)
        let l = try await c.folder("INBOX", query: "")
        XCTAssertEqual(l["total"]?.int, 57)
        XCTAssertEqual(l["pages"]?.int, 2)
        XCTAssertEqual(l["unseen"]?.int, 56)
        let uids = SOGo.flattenUIDs(l["uids"])
        XCTAssertEqual(uids.first, 57, "neueste zuerst")
        let first = try XCTUnwrap(l["messages"]?.array)
        XCTAssertEqual(first.count, 50)
        XCTAssertEqual(first[0]["subject"]?.string, "Übungsblatt 3 – Abgabe verschoben")
        XCTAssertEqual(first[0]["sender"]?.string, "Prof. Dr. Max Müller")
        XCTAssertEqual(first[0]["date"]?.string, "Gestern")
        XCTAssertEqual(first[0]["attachment"]?.bool, true)
        XCTAssertEqual(first[0]["flagged"]?.bool, true)
        XCTAssertEqual(first[0]["read"]?.bool, false)
        let page2 = try await c.headers("INBOX", uids: SOGo.pageUIDs(uids, page: 1))
        XCTAssertEqual(page2.count, 7)
        XCTAssertEqual(page2.last?["subject"]?.string, "Neuer Speiseplan")
        XCTAssertEqual(page2.last?["read"]?.bool, true)
        let found = try await c.folder("INBOX", query: "speiseplan")
        XCTAssertEqual(SOGo.flattenUIDs(found["uids"]), [1])
        let unseen = try await c.unseen("INBOX")
        XCTAssertEqual(unseen, 56)
        XCTAssertEqual(fake.logins, 1, "eine Verbindung fuer alles")
        XCTAssertFalse(fake.log.contains { $0.hasPrefix("VERBOTEN") })
    }

    func testReadMarksSeenAndDownloadsAttachment() async throws {
        let fake = IMAPFake.goettingen()
        fake.add("INBOX", FakeMails.plain, latin1: true)
        let uid = fake.add("INBOX", FakeMails.lecture)
        let c = client(fake)
        let m = try await c.message("INBOX", uid: uid)
        XCTAssertTrue(fake.box("INBOX")!.messages[1].flags.contains("\\Seen"), "Lesen markiert als gelesen (wie SOGo)")
        let plain = try await c.message("INBOX", uid: 1)
        XCTAssertEqual(plain["text"]?.string, "Grüße aus der Mensa.", "ISO-8859-1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imap-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.pdf")
        try await c.download(m["attachments"]?.array?.first?["path"]?.string ?? "", to: file)
        XCTAssertEqual(String(decoding: try Data(contentsOf: file).prefix(8), as: UTF8.self), "%PDF-1.4")
        do {
            try await c.download("https://evil.example/x", to: file)
            XCTFail("fremde Adresse")
        } catch {}
    }

    func testMarkFlagTrashRestoreNeverPermanent() async throws {
        let fake = IMAPFake.goettingen()
        let keep = fake.add("INBOX", FakeMails.group(1), flags: ["\\Deleted"])     // fremd als geloescht markiert: bleibt
        let uid = fake.add("INBOX", FakeMails.group(2))
        let c = client(fake)
        try await c.markRead("INBOX", uid: uid, read: true)
        XCTAssertTrue(fake.box("INBOX")!.messages[1].flags.contains("\\Seen"))
        try await c.markRead("INBOX", uid: uid, read: false)
        XCTAssertFalse(fake.box("INBOX")!.messages[1].flags.contains("\\Seen"))
        try await c.flag("INBOX", uid: uid, flagged: true)
        XCTAssertTrue(fake.box("INBOX")!.messages[1].flags.contains("\\Flagged"))
        try await c.trash("INBOX", uids: [uid])
        XCTAssertEqual(fake.box("INBOX")!.messages.map(\.uid), [keep], "nur diese UID entfernt (UID EXPUNGE), die fremde bleibt")
        XCTAssertEqual(fake.box("Gel&APY-schte Elemente")!.messages.count, 1, "liegt im Papierkorb")
        XCTAssertFalse(fake.log.contains { $0.hasPrefix("VERBOTEN") }, "nie CLOSE oder EXPUNGE ohne UID")
        let trashUID = fake.box("Gel&APY-schte Elemente")!.messages[0].uid
        do {
            try await c.trash("Gel&APY-schte Elemente", uids: [trashUID])
            XCTFail("im Papierkorb nicht noch einmal")
        } catch let e as SOGoError {
            XCTAssertEqual(e, .input("Die E-Mail liegt schon im Papierkorb."))
        }
        try await c.move("Gel&APY-schte Elemente", uids: [trashUID], to: "INBOX")
        XCTAssertEqual(fake.box("INBOX")!.messages.count, 2)
        XCTAssertTrue(fake.box("Gel&APY-schte Elemente")!.messages.isEmpty)
    }

    func testWithoutUIDPLUSNoMoveAtAll() async throws {
        let fake = IMAPFake.goettingen()
        fake.capabilities = "IMAP4 IMAP4rev1 AUTH=PLAIN SASL-IR UNSELECT"
        let uid = fake.add("INBOX", FakeMails.group(1))
        do {
            try await client(fake).trash("INBOX", uids: [uid])
            XCTFail("ohne UIDPLUS ablehnen")
        } catch {}
        XCTAssertEqual(fake.box("INBOX")!.messages.count, 1)
        XCTAssertTrue(fake.box("Gel&APY-schte Elemente")!.messages.isEmpty)
        XCTAssertFalse(fake.log.contains { $0.contains("EXPUNGE") || $0.contains("COPY") })
    }

    func testWrongPasswordOnceAndNoCredential() async throws {
        let fake = IMAPFake.goettingen()
        let c = client(fake, password: "falsch")
        do {
            _ = try await c.mailboxes()
            XCTFail("abgelehnt")
        } catch let e as IMAPMailError {
            guard case .rejected = e else { return XCTFail("\(e)") }
            XCTAssertFalse(e.description.contains("falsch"), "Passwort nie in der Meldung")
        }
        XCTAssertEqual(fake.logins, 1, "genau ein Versuch")
        let none = client(fake, password: nil)
        do {
            _ = try await none.mailboxes()
            XCTFail("ohne Passwort")
        } catch {
            XCTAssertEqual(error as? SOGoError, .needsLogin)
        }
        XCTAssertEqual(fake.logins, 1, "ohne Passwort keine Verbindung")
    }

    func testPlainLOGINWithoutAuthPlain() async throws {
        let fake = IMAPFake.goettingen()
        fake.capabilities = "IMAP4rev1 UIDPLUS UNSELECT LITERAL+"
        fake.password = "mit \"Zeichen\" ü"
        _ = try await client(fake, password: "mit \"Zeichen\" ü").mailboxes()
        XCTAssertTrue(fake.log.contains { $0.contains("LOGIN ***") })
        XCTAssertEqual(fake.failedLogins, 0, "Sonderzeichen als Literal richtig übertragen")
    }

    func testReconnectAfterDropOnRead() async throws {
        let fake = IMAPFake.goettingen()
        fake.add("INBOX", FakeMails.group(1))
        let c = client(fake)
        _ = try await c.mailboxes()
        fake.dropAfterCommands = 0
        let l = try await c.folder("INBOX", query: "")
        XCTAssertEqual(l["total"]?.int, 1)
        let connects = await c.connects
        XCTAssertEqual(connects, 2, "einmal neu verbunden")
    }

    func testReplyDraftSaveAndSendOnce() async throws {
        let fake = IMAPFake.goettingen()
        let uid = fake.add("INBOX", FakeMails.lecture)
        let c = client(fake)
        let d = try await c.newDraft("reply", folder: "INBOX", uid: uid)
        XCTAssertEqual(d["to"]?.array?.compactMap(\.string), ["Prof. Dr. Max Müller <max.mueller@uni-goettingen.de>"])
        XCTAssertEqual(d["subject"]?.string, "Re: Übungsblatt 3 – Abgabe verschoben")
        XCTAssertEqual(d["from"]?.string, "erika.muster@stud.uni-goettingen.de")
        XCTAssertTrue(d["text"]?.string?.contains("Am 26.11.2026 um 10:42 schrieb Prof. Dr. Max Müller:\n> Liebe Studierende,") == true)
        XCTAssertTrue(fake.box("Entw&APw-rfe")!.messages.isEmpty, "Entwurf anlegen legt nichts im Postfach an")
        XCTAssertTrue(fake.deliveries.isEmpty)
        var body = SOGo.payload(d, to: .text("Prof. Dr. Max Müller <max.mueller@uni-goettingen.de>"), cc: .text(""),
                                bcc: .text("ich@stud.uni-goettingen.de"), subject: d["subject"]?.string ?? "", text: "Danke!\n" + (d["text"]?.string ?? ""))
        // speichern: zweimal, die erste Fassung verschwindet
        try await c.save(d, body: body)
        try await c.save(d, body: body)
        XCTAssertEqual(fake.box("Entw&APw-rfe")!.messages.count, 1)
        XCTAssertTrue(fake.box("Entw&APw-rfe")!.messages[0].flags.contains("\\Draft"))
        XCTAssertTrue(fake.deliveries.isEmpty, "Speichern sendet nie")
        // senden
        let r = try await c.send(d, body: body)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.message, "Gesendet.")
        XCTAssertEqual(fake.deliveries.count, 1)
        let sent = fake.deliveries[0]
        XCTAssertEqual(sent.from, "erika.muster@stud.uni-goettingen.de")
        XCTAssertEqual(sent.recipients, ["max.mueller@uni-goettingen.de", "ich@stud.uni-goettingen.de"])
        let text = String(decoding: sent.data, as: UTF8.self)
        XCTAssertTrue(text.contains("In-Reply-To: <blatt3@uni-goettingen.de>"))
        XCTAssertFalse(text.contains("ich@stud"), "Bcc nicht im Kopf")
        XCTAssertFalse(fake.smtpAuthBeforeTLS, "Anmeldung erst nach STARTTLS")
        XCTAssertEqual(fake.smtpLog.prefix(3), ["EHLO studinow.app", "STARTTLS", "EHLO studinow.app"])
        XCTAssertTrue(fake.smtpLog.contains("AUTH LOGIN"), "Exchange bietet nur LOGIN")
        XCTAssertEqual(fake.box("Gesendete Elemente")!.messages.count, 1, "Kopie in Gesendet")
        XCTAssertTrue(fake.box("INBOX")!.messages[0].flags.contains("\\Answered"))
        XCTAssertTrue(fake.box("Entw&APw-rfe")!.messages.isEmpty, "gespeicherter Entwurf nach dem Senden weg")
        let sends = await c.smtpSends
        XCTAssertEqual(sends, 1)
        XCTAssertNil(fake.wire.range(of: Data("richtig-geheim".utf8)))
        // derselbe Entwurf ist nach dem Senden geschlossen: kein zweites Senden
        do {
            _ = try await c.send(d, body: body)
            XCTFail("zweimal")
        } catch {}
        XCTAssertEqual(fake.deliveries.count, 1)
        body["to"] = []
        _ = body
    }

    func testReplyAllAndForward() async throws {
        let fake = IMAPFake.goettingen()
        let g = fake.add("INBOX", FakeMails.group(4))
        let l = fake.add("INBOX", FakeMails.lecture)
        let c = client(fake)
        let all = try await c.newDraft("replyall", folder: "INBOX", uid: g)
        XCTAssertEqual(all["to"]?.array?.compactMap(\.string), ["liste4@stud.uni-goettingen.de", "lena.beispiel@stud.uni-goettingen.de"],
                       "Antwort-an zuerst, ohne mich selbst")
        XCTAssertEqual(all["cc"]?.array?.compactMap(\.string), ["tom.test@stud.uni-goettingen.de"])
        let fwd = try await c.newDraft("forward", folder: "INBOX", uid: l)
        XCTAssertEqual(fwd["subject"]?.string, "Fwd: Übungsblatt 3 – Abgabe verschoben")
        XCTAssertEqual(fwd["to"]?.array?.count, 0)
        XCTAssertEqual(fwd["attachments"]?.array?.first?["name"]?.string, "Übungsblatt 3.pdf", "Anhänge gehen mit")
        let body = SOGo.payload(fwd, to: .text("lena.beispiel@stud.uni-goettingen.de"), cc: .text(""), bcc: .text(""),
                                subject: fwd["subject"]?.string ?? "", text: fwd["text"]?.string ?? "")
        let r = try await c.send(fwd, body: body)
        XCTAssertTrue(r.ok)
        let back = IMAPMailClient.messageJSON(fake.deliveries[0].data, folder: "x", uid: 1, flags: [])
        XCTAssertEqual(back["attachments"]?.array?.first?["name"]?.string, "Übungsblatt 3.pdf")
        XCTAssertTrue(fake.box("INBOX")!.messages[1].flags.contains("$Forwarded"))
    }

    func testSendRefusals() async throws {
        let fake = IMAPFake.goettingen()
        let c = client(fake)
        let d = try await c.newDraft("compose", folder: "INBOX", uid: nil)
        // ungueltige Empfaenger: vor jeder Verbindung
        do {
            _ = try await c.send(d, body: SOGo.payload(d, to: .text("kein-empfaenger"), cc: .text(""), bcc: .text(""), subject: "x", text: "y"))
            XCTFail("ungültig")
        } catch let e as SOGoError {
            guard case .input = e else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(fake.opened.contains { $0.port == 587 })
        // Server lehnt einen Empfaenger ab: nichts geht hinaus
        fake.smtpRejects = ["weg@uni-goettingen.de"]
        let r = try await c.send(d, body: SOGo.payload(d, to: .text("da@uni-goettingen.de, weg@uni-goettingen.de"), cc: .text(""), bcc: .text(""),
                                                       subject: "x", text: "y"))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("weg@uni-goettingen.de"))
        XCTAssertTrue(fake.deliveries.isEmpty)
        XCTAssertFalse(fake.smtpLog.contains("DATA"))
        // ohne STARTTLS: keine Anmeldung, nichts gesendet
        fake.smtpRejects = []
        fake.smtpAdvertisesStartTLS = false
        fake.smtpLog = []
        let r2 = try await c.send(d, body: SOGo.payload(d, to: .text("da@uni-goettingen.de"), cc: .text(""), bcc: .text(""), subject: "x", text: "y"))
        XCTAssertFalse(r2.ok)
        XCTAssertEqual(r2.message, SMTPError.noTLS.description)
        XCTAssertFalse(fake.smtpLog.contains { $0.hasPrefix("AUTH") })
        XCTAssertTrue(fake.deliveries.isEmpty)
        // Verbindung bricht nach dem Absenden ab: "unklar", kein zweiter Versuch
        fake.smtpAdvertisesStartTLS = true
        fake.smtpDropAfterData = true
        let r3 = try await c.send(d, body: SOGo.payload(d, to: .text("da@uni-goettingen.de"), cc: .text(""), bcc: .text(""), subject: "x", text: "y"))
        XCTAssertFalse(r3.ok)
        XCTAssertEqual(r3.message, SMTPError.unknownOutcome.description)
        XCTAssertEqual(fake.smtpLog.filter { $0 == "DATA" }.count, 1)
    }

    func testAttachToDraftLimits() async throws {
        let fake = IMAPFake.goettingen()
        let c = client(fake)
        let d = try await c.newDraft("compose", folder: "INBOX", uid: nil)
        let a = try await c.attach(d, name: "Blatt/3.pdf", data: Data(repeating: 1, count: 2048), mime: "application/pdf")
        XCTAssertEqual(a["name"]?.string, "Blatt_3.pdf")
        XCTAssertEqual(a["size"]?.string, "2 KB")
        do {
            _ = try await c.attach(d, name: "gross.bin", data: Data(count: SOGo.maxAttachment + 1), mime: "")
            XCTFail("zu groß")
        } catch {}
        do {
            _ = try await c.attach(["draft_id": "unbekannt"], name: "x", data: Data([1]), mime: "")
            XCTFail("unbekannter Entwurf")
        } catch {}
    }
}
