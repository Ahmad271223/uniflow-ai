import Foundation

/// Raumplan des LSF Hildesheim ohne Netz (Kern- und App-Tests, Bildvergleiche): nachgebaute Seiten mit erfundenen
/// Daten im Aufbau der echten Seiten vom 07.11.2026 (~/Studora-Builds/hildesheim/RAUMPLAN-STRUKTUR-2026-11-07.md).
/// Erfunden: Campus "Testcampus" (Kuerzel TC), "Gebäude T (Testcampus)" (gebid 9100, Teststraße 1), Raeume
/// "TC.T.1.01 (Kleiner Testraum)" (rgid 9001) und "TC.T.0.02 (Großer Testsaal)" (rgid 9002), Lehrperson "Muster, Erika".
/// Suche: Begriff in einem der beiden Raumnamen -> beide = Auswahlseite, genau einer = Belegungsplan, keiner = leerer Plan.
public struct HildesheimRoomsDemoHTTP: HildesheimRoomsHTTP {
    public init() {}

    static let rooms: [(rgid: Int, name: String, floor: String, kind: String, short: String)] = [
        (9001, "TC.T.1.01 (Kleiner Testraum)", "Ebene 1", "Seminarraum", "T 101"),
        (9002, "TC.T.0.02 (Großer Testsaal)", "Ebene 0", "Hörsaal", "T 002"),
    ]

    static func head(_ title: String) -> String {
        """
        <!DOCTYPE html><html lang="de"><head><meta charset="UTF-8"><title>\(title) - Universität Hildesheim</title></head>
        <body><div class="divcontent"><div id="hidden">Wenn Sie diesen Text sehen, ist auf ihrem Gerät noch nicht das neue Layout geladen worden.</div>
        <a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=wlogin&amp;login=in">Anmelden</a>
        <div class="breadcrumb">Sie sind hier: <a class='regular' href="https://lsf.uni-hildesheim.de/qisserver/rds?state=user&amp;type=0">Startseite</a></div>
        <div class="content_max"><a name="lese"></a>
        """
    }

    static let foot = """
        </div></div><div class="divfoot"><a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=template&amp;template=about" class="links3">Impressum</a></div></body></html>
        """

    /// "Ihre Auswahl war nicht eindeutig" mit einem Link je Raum
    public static func choicePage(_ hits: [(rgid: Int, name: String)], term: String) -> String {
        var s = head("Raumplan") + "<h1>Ihre Auswahl war nicht eindeutig.<br>Bitte wählen Sie ...</h1>\n<fieldset><br /><a class=\"regular qisback\" href=\"https://lsf.uni-hildesheim.de/qisserver/rds?state=user&amp;type=0\">Zur&uuml;ck</a>&nbsp;(ohne Auswahl)</fieldset>\n<fieldset><legend>Auswahl</legend>\n"
        for (i, h) in hits.enumerated() {
            let name = h.name.replacingOccurrences(of: "&", with: "&amp;")
            s += "<div style=\"text-align: right; width: 5%; margin-right: 10px; float: left\">\(i + 1):</div>\n<div>\n"
            s += "<a class=\"regular\" name=\"\(name.prefix(1))\" href=\"https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&amp;act=Raum&amp;pool=Raum&amp;P.subc=plan&amp;raum.rgid=\(h.rgid)&amp;idcol=raum.rgid&amp;idval=\(h.rgid)&amp;raum.stxt=\(PyText.quote(term, safe: "", plus: true))&amp;purge=n&amp;getglobal=n&amp;text=\(PyText.quote(h.name, safe: "", plus: true))\" >\n\t\t\t\t\t\(name)\n\t\t\t\t</a>\n</div>\n"
        }
        return s + "</fieldset>\n" + foot
    }

