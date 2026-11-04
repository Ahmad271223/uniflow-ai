import Foundation

/// Nachrichten aus Stud.IP (`StudIPExtras.messageList`, nur Geraet, keine Python-Entsprechung): `GET /api/studip/messages?q=`
/// mit allen gespeicherten Nachrichten des Posteingangs, neueste zuerst, gefiltert nach `q`. Nur lesend; ohne Tabelle
/// (noch kein Abgleich) leer. Eine Einzelansicht gibt es bewusst nicht (der Abgleich liest nur die Liste).
enum StudIPMessagesEndpoints: LocalEndpointModule {
    static let name = "Nachrichten aus Stud.IP"

    static func register(on router: LocalRouter) {
        router.get("/api/studip/messages") { req, ctx in
            let q = req.query("q")
            return .json(try await ctx.database.withConnection { try StudIPExtras.messageList($0, query: q) })
        }
    }
}
