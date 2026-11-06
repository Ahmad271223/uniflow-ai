import Foundation
import XCTest
@testable import UniFlowCore

// Termin-Detail (06.11.2026) gegen die gemeinsamen Faelle packages/shared-contracts/fixtures/termin-detail/cases.json
// (gleich in tests/js/termin-detail.test.mjs): Raeume eines Termins, Route zu Fuss oder Raumfinder-Suche, Lehrende und
// Tutor/innen, "Allen Lehrenden schreiben", Betreff, mailto:, Wahl zwischen Uni-Mail, "Uni-Mail verbinden" und mailto:.

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/termin-detail/cases.json")))
}

final class TerminDetailTests: XCTestCase {

    func testRoomsOfAnAppointment() throws {
        for c in try fixture()["rooms"]?.array ?? [] {
            let got = TerminDetail.rooms(c["text"]?.string)
            let want = (c["want"]?.array ?? []).map { TerminDetail.Room(text: $0["text"]?.string ?? "", link: $0["link"]?.bool ?? false) }
            XCTAssertEqual(got, want, "\(c)")
        }
    }

    func testRouteOrSearch() throws {
        for c in try fixture()["route"]?.array ?? [] {
            let part = try XCTUnwrap(c["part"])
            let got = TerminDetail.route(part, appInstalled: c["app"]?.bool ?? false)
            let w = try XCTUnwrap(c["want"])
            switch w["kind"]?.string {
            case "route": XCTAssertEqual(got, .route(w["url"]?.string ?? ""), "\(c)")
            case "search": XCTAssertEqual(got, .search(w["query"]?.string ?? ""), "\(c)")
            default: XCTAssertEqual(got, .none, "\(c)")
            }
        }
    }

    func testLecturersTutorsAndRecipients() throws {
        let fx = try fixture()
        let people = fx["people"]?.array ?? []
        let g = TerminDetail.groups(people)
        XCTAssertEqual(g.lecturers.compactMap { $0["id"]?.string }, fx["groups"]?["lecturers"]?.array?.compactMap(\.string))
        XCTAssertEqual(g.tutors.compactMap { $0["id"]?.string }, fx["groups"]?["tutors"]?.array?.compactMap(\.string))
        XCTAssertEqual(TerminDetail.recipients(people), fx["recipients"]?.array?.compactMap(\.string))
    }

    func testSubjectMailtoAndChoice() throws {
        let fx = try fixture()
        for c in fx["subject"]?.array ?? [] {
            XCTAssertEqual(TerminDetail.subject(c["title"]?.string), c["want"]?.string, "\(c)")
        }
        for c in fx["mailto"]?.array ?? [] {
            let to = (c["to"]?.array ?? []).compactMap(\.string)
            XCTAssertEqual(TerminDetail.mailto(to, subject: c["subject"]?.string ?? ""), c["want"]?.string, "\(c)")
        }
        for c in fx["mail_choice"]?.array ?? [] {
            let to = (c["to"]?.array ?? []).compactMap(\.string)
            let state = try XCTUnwrap(TerminDetail.UniMailState(rawValue: c["unimail"]?.string ?? ""))
            XCTAssertEqual(TerminDetail.mailChoice(to, uniMail: state).rawValue, c["want"]?.string, "\(c)")
        }
    }

    func testLecturersQueryAndUniversity() throws {
        let fx = try fixture()
        for c in fx["lecturers_query"]?.array ?? [] {
            XCTAssertEqual(TerminDetail.lecturersQuery(c["event"] ?? .null), c["want"]?.string, "\(c)")
        }
        for c in fx["shows_lecturers"]?.array ?? [] {
            XCTAssertEqual(TerminDetail.showsLecturers(university: c["university"]?.string), c["want"]?.bool, "\(c)")
        }
    }

    /// Die Route zu einem gefundenen Raum des Raumfinders laeuft zu Fuss (Koordinaten, `Rooms.maps`)
    func testRouteFromRoomsMapsIsWalking() {
        let maps = Rooms.maps("x", label: "Raum F102", lat: 52.38255, lon: 9.71785)
        let part: JSONValue = ["text": "1101 - F102", "status": "found", "maps": maps]
        XCTAssertEqual(TerminDetail.route(part, appInstalled: false),
                       .route("https://www.google.com/maps/dir/?api=1&destination=52.38255%2C9.71785&travelmode=walking"))
        XCTAssertEqual(TerminDetail.route(part, appInstalled: true), .route("comgooglemaps://?daddr=52.38255%2C9.71785&directionsmode=walking"))
    }
}