    /// Belegungsplan (lange Ansicht) eines Raums; ohne Raum (`nil`): die Seite nach einer Suche ohne Treffer
    public static func planPage(room: (rgid: Int, name: String)?, week: String) -> String {
        var s = head("Raumplan")
        s += """
        <table class="normal" width="100%"><tr><td class="menu1_on"><fieldset><legend>Anzeigeoptionen</legend>
        <form class="form" action="https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&amp;act=Raum&amp;pool=Raum&amp;show=plan&amp;P.vx=lang" method="post">
        <select name="week" class="kleinerButton"><optgroup label="globale Ansichten"><option value="-2">Semesteransicht </option>
        <option value="-1" selected>Vorlesungszeitansicht</option></optgroup><optgroup label="einzelne Wochen">
        <option value="45_2026">Woche: 45 &nbsp;&nbsp;&nbsp;  2.11.2026 ---- 8.11.2026</option>
        <option value="46_2026">Woche: 46 &nbsp;&nbsp;&nbsp;  9.11.2026 ---- 15.11.2026</option></optgroup></select>
        <input type="submit" class="kleinerButton" name="work" value="anzeigen"></form></fieldset></td>
        <td class="menu2_off"><h1>\n &nbsp;Raum - Belegungsplan&nbsp;\n       (WiSe 2026/27)\n</h1></td></tr></table>

        """
        guard let room else { return s + foot }
        let name = room.name.replacingOccurrences(of: "&", with: "&amp;")
        s += """
        <table width="100%"><tr><td><h4>
        \t\t\t<a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;status=init&amp;vmfile=no&amp;moduleCall=webInfo&amp;publishConfFile=webInfoRaum&amp;publishSubDir=raum&amp;keep=y&amp;raum.rgid=\(room.rgid)" class="nav" target="_blank" title="Details ansehen [Neues Fenster]">
        \t                                               &nbsp;\(name)\n\t\t\t\t&nbsp;\n\t\t\t\t</a>
        \t        </h4></td><td class="plan_gremien" align="center"><a href="https://www.uni-hildesheim.de/wiki/lsf/faq/gremienzeiten">Gremienzeiten</a></td>
         <td class="plan5" align="center">Einzeltermin</td>
         <td class="plan7" align="center">Blockveranstaltung</td>
         <td class="plan6" align="center">14-tägl. Veranstaltung</td></tr></table>
        <table width="100%" border="1" cellpadding="2" cellspacing="0">
          <tr><td class="plan_rahmen" colspan="2">&nbsp;Zeit</td><th class="plan_rahmen" scope="col" nowrap>Montag</th><th class="plan_rahmen" scope="col" nowrap>Dienstag</th>
          <th class="plan_rahmen" scope="col" nowrap>Mittwoch</th><th class="plan_rahmen" scope="col" nowrap>Donnerstag</th><th class="plan_rahmen" scope="col" nowrap>Freitag</th></tr>
          <tr style="background-color:#FFFFFF"><td valign="top" scope="row" class="plan_rahmen" nowrap>&nbsp;<span class="normal">vor 8</span></td><td width="0"></td>
          <td valign="top" class="plan1" nowrap align="right">&nbsp;</td><td valign="top" class="plan1" nowrap align="right">&nbsp;</td><td valign="top" class="plan1" nowrap align="right">&nbsp;</td><td valign="top" class="plan1" nowrap align="right">&nbsp;</td><td valign="top" class="plan1" nowrap align="right">&nbsp;</td></tr>
          <tr style="background-color:#f4f6f7"><td valign="top" scope="row" class="plan_rahmen" nowrap rowspan="4">&nbsp;<span class="normal">10</span></td><td width="0"></td>
          <td valign="top" class="plan2" rowspan="8"><table width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td class="plan5">
        \t\t<a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;status=init&amp;vmfile=no&amp;publishid=990001&amp;moduleCall=webInfo&amp;publishConfFile=webInfo&amp;publishSubDir=veranstaltung" hreflang="de" charset="ISO-8859-1" title="1234 Testvorlesung Algorithmen" class="ver">
                               <span title="1234 Testvorlesung Algorithmen">1234 Testvorlesung Algorithmen</span><div class="grueneWarnung"></div></a><b class="inputerror">&nbsp;</b></td></tr>
        \t\t<tr><td class="notiz">\n\t\t\t\t\t\t\t\t\tMontag,&nbsp;\n\t\t\t\t\t\t\t\t10:00 - 12:00 c.t., wöchentlich\n\t\t\t\t\t\t\t</td></tr>
        \t\t<tr><td class="notiz">Start :&nbsp;&nbsp;19.10.2026</td></tr><tr><td class="notiz">Ende :&nbsp;&nbsp;01.02.2027</td></tr>
        \t\t<tr><td class="notiz">Vorlesung</td></tr><tr><td class="notiz">2&nbsp;SWS</td></tr>
        \t\t<tr><td class="notiz">Zugeordnete Lehrpersonen: <a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;publishConfFile=webInfoPerson&amp;personal.pid=990" class="ver"> Muster,&nbsp;Erika</a></td></tr>
        \t\t<tr><td class="notiz">Einrichtung: <a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;publishConfFile=webInfoEinrichtung&amp;einrichtung.eid=990" class="ver">Institut für Testwesen - Institut</a></td></tr>
        \t\t</table></td>
          <td valign="top" class="plan1" nowrap align="right">&nbsp;</td>
          <td valign="top" class="plan2" rowspan="8"><table width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td class="plan5">
        \t\t<a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;status=init&amp;vmfile=no&amp;publishid=990002&amp;moduleCall=webInfo&amp;publishConfFile=webInfo&amp;publishSubDir=veranstaltung" hreflang="de" charset="ISO-8859-1" title="Klausur Testmodul &amp; Übung" class="ver">
                               <span title="Klausur Testmodul &amp; Übung">Klausur Testmodul &amp; Übung</span><div class="grueneWarnung"></div></a><b class="inputerror">&nbsp;</b></td></tr>
        \t\t<tr><td class="notiz">\n\t\t\t\t\t\t\t\t\tMittwoch,&nbsp;\n\t\t\t\t\t\t\t\t14:00 - 16:00 s.t., Einzeltermin\n\t\t\t\t\t\t\t</td></tr>
        \t\t<tr><td class="notiz">Start :&nbsp;&nbsp;04.11.2026</td></tr><tr><td class="notiz">Ende :&nbsp;&nbsp;04.11.2026</td></tr>
        \t\t<tr><td class="notiz">Klausur</td></tr>
        \t\t</table></td>
          <td valign="top" class="plan1" nowrap align="right">&nbsp;</td><td valign="top" class="plan1" nowrap align="right">&nbsp;</td></tr>
        </table>

        """
        return s + foot
    }

