import Foundation
import XCTest
@testable import UniFlowCore

// ZIP-Dateien in StudiNow oeffnen und bearbeiten (07.11.2026): Rundlauf Packen/Entpacken, Python-ZIP lesen,
// Zip-Slip, ZIP-Bomben, verschluesselte ZIPs, CP437-Namen und der Arbeitsordner (ZipWorkspace).

/// ZIP von Python `zipfile` (Ordner, DEFLATE, UTF-8-Name "Übung.md", ungepackte Binaerdatei)
private let pythonZip = "UEsDBBQAAAAIAJdiZ10AAAAAAgAAAAAAAAAIAAAAQmxhdHQgMS8DAFBLAwQUAAAACACXYmddIj5J2ycAAABYAgAAEwAAAEJsYXR0IDEvYXVmZ2FiZS50eHRzLE1LT0xKVTC0UohKzUxP1VFISSwuVjDUNrQ10uNyHJUdlSVLFgBQSwMEFAAACAgAl2JnXWcdYQQLAAAACQAAAAkAAADDnGJ1bmcubWRTVjg8J6k0L50LAFBLAwQUAAAAAAAAACEAc4wFKQABAAAAAQAABwAAAHJvaC5iaW4AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CBgoOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr/AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3+Dh4uPk5ebn6Onq6+zt7u/w8fLz9PX29/j5+vv8/f7/UEsBAhQDFAAAAAgAl2JnXQAAAAACAAAAAAAAAAgAAAAAAAAAAAAQAP1BAAAAAEJsYXR0IDEvUEsBAhQDFAAAAAgAl2JnXSI+SdsnAAAAWAIAABMAAAAAAAAAAAAAAIABKAAAAEJsYXR0IDEvYXVmZ2FiZS50eHRQSwECFAMUAAAICACXYmddZx1hBAsAAAAJAAAACQAAAAAAAAAAAAAAgAGAAAAAw5xidW5nLm1kUEsBAhQDFAAAAAAAAAAhAHOMBSkAAQAAAAEAAAcAAAAAAAAAAAAAAIABsgAAAHJvaC5iaW5QSwUGAAAAAAQABADjAAAA1wEAAAAA"

/// Roh-ZIP fuer Angriffsfaelle (ungepackt, Namen und Kennzeichen frei waehlbar)
private struct RawEntry {
    var name: [UInt8]
    var data: Data
    var flags: UInt16 = 0
    var method: UInt16 = 0
    var madeBy: UInt16 = 20
    var external: UInt32 = 0
    var crc: UInt32? = nil
    var declaredSize: UInt32? = nil
    init(_ name: String, _ data: Data = Data("x".utf8)) { self.name = Array(name.utf8); self.data = data }
}

private func rawZip(_ entries: [RawEntry]) -> Data {
    func p16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
    func p32(_ d: inout Data, _ v: UInt32) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    var out = Data(), cd = Data()
    for e in entries {
        let off = UInt32(out.count)
        let crc = e.crc ?? ZipArchive.crc32(e.data)
        let size = e.declaredSize ?? UInt32(e.data.count)
        p32(&out, 0x0403_4b50); p16(&out, 20); p16(&out, e.flags); p16(&out, e.method); p16(&out, 0); p16(&out, 0x21)
        p32(&out, crc); p32(&out, UInt32(e.data.count)); p32(&out, size); p16(&out, UInt16(e.name.count)); p16(&out, 0)
        out.append(contentsOf: e.name); out.append(e.data)
        p32(&cd, 0x0201_4b50); p16(&cd, e.madeBy); p16(&cd, 20); p16(&cd, e.flags); p16(&cd, e.method); p16(&cd, 0); p16(&cd, 0x21)
        p32(&cd, crc); p32(&cd, UInt32(e.data.count)); p32(&cd, size); p16(&cd, UInt16(e.name.count))
        p16(&cd, 0); p16(&cd, 0); p16(&cd, 0); p16(&cd, 0); p32(&cd, e.external); p32(&cd, off)
        cd.append(contentsOf: e.name)
    }
    let cdOff = UInt32(out.count)
    out.append(cd)
    p32(&out, 0x0605_4b50); p16(&out, 0); p16(&out, 0); p16(&out, UInt16(entries.count)); p16(&out, UInt16(entries.count))
    p32(&out, UInt32(cd.count)); p32(&out, cdOff); p16(&out, 0)
    return out
}

