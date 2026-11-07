import Foundation

// Gebaeude der Universitaet Hildesheim (Raumfinder, 07.11.2026). Quelle: Gebaeude-Einzelansichten im oeffentlichen LSF
// (https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&publishContainer=buildingContainer&k_gebaeude.gebid=<id>),
// gelesen am 07.11.2026 ohne Anmeldung (Aufbau: ~/Studora-Builds/hildesheim/RAUMPLAN-STRUKTUR-2026-11-07.md). Je Gebaeude:
// Kennung im LSF, Name, Kurzbezeichnung, Campus, Strasse/PLZ/Ort aus dem Abschnitt "Adresse" (fehlt die Strasse im LSF,
// gilt die Adresse des Campus von der Anfahrtsseite https://www.uni-hildesheim.de/en/ueber-uns/anfahrt/, `addressFromCampus`),
// Koordinaten aus dem OpenStreetMap-Marker des Abschnitts "Karte", Praefixe der Raumcodes aus der Raumliste des Gebaeudes
// (z. B. "HC.I" fuer "HC.I.1.Hörsaal 1"; Schützenallee "SH" fuer "SH.0.23", Leesterhaus "WL" fuer "WL.2.01"; das Bistro
// "BC.L.0.62" steht im LSF beim Neubau, der Code gehoert zum Altbau "BC.L"). Keine Personen (die Raumadmin-Namen der Seiten werden nicht uebernommen).
// Neu lesen: tools gibt es nicht; die Seiten von Hand pruefen und diese Datei anpassen.