    /// Raum-Einzelansicht mit Grunddaten, Raumadmin (erfunden) und Verweisen
    public static func roomPage(rgid: Int, name: String, floor: String, kind: String, short: String) -> String {
        let n = name.replacingOccurrences(of: "&", with: "&amp;")
        return head("Raum") + """
        <form class="form" action="https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&amp;search=ver&amp;act=add" method="post">
        <h1>Raum: \(n)&nbsp;- Einzelansicht</h1>
        <div class="functionnavi"><ul><li class="randlos">Funktionen:</li><li><a class="regular" title="Raumplan" href="https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&amp;act=Raum&amp;pool=Raum&amp;raum.rgid=\(rgid)"><img src="/QIS/images//view_tile.svg" alt="" title="Raumplan"></a></li></ul></div>
        <a name="basicdata"></a>
        <table summary="Grunddaten zum Raum"><caption class="t_capt">Grunddaten</caption>
        <tr><th class="mod" id="basic_1">Raum</th><td class="mod_n_basic" headers="basic_1">\(n)</td>
        <th class="mod" id="basic_2">Gebäude</th><td class="mod_n_basic" headers="basic_2">
        <a class="regular" title="Details ansehen zu Gebäude T (Testcampus)" href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;publishContainer=buildingContainer&amp;k_gebaeude.gebid=9100">Gebäude T (Testcampus)</a></td></tr>
        <tr><th class="mod" id="basic_3">Kurzbezeichnung</th><td class="mod_n_basic" headers="basic_3">\(short)</td>
        <th class="mod" id="basic_4">Stockwerk</th><td class="mod_n_basic" headers="basic_4">\(floor)</td></tr>
        <tr><th class="mod" id="basic_5">Zusatzbezeichnung</th><td class="mod_n_basic" headers="basic_5">\(n)</td>
        <th class="mod" id="basic_6">Kostenstelle</th><td class="mod_n_basic" headers="basic_6"> </td></tr>
        <tr><th class="mod" id="basic_7">Raumart</th><td class="mod_n_basic" headers="basic_7">\(kind)</td>
        <th class="mod" id="basic_8">Zentral verwaltet</th><td class="mod_n_basic" headers="basic_8"> Ja </td></tr></table>
        <br /><br /><a name="raumverwalter"></a><h2>Raumadmin</h2>
        <table border=0 summary="Raumverwalter"><tr><th scope="col" id="basic_1" class="mod">Raumadmin</th><td class="mod_n_odd" headers="basic_1">
        <a class="regular" href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;publishConfFile=webInfoPerson&amp;personal.pid=991">Muster, Erika</a></td></tr></table>
        <a name="lecture"></a><table summary="Übersicht über die Zugehörigkeit zu Veranstaltungen"><caption class="t_capt">Veranstaltungen</caption></table>
        </form>
        """ + foot
    }