final class ZipArchiveTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    // MARK: Rundlauf

    func testPackAndExtractRoundTrip() throws {
        let big = Data(String(repeating: "Lösung zu Aufgabe 3, Teil b) ", count: 4000).utf8)
        let binary = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let items = [
            ZipArchive.Item(path: "Blatt 03", data: nil),
            ZipArchive.Item(path: "Blatt 03/lösung.txt", data: big),
            ZipArchive.Item(path: "Blatt 03/leer", data: nil),
            ZipArchive.Item(path: "Blatt 03/Bilder/skizze.bin", data: binary),
            ZipArchive.Item(path: "Übung.md", data: Data("# Übung\n".utf8)),
            ZipArchive.Item(path: "leer.txt", data: Data()),
        ]
        let zip = try ZipArchive.pack(items)
        XCTAssertTrue(ZipArchive.looksLikeZip(zip))
        XCTAssertLessThan(zip.count, big.count, "Text wird mit DEFLATE kleiner")
        let entries = try ZipArchive.entries(zip)
        XCTAssertEqual(entries.compactMap(\.path), ["Blatt 03", "Blatt 03/lösung.txt", "Blatt 03/leer", "Blatt 03/Bilder/skizze.bin", "Übung.md", "leer.txt"])
        XCTAssertEqual(entries.filter(\.isDirectory).count, 2)
        let dest = tmp.appendingPathComponent("aus")
        let s = try ZipArchive.extract(zip, to: dest)
        XCTAssertEqual(s.files, 4)
        XCTAssertEqual(s.unsafe, [])
        XCTAssertEqual(s.unreadable, [])
        XCTAssertEqual(try read(dest.appendingPathComponent("Blatt 03/lösung.txt")), big)
        XCTAssertEqual(try read(dest.appendingPathComponent("Blatt 03/Bilder/skizze.bin")), binary)
        XCTAssertEqual(try read(dest.appendingPathComponent("leer.txt")), Data())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Blatt 03/leer").path, isDirectory: &isDir) && isDir.boolValue)
        // Ordner wieder packen und erneut entpacken: gleicher Inhalt
        let again = try ZipArchive.pack(directory: dest)
        let dest2 = tmp.appendingPathComponent("aus2")
        try ZipArchive.extract(again, to: dest2)
        for p in ["Blatt 03/lösung.txt", "Blatt 03/Bilder/skizze.bin", "Übung.md", "leer.txt"] {
            XCTAssertEqual(try read(dest2.appendingPathComponent(p)), try read(dest.appendingPathComponent(p)), p)
        }
        XCTAssertEqual(Set(try ZipArchive.entries(again).filter { !$0.isDirectory }.compactMap(\.path)),
                       Set(entries.filter { !$0.isDirectory }.compactMap(\.path)))
        XCTAssertTrue(try ZipArchive.entries(again).contains { $0.path == "Blatt 03/leer" && $0.isDirectory }, "leerer Ordner bleibt")
    }

    func testReadsPythonZipfile() throws {
        let zip = try XCTUnwrap(Data(base64Encoded: pythonZip))
        let dest = tmp.appendingPathComponent("py")
        let s = try ZipArchive.extract(zip, to: dest)
        XCTAssertEqual(s.files, 3)
        XCTAssertEqual(String(decoding: try read(dest.appendingPathComponent("Blatt 1/aufgabe.txt")), as: UTF8.self),
                       String(repeating: "Aufgabe 1: Zeige, dass 1+1=2.\n", count: 20))
        XCTAssertEqual(String(decoding: try read(dest.appendingPathComponent("Übung.md")), as: UTF8.self), "# Übung\n")
        XCTAssertEqual(try read(dest.appendingPathComponent("roh.bin")), Data(0...255))
    }

    func testCRC32MatchesZlib() {
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipArchive.crc32(Data()), 0)
    }

    func testLegacyNamesUseCodepage437() throws {
        XCTAssertEqual(ZipArchive.cp437High.count, 128)
        // "Lösung.txt" wie der Windows-Explorer: 0x94 = ö, ohne UTF-8-Kennzeichen
        var e = RawEntry("x")
        e.name = Array("L".utf8) + [0x94] + Array("sung.txt".utf8)
        let entries = try ZipArchive.entries(rawZip([e]))
        XCTAssertEqual(entries.first?.path, "Lösung.txt")
    }

    // MARK: Sicherheit

    func testSafePathRejectsTraversal() {
        XCTAssertEqual(ZipArchive.safePath("a/./b//c.txt"), "a/b/c.txt")
        XCTAssertEqual(ZipArchive.safePath("ordner\\datei.txt"), "ordner/datei.txt")
        for bad in ["../x", "a/../../x", "a/..", "/etc/passwd", "\\\\server\\x", "..\\win.txt", "C:/x.txt", "C:", "", "/", "a\u{0}b", "ok/\u{1b}x"] {
            XCTAssertNil(ZipArchive.safePath(bad), bad)
        }
        XCTAssertNil(ZipArchive.safePath(String(repeating: "a/", count: 40) + "x"), "zu tief")
    }

    func testZipSlipEntriesAreSkippedNothingOutside() throws {
        let zip = rawZip([RawEntry("../boese.txt"), RawEntry("/abs.txt"), RawEntry("a/../../noch.txt"), RawEntry("..\\win.txt"),
                          RawEntry("C:/laufwerk.txt"), RawEntry("ok/gut.txt", Data("gut".utf8))])
        let dest = tmp.appendingPathComponent("ziel")
        let s = try ZipArchive.extract(zip, to: dest)
        XCTAssertEqual(s.files, 1)
        XCTAssertEqual(s.unsafe.count, 5)
        XCTAssertEqual(try read(dest.appendingPathComponent("ok/gut.txt")), Data("gut".utf8))
        let outside = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertEqual(outside, ["ziel"], "nichts neben dem Ziel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/abs.txt"))
        // auch Packen nimmt keinen unsicheren Pfad an
        XCTAssertThrowsError(try ZipArchive.pack([ZipArchive.Item(path: "../x", data: Data())]))
    }

    func testSymlinkEntriesAreNotCreated() throws {
        var link = RawEntry("link", Data("/etc".utf8))
        link.madeBy = 0x0314
        link.external = UInt32(0o120777) << 16
        let zip = rawZip([link, RawEntry("link/passwd")])
        let dest = tmp.appendingPathComponent("ziel")
        let s = try ZipArchive.extract(zip, to: dest)
        XCTAssertEqual(s.unsafe, ["link"])
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("link").path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeDirectory, "ein Ordner, kein Link")
    }

    func testExtractRefusesSymlinkPlantedInTarget() throws {
        let dest = tmp.appendingPathComponent("ziel")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let outside = tmp.appendingPathComponent("draussen")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("weg"), withDestinationURL: outside)
        XCTAssertThrowsError(try ZipArchive.extract(rawZip([RawEntry("weg/x.txt")]), to: dest))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testZipBombLimits() throws {
        let zeros = Data(count: 2 << 20)
        let bomb = try ZipArchive.pack([ZipArchive.Item(path: "a.bin", data: zeros), ZipArchive.Item(path: "b.bin", data: zeros)])
        let small = ZipArchive.Limits(maxEntries: 10, maxTotalBytes: 3 << 20, maxEntryBytes: 2 << 20)
        XCTAssertThrowsError(try ZipArchive.extract(bomb, to: tmp.appendingPathComponent("b1"), limits: small)) {
            XCTAssertEqual($0 as? ZipArchive.Failure, .tooLarge)
        }
        let tiny = ZipArchive.Limits(maxEntries: 10, maxTotalBytes: 10 << 20, maxEntryBytes: 1 << 20)
        XCTAssertThrowsError(try ZipArchive.entries(bomb, limits: tiny)) { XCTAssertEqual($0 as? ZipArchive.Failure, .tooLarge) }
        let few = ZipArchive.Limits(maxEntries: 1, maxTotalBytes: 10 << 20, maxEntryBytes: 10 << 20)
        XCTAssertThrowsError(try ZipArchive.entries(bomb, limits: few)) { XCTAssertEqual($0 as? ZipArchive.Failure, .tooManyEntries(2)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("b1/a.bin").path), "vor dem Entpacken abgelehnt")
    }

    func testLyingSizeNeverInflatesMore() throws {
        // angegeben 10 Byte, gepackt aber 2 MB Nullen: der Eintrag wird nicht geschrieben
        let zeros = Data(count: 2 << 20)
        let packed = try SolutionDeflate.deflate(zeros)
        var e = RawEntry("klein.txt", packed)
        e.method = 8
        e.crc = ZipArchive.crc32(zeros)
        e.declaredSize = 10
        let dest = tmp.appendingPathComponent("l")
        do {
            let s = try ZipArchive.extract(rawZip([e]), to: dest)
            XCTAssertEqual(s.files, 0)
        } catch {
            XCTAssertEqual(error as? ZipArchive.Failure, .tooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("klein.txt").path))
    }

    func testEncryptedZipGivesClearMessage() throws {
        var e = RawEntry("geheim.pdf")
        e.flags = 1
        XCTAssertThrowsError(try ZipArchive.entries(rawZip([e]))) { err in
            XCTAssertEqual(err as? ZipArchive.Failure, .encrypted)
            XCTAssertTrue(err.localizedDescription.contains("Passwort"))
        }
        var aes = RawEntry("aes.pdf")
        aes.method = 99
        XCTAssertThrowsError(try ZipArchive.entries(rawZip([aes]))) { XCTAssertEqual($0 as? ZipArchive.Failure, .encrypted) }
    }

    func testBrokenInputs() throws {
        XCTAssertThrowsError(try ZipArchive.entries(Data("keine zip".utf8))) { XCTAssertEqual($0 as? ZipArchive.Failure, .notZip) }
        let ok = try ZipArchive.pack([ZipArchive.Item(path: "a.txt", data: Data("hallo".utf8))])
        XCTAssertThrowsError(try ZipArchive.entries(ok.prefix(ok.count - 5)))
        // falsche CRC: Eintrag nicht lesbar, Rest kommt
        var bad = RawEntry("kaputt.txt")
        bad.crc = 1
        let s = try ZipArchive.extract(rawZip([bad, RawEntry("gut.txt")]), to: tmp.appendingPathComponent("c"))
        XCTAssertEqual(s.unreadable, ["kaputt.txt"])
        XCTAssertEqual(s.files, 1)
        // macOS-Beiwerk faellt weg
        let mac = try ZipArchive.extract(rawZip([RawEntry("__MACOSX/._a.txt"), RawEntry("a.txt"), RawEntry("x/.DS_Store")]), to: tmp.appendingPathComponent("m"))
        XCTAssertEqual(mac.files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("m/__MACOSX").path))
    }

    // MARK: Arbeitsordner

    func testWorkspaceEditAndRepack() throws {
        let source = try ZipArchive.pack([
            ZipArchive.Item(path: "Blatt 1", data: nil),
            ZipArchive.Item(path: "Blatt 1/aufgabe.pdf", data: Data("%PDF-1.4 Aufgabe".utf8)),
            ZipArchive.Item(path: "Blatt 1/notiz.txt", data: Data("alt".utf8)),
            ZipArchive.Item(path: "readme.txt", data: Data("lies mich".utf8)),
        ])
        let ws = ZipWorkspace(root: tmp.appendingPathComponent("ws"))
        guard case .extracted(let s) = try ws.prepare(source: source, name: "Blatt.zip") else { return XCTFail("nicht entpackt") }
        XCTAssertEqual(s.files, 3)
        XCTAssertEqual(try ws.prepare(source: source, name: "Blatt.zip"), .kept)
        XCTAssertEqual(try ws.list().map(\.name), ["Blatt 1", "readme.txt"])
        XCTAssertEqual(try ws.list().first?.childCount, 2)
        XCTAssertEqual(try ws.list("Blatt 1").map(\.path), ["Blatt 1/aufgabe.pdf", "Blatt 1/notiz.txt"])

        // Notizen-Verknuepfung folgt dem Umbenennen und faellt bei geaendertem Inhalt weg
        try ws.setLink("doc-1", for: "Blatt 1/aufgabe.pdf")
        XCTAssertEqual(ws.link(for: "Blatt 1/aufgabe.pdf")?.fileID, "doc-1")
        let renamed = try ws.rename("Blatt 1", to: "Abgabe")
        XCTAssertEqual(renamed, "Abgabe")
        XCTAssertEqual(ws.link(for: "Abgabe/aufgabe.pdf")?.fileID, "doc-1")
        try ws.write(Data("neu".utf8), to: "Abgabe/notiz.txt")
        let added = try ws.add(Data("zweite".utf8), named: "notiz.txt", into: "Abgabe")
        XCTAssertEqual(added, "Abgabe/notiz 2.txt")
        try ws.makeFolder(named: "Quellcode", in: "Abgabe")
        try ws.delete("readme.txt")
        try ws.rename("Abgabe/notiz.txt", to: "Notiz.txt")          // nur Gross-/Kleinschreibung
        XCTAssertTrue(ws.meta?.changed == true)
        XCTAssertThrowsError(try ws.rename("Abgabe/Notiz.txt", to: "../raus.txt"))
        XCTAssertThrowsError(try ws.rename("Abgabe/Notiz.txt", to: "notiz 2.txt")) { XCTAssertEqual($0 as? ZipWorkspace.Failure, .exists("notiz 2.txt")) }
        XCTAssertThrowsError(try ws.url("../../x"))
        XCTAssertThrowsError(try ws.add(Data(), named: "..", into: ""))

        // Packen mit ersetzter PDF (Notizen) und wieder entpacken
        let annotated = Data("%PDF-1.4 mit Notizen".utf8)
        let out = try ws.pack(replacing: ["Abgabe/aufgabe.pdf": annotated])
        let check = tmp.appendingPathComponent("check")
        try ZipArchive.extract(out, to: check)
        XCTAssertEqual(try read(check.appendingPathComponent("Abgabe/aufgabe.pdf")), annotated)
        XCTAssertEqual(try read(check.appendingPathComponent("Abgabe/Notiz.txt")), Data("neu".utf8))
        XCTAssertEqual(try read(check.appendingPathComponent("Abgabe/notiz 2.txt")), Data("zweite".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: check.appendingPathComponent("Abgabe/Quellcode").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: check.appendingPathComponent("readme.txt").path))
        XCTAssertEqual(try read(ws.url("Abgabe/aufgabe.pdf")), Data("%PDF-1.4 Aufgabe".utf8), "Original im Arbeitsordner bleibt")

        // neue Fassung der ZIP: eigener Stand bleibt, bis man ausdruecklich neu entpackt
        let newer = try ZipArchive.pack([ZipArchive.Item(path: "neu.txt", data: Data("v2".utf8))])
        XCTAssertEqual(try ws.prepare(source: newer, name: "Blatt.zip"), .keptWithNewerSource)
        guard case .extracted = try ws.prepare(source: newer, name: "Blatt.zip", force: true) else { return XCTFail() }
        XCTAssertEqual(try ws.list().map(\.name), ["neu.txt"])
        XCTAssertEqual(ws.meta?.changed, false)
        XCTAssertEqual(ws.meta?.links, [:])

        // Link-Aenderung: geaenderte PDF loest die Verknuepfung
        try ws.add(Data("%PDF a".utf8), named: "x.pdf")
        try ws.setLink("doc-2", for: "x.pdf")
        try ws.write(Data("%PDF b".utf8), to: "x.pdf")
        XCTAssertNil(ws.link(for: "x.pdf"))
    }

    func testWorkspaceKeepsOldStateWhenNewSourceIsBroken() throws {
        let ws = ZipWorkspace(root: tmp.appendingPathComponent("ws"))
        try ws.prepare(source: try ZipArchive.pack([ZipArchive.Item(path: "a.txt", data: Data("a".utf8))]), name: "a.zip")
        var e = RawEntry("x")
        e.flags = 1
        XCTAssertThrowsError(try ws.prepare(source: rawZip([e]), name: "a.zip", force: true))
        XCTAssertEqual(try ws.list().map(\.name), ["a.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ws.root.path).sorted(), ["inhalt", "zip.json"])
    }

    func testUniqueNames() {
        XCTAssertEqual(ZipWorkspace.uniqueName("a.pdf") { _ in false }, "a.pdf")
        XCTAssertEqual(ZipWorkspace.uniqueName("a.pdf") { ["a.pdf", "a 2.pdf"].contains($0) }, "a 3.pdf")
        XCTAssertEqual(ZipWorkspace.uniqueName("Ordner") { $0 == "Ordner" }, "Ordner 2")
    }
}