public struct HildesheimBuilding: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let short: String
    public let campus: String
    /// Kennung des Standorts wie in rooms.json (`universities.hildesheim.campuses`): hauptcampus, buehler, samelsonplatz,
    /// domaene, schuetzenallee, aussenstelle, extern
    public let campusID: String
    /// Strasse laut LSF, bei `addressFromCampus` die des Campus
    public let street: String?
    public let zip: String
    public let city: String
    public let lat: Double?
    public let lon: Double?
    /// Anfang der Raumcodes dieses Gebaeudes ("HC.I" -> "HC.I.1.Hörsaal 1")
    public let codes: [String]
    /// Strasse nicht im LSF: Adresse des Campus (Anfahrtsseite der Uni)
    public let addressFromCampus: Bool

    public var addressLine: String {
        let first = street ?? ""
        let second = [zip, city].filter { !$0.isEmpty }.joined(separator: " ")
        return [first, second].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

public enum HildesheimRoomsData {
    public static let checkedAt = "2026-11-07"

    /// Standorte laut Anfahrtsseite der Uni (https://www.uni-hildesheim.de/en/ueber-uns/anfahrt/) und LSF-Gebaeudeseiten;
    /// Adresse des Campus fuer Gebaeude ohne Strasse im LSF
    public static let campusAddress: [String: (street: String, zip: String, city: String)] = [
        "hauptcampus": ("Universitätsplatz 1", "31141", "Hildesheim"),          // Hauptcampus Marienburger Höhe
        "buehler": ("Lübecker Straße 3", "31141", "Hildesheim"),                // Bühler-Campus (LSF: Altbau, Lübecker Straße 3)
        "samelsonplatz": ("Samelsonplatz 1", "31141", "Hildesheim"),            // Samelson-Campus
        "domaene": ("Domänenstraße 1", "31141", "Hildesheim"),                  // Kulturcampus Domäne Marienburg
        "schuetzenallee": ("Schützenallee 41b", "31134", "Hildesheim"),         // Schützenallee-Campus
    ]

    public static let buildings: [HildesheimBuilding] = [
        HildesheimBuilding(id: 1, name: "Gebäude V (Verwaltung)", short: "V___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13425, lon: 9.97531,
                           codes: ["HC.V"], addressFromCampus: false),
        HildesheimBuilding(id: 2, name: "Gebäude SP (Sport)", short: "SP__", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13353, lon: 9.97675,
                           codes: ["HC.Sp"], addressFromCampus: false),
        HildesheimBuilding(id: 3, name: "Gebäude K (Hauptcampus)", short: "K___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13484, lon: 9.9759,
                           codes: ["HC.K"], addressFromCampus: false),
        HildesheimBuilding(id: 4, name: "Gebäude J (Hauptcampus)", short: "J___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13473, lon: 9.97624,
                           codes: ["HC.J"], addressFromCampus: false),
        HildesheimBuilding(id: 5, name: "Gebäude I (Hauptcampus)", short: "I___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13452, lon: 9.97618,
                           codes: ["HC.I"], addressFromCampus: false),
        HildesheimBuilding(id: 6, name: "Gebäude H (Hauptcampus)", short: "H___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13428, lon: 9.97639,
                           codes: ["HC.H"], addressFromCampus: false),
        HildesheimBuilding(id: 7, name: "Gebäude G (Hauptcampus)", short: "G___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13403, lon: 9.97633,
                           codes: ["HC.G"], addressFromCampus: true),
        HildesheimBuilding(id: 8, name: "Gebäude F (Hauptcampus)", short: "F___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13384, lon: 9.97471,
                           codes: ["HC.F"], addressFromCampus: false),
        HildesheimBuilding(id: 9, name: "Gebäude E (Hauptcampus)", short: "E___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13396, lon: 9.97583,
                           codes: ["HC.E"], addressFromCampus: false),
        HildesheimBuilding(id: 10, name: "Gebäude D (Hauptcampus)", short: "D___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13394, lon: 9.97553,
                           codes: ["HC.D"], addressFromCampus: false),
        HildesheimBuilding(id: 13, name: "Audimax/alte Mensa", short: "A___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13485, lon: 9.97544,
                           codes: ["HC.A"], addressFromCampus: false),
        HildesheimBuilding(id: 14, name: "Gebäude W (Tilsiter Straße)", short: "W___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Tilsiterstraße 1", zip: "31141", city: "Hildesheim", lat: 52.13291, lon: 9.97716,
                           codes: ["HC.W2", "HC.W3"], addressFromCampus: false),
        HildesheimBuilding(id: 17, name: "Gebäude D (Samelson-Campus)", short: "DSPL", campus: "Samelson-Campus", campusID: "samelsonplatz",
                           street: "Samelsonplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13351, lon: 9.96739,
                           codes: ["SC.D"], addressFromCampus: false),
        HildesheimBuilding(id: 18, name: "Gebäude C (Samelson-Campus)", short: "CSPL", campus: "Samelson-Campus", campusID: "samelsonplatz",
                           street: "Samelsonplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13401, lon: 9.9686,
                           codes: ["SC.C"], addressFromCampus: false),
        HildesheimBuilding(id: 19, name: "Gebäude B (Samelson-Campus)", short: "BSPL", campus: "Samelson-Campus", campusID: "samelsonplatz",
                           street: "Samelsonplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13389, lon: 9.96761,
                           codes: ["SC.B"], addressFromCampus: false),
        HildesheimBuilding(id: 20, name: "Gebäude A (Samelson-Campus)", short: "ASPL", campus: "Samelson-Campus", campusID: "samelsonplatz",
                           street: "Samelsonplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13405, lon: 9.96797,
                           codes: ["SC.A"], addressFromCampus: false),
        HildesheimBuilding(id: 22, name: "Hs 51 / Kartoffelwaschhaus", short: "51_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 51", zip: "31141", city: "Hildesheim", lat: 52.11459, lon: 9.98226,
                           codes: ["KC.51"], addressFromCampus: false),
        HildesheimBuilding(id: 25, name: "Hs 48 / Brauhaus", short: "48_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 48", zip: "31141", city: "Hildesheim", lat: 52.11432, lon: 9.98221,
                           codes: ["KC.48"], addressFromCampus: false),
        HildesheimBuilding(id: 29, name: "Hs 31 / Steinscheune", short: "31_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 31", zip: "31141", city: "Hildesheim", lat: 52.11481, lon: 9.98178,
                           codes: ["KC.31"], addressFromCampus: false),
        HildesheimBuilding(id: 30, name: "Hs 30 / Eishalle", short: "30_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 1", zip: "31141", city: "Hildesheim", lat: nil, lon: nil,
                           codes: [], addressFromCampus: true),
        HildesheimBuilding(id: 34, name: "Hs 2A / Altes Pächterhaus", short: "2a_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 1", zip: "31141", city: "Hildesheim", lat: 52.11446, lon: 9.98194,
                           codes: ["KC.2A"], addressFromCampus: true),
        HildesheimBuilding(id: 40, name: "Hs 2 / Altes Pächterhaus", short: "2__D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 2", zip: "31141", city: "Hildesheim", lat: 52.11455, lon: 9.98171,
                           codes: ["KC.2"], addressFromCampus: false),
        HildesheimBuilding(id: 41, name: "Hs 1 / Neues Pächterhaus", short: "1__D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 1", zip: "31141", city: "Hildesheim", lat: 52.11463, lon: 9.98148,
                           codes: ["KC.1"], addressFromCampus: false),
        HildesheimBuilding(id: 42, name: "Moltkestraße", short: "MO__", campus: "Außenstelle", campusID: "aussenstelle",
                           street: "Moltkestr. 86", zip: "31135", city: "Hildesheim", lat: 52.15329, lon: 9.96388,
                           codes: [], addressFromCampus: false),
        HildesheimBuilding(id: 43, name: "Bezirkssportanlage (bis SS09)", short: "BezS", campus: "Außenstelle", campusID: "aussenstelle",
                           street: "Marienburger Platz 90a", zip: "31141", city: "Hildesheim", lat: nil, lon: nil,
                           codes: [], addressFromCampus: false),
        HildesheimBuilding(id: 44, name: "Keßlerstraße", short: "Ke", campus: "Außenstelle", campusID: "aussenstelle",
                           street: "Keßlerstraße 57", zip: "31141", city: "Hildesheim", lat: 52.1459, lon: 9.95579,
                           codes: [], addressFromCampus: false),
        HildesheimBuilding(id: 45, name: "Altbau Bühler-Campus", short: "L___", campus: "Bühler-Campus", campusID: "buehler",
                           street: "Lübecker Straße 3", zip: "31141", city: "Hildesheim", lat: 52.13646, lon: 9.96451,
                           codes: ["BC.L"], addressFromCampus: false),
        HildesheimBuilding(id: 46, name: "Externes Gebäude", short: "Ext", campus: "", campusID: "extern",
                           street: nil, zip: "", city: "", lat: nil, lon: nil,
                           codes: [], addressFromCampus: false),
        HildesheimBuilding(id: 47, name: "Timotheuskirche", short: "T___", campus: "Samelson-Campus", campusID: "samelsonplatz",
                           street: "Schillstraße", zip: "31141", city: "Hildesheim", lat: 52.13476, lon: 9.96777,
                           codes: ["SC.TI"], addressFromCampus: false),
        HildesheimBuilding(id: 48, name: "Pavillon 1 (Samelson-Campus)", short: "Pavi1", campus: "Samelson-Campus", campusID: "samelsonplatz",
                           street: "Samelsonplatz 1", zip: "31141", city: "Hildesheim", lat: nil, lon: nil,
                           codes: [], addressFromCampus: true),
        HildesheimBuilding(id: 49, name: "Leesterhaus (Musikschule Hildesheim) (ehem. Waterloo-Kaserne)", short: "LH", campus: "Außenstelle", campusID: "aussenstelle",
                           street: nil, zip: "", city: "Hildesheim", lat: 52.15583, lon: 9.96842,
                           codes: ["WL"], addressFromCampus: false),
        HildesheimBuilding(id: 51, name: "Pavillon 2 (Samelson-Campus)", short: "Pavi2", campus: "Samelson-Campus", campusID: "samelsonplatz",
                           street: "Samelsonplatz 1", zip: "31141", city: "Hildesheim", lat: nil, lon: nil,
                           codes: [], addressFromCampus: true),
        HildesheimBuilding(id: 52, name: "Hs 27 / Ackerpferdestall", short: "27__D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 27", zip: "31141", city: "Hildesheim", lat: 52.11523, lon: 9.98213,
                           codes: ["KC.27"], addressFromCampus: false),
        HildesheimBuilding(id: 53, name: "Hs 50 / Hohes Haus", short: "50_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 1", zip: "31141", city: "Hildesheim", lat: 52.1145, lon: 9.98247,
                           codes: ["KC.50"], addressFromCampus: true),
        HildesheimBuilding(id: 54, name: "Hs 52 / Burgtheater", short: "52_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 1", zip: "31141", city: "Hildesheim", lat: 52.11475, lon: 9.9827,
                           codes: ["KC.52"], addressFromCampus: true),
        HildesheimBuilding(id: 55, name: "Neubau Bühler-Campus", short: "LN___", campus: "Bühler-Campus", campusID: "buehler",
                           street: "Lübecker Straße 3", zip: "31141", city: "Hildesheim", lat: 52.1367, lon: 9.965,
                           codes: ["BC.LN"], addressFromCampus: true),
        HildesheimBuilding(id: 56, name: "Forum", short: "N___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.1333, lon: 9.9757,
                           codes: ["HC.N"], addressFromCampus: true),
        HildesheimBuilding(id: 57, name: "Hs 46 / Weißes Haus", short: "46_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 1", zip: "31141", city: "Hildesheim", lat: 52.11505, lon: 9.98272,
                           codes: ["KC.46"], addressFromCampus: true),
        HildesheimBuilding(id: 58, name: "Gebäude C (Hauptcampus)", short: "C___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13399, lon: 9.9747,
                           codes: ["HC.C"], addressFromCampus: false),
        HildesheimBuilding(id: 60, name: "Hs Con / Containergebäude Domäne", short: "CO_D", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 1", zip: "31141", city: "Hildesheim", lat: nil, lon: nil,
                           codes: [], addressFromCampus: true),
        HildesheimBuilding(id: 63, name: "Schützenallee", short: "SH___", campus: "Schützenallee-Campus", campusID: "schuetzenallee",
                           street: "Schützenallee 41b", zip: "31134", city: "Hildesheim", lat: 52.1555, lon: 9.94372,
                           codes: ["SH"], addressFromCampus: false),
        HildesheimBuilding(id: 64, name: "Außengelände Domäne", short: "Außen", campus: "Kulturcampus Domäne Marienburg", campusID: "domaene",
                           street: "Domänenstraße 1", zip: "31141", city: "Hildesheim", lat: nil, lon: nil,
                           codes: [], addressFromCampus: true),
        HildesheimBuilding(id: 65, name: "Twetje", short: "TW___", campus: "Schützenallee-Campus", campusID: "schuetzenallee",
                           street: "Twetje 10", zip: "31134", city: "Hildesheim", lat: 52.15574, lon: 9.9443,
                           codes: ["SH.TW"], addressFromCampus: false),
        HildesheimBuilding(id: 66, name: "Neue Mensa", short: "M___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Universitätsplatz 1", zip: "31141", city: "Hildesheim", lat: 52.13488, lon: 9.97407,
                           codes: ["HC.M"], addressFromCampus: true),
        HildesheimBuilding(id: 67, name: "Liebfrauenkirche", short: "LK___", campus: "Hauptcampus", campusID: "hauptcampus",
                           street: "Liebfrauenkirchplatz 3", zip: "31141", city: "Hildesheim", lat: 52.13516, lon: 9.97448,
                           codes: ["HC.LK"], addressFromCampus: false),
    ]
}