    /// Gebaeude-Einzelansicht mit Grunddaten, Adresse, Raumliste, Raumadmin (erfunden) und Karte
    public static func buildingPage(gebid: Int, name: String, short: String, campus: String, street: String?, zip: String, city: String,
                                    lat: Double?, lon: Double?, rooms: [(rgid: Int, name: String)]) -> String {
        var s = head("Gebäude") + """
        <form class="form" action="https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&amp;search=ver&amp;act=add" method="post">
        <h1>Gebäude: \(name)&nbsp;- Einzelansicht</h1>
        <a name="basicdata"></a>
        <table summary="Grunddaten zum Gebäude"><caption class="t_capt">Grunddaten</caption>
        <tr><th class="mod" id="basic_1">Kurzbezeichnung</th><td class="mod_n_basic" headers="basic_1">\(short)</td>
        <th class="mod" id="basic_2">Campus</th><td class="mod_n_basic" headers="basic_2">\(campus)</td></tr>
        <tr><th class="mod" id="basic_3">Gebäude</th><td class="mod_n_basic" headers="basic_3">\(name)</td>
        <th class="mod" id="basic_4">Hochschulgebäude</th><td class="mod_n_basic" headers="basic_4">J</td></tr>
        <tr><th class="mod" id="basic_5">Zusatzbezeichnung</th><td class="mod_n_basic" headers="basic_5">\(name)</td>
        <th class="mod" id="basic_6">&nbsp;</th><td class="mod_n_basic" headers="basic_6">&nbsp;</td></tr></table>
        <br><a name="adresse"></a><h2>Adresse</h2>
        <table border="0" summary="Adresse">
        <tr><th scope="col" class="mod" id="basic_1"><acronym title="Postleitzahl">PLZ</acronym></th><td class="mod_n_basic" headers="basic_1">\(zip)</td>
        <th scope="col" class="mod" id="basic_2">Fax</th><td class="mod_n_basic" headers="basic_2"> </td></tr>
        <tr><th scope="col" class="mod" id="basic_3">Ort</th><td class="mod_n_basic" headers="basic_3">\(city)</td>
        <th scope="col" class="mod" id="basic_4">E-Mail-Adresse</th><td class="mod_n_basic" headers="basic_4"><a href="mailto: "> </a></td></tr>
        <tr><th scope="col" class="mod" id="basic_5">Straße</th><td class="mod_n_basic" headers="basic_5">\(street ?? " ")</td>
        <th scope="col" class="mod" id="basic_6">Hyperlink </th><td class="mod_n_basic" headers="basic_6"><a class="external" title="Externer Link:  " href="https://lsf.uni-hildesheim.de/qisserver/rds?state=redirect&amp;destination=+"> </a></td></tr>
        <tr><th scope="col" class="mod" id="basic_7">Telefon</th><td class="mod_n_basic" headers="basic_7"> </td><th scope="col" class="mod" id="basic_8"></th><td class="mod_n_basic" headers="basic_8"></td></tr></table>
        <a name="raum"></a><table summary="Übersicht über alle Veranstaltungstermine"><caption class="t_capt">Räume</caption>
        <tr><th scope="col" class="mod">Kurzbezeichnung</th><th scope="col" class="mod">Beschreibung</th><th scope="col" class="mod">Zusatzbezeichnung</th></tr>

        """
        for r in rooms {
            let n = r.name.replacingOccurrences(of: "&", with: "&amp;")
            s += "<tr><td class=\"mod_n_odd\"><a class=\"regular\" title=\"Details ansehen zu \(n)\" href=\"https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;status=init&amp;vmfile=no&amp;moduleCall=webInfo&amp;publishConfFile=webInfoRaum&amp;publishSubDir=raum&amp;keep=y&amp;purge=y&amp;raum.rgid=\(r.rgid)\">\(n.prefix(5))</a></td>"
            s += "<td class=\"mod_n_odd\"><a class=\"regular\" title=\"Details ansehen zu Raum \(n)\" href=\"https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;status=init&amp;vmfile=no&amp;moduleCall=webInfo&amp;publishConfFile=webInfoRaum&amp;publishSubDir=raum&amp;keep=y&amp;purge=y&amp;raum.rgid=\(r.rgid)\">\(n)</a></td><td class=\"mod_n_odd\">\(n)</td></tr>\n"
        }
        s += """
        </table>
        <a name="raumverwalter"></a><h2>Raumadmin</h2>
        <table border=0 summary="Raumverwalter"><tr><th scope="col" id="basic_1" class="mod">Raumadmin</th><td class="mod_n_odd" headers="basic_1">
        <a class="regular" href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;publishConfFile=webInfoPerson&amp;personal.pid=991">Muster, Erika</a></td></tr></table>

        """
        if let lat, let lon {
            s += "<a name=\"karte\"></a><h2>Karte</h2>\n<object data=\"https://www.openstreetmap.org/export/embed.html?bbox=\(lon - 0.004),\(lat - 0.003),\(lon + 0.004),\(lat + 0.003)&layer=mapnik&marker=\(lat),\(lon)\" type=\"application/xhtml+xml\" width=\"425\" height=\"350\">Ihr Browser kann die Karte leider nicht anzeigen!</object>\n<BR />&Ouml;ffnen mit <A target=\"_blank\" href=\"http://www.openstreetmap.org/?mlat=\(lat)&mlon=\(lon)&zoom=17\">OpenStreetMap</A>\n"
        }
        return s + "</form>" + foot
    }

    public func get(_ url: URL) async throws -> String {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        if v("moduleParameter") == "raumPlanSearch", let term = v("raum.stxt") {
            let low = PyText.lower(Rooms.words(term)).replacingOccurrences(of: "*", with: "")
            let hits = Self.rooms.filter { !low.isEmpty && PyText.contains(PyText.lower($0.name), low) }.map { (rgid: $0.rgid, name: $0.name) }
            if hits.count > 1 { return Self.choicePage(hits, term: term) }
            return Self.planPage(room: hits.first, week: "-1")
        }
        if v("publishConfFile") == "webInfoRaum", let id = Int(v("raum.rgid") ?? "") {
            // unbekannter Raum: das LSF zeigt eine Einzelansicht ohne Grunddaten
            guard let r = Self.rooms.first(where: { $0.rgid == id }) else { return Self.head("Raum") + "<h1>Raum: &nbsp;- Einzelansicht</h1>" + Self.foot }
            return Self.roomPage(rgid: r.rgid, name: r.name, floor: r.floor, kind: r.kind, short: r.short)
        }
        if v("publishContainer") == "buildingContainer", let id = Int(v("k_gebaeude.gebid") ?? "") {
            guard id == 9100 else { throw RoomFinderHTTPError(status: 404) }
            return Self.buildingPage(gebid: 9100, name: "Gebäude T (Testcampus)", short: "T___", campus: "Testcampus", street: "Teststraße 1",
                                     zip: "31141", city: "Hildesheim", lat: 52.1345, lon: 9.9762,
                                     rooms: Self.rooms.map { (rgid: $0.rgid, name: $0.name) })
        }
        if v("state") == "wplan", let id = Int(v("raum.rgid") ?? "") {
            guard let r = Self.rooms.first(where: { $0.rgid == id }) else { return Self.planPage(room: nil, week: v("week") ?? "-1") }
            return Self.planPage(room: (rgid: r.rgid, name: r.name), week: v("week") ?? "-1")
        }
        throw RoomFinderHTTPError(status: 404)
    }
}
