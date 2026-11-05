// Erzeugt von tools/gen-exam-registration-fixture.py aus packages/shared-contracts/exam-registration-luh.json,
// exam-registration-hildesheim.json und exam-registration-hsh.json - nicht von Hand aendern.
enum ExamRegistrationData {
    static let luh = #"""
{
 "v": 1,
 "university": "luh",
 "note": "Meldezeitraeume der LUH aus den oeffentlichen Terminseiten des Pruefungsamts (Quelle je Studiengang in url, gelesen am checked_at). Daten nur fuer gepruefte Studiengaenge (table gesetzt); alle anderen nur mit Link. Neu lesen: tools/gen-exam-registration-fixture.py --from-cache DIR. docs/PRUEFUNGSANMELDUNG-2026-11-05.md",
 "checked_at": "2026-11-05",
 "general": {
  "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/pruefungsanmeldung",
  "title": "Prüfungsanmeldung und Musterprüfungsordnung (Akademisches Prüfungsamt der LUH)"
 },
 "qis_menu": "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=change&type=1&moduleParameter=studyPOSMenu&next=menu.vm",
 "rules": [
  {
   "form": "Klausur",
   "withdraw_days_before": 7,
   "text": "Klausur (auch mit Antwortwahl): Abmeldung bis 7 Tage vor dem Prüfungstermin im QIS."
  },
  {
   "form": "Mündliche Prüfung",
   "withdraw_days_before": 1,
   "text": "Mündliche Prüfung und Sportpraktische Präsentation: Abmeldung bis 1 Tag vorher, schriftlich oder per E-Mail."
  },
  {
   "form": "VbP",
   "withdraw_days_before": null,
   "text": "Veranstaltungsbegleitende Prüfung (VbP) und Leistungen mit Abgabe: Abmeldung bis zum Beginn der Prüfungsleistung."
  },
  {
   "form": "Abschlussarbeit",
   "withdraw_days_before": null,
   "text": "Bachelor-, Master- und Studienarbeiten: kein Meldezeitraum, eigener Antrag; keine Abmeldung."
  }
 ],
 "tables": {
  "luh-v1": {
   "variant": "1",
   "terms": [
    {
     "term": "WiSe 26/27",
     "periods": [
      {
       "kind": "vbp_meldung",
       "n": 1,
       "label": "Meldezeitraum für VbP",
       "start": "2026-10-19",
       "end": "2026-11-01"
      },
      {
       "kind": "vbp_pruefung",
       "n": 1,
       "label": "Prüfungszeitraum für VbP",
       "start": "2026-11-09",
       "end": "2027-03-06"
      },
      {
       "kind": "vbp_bewertung",
       "n": 1,
       "label": "Bewertungsfrist für VbP",
       "start": "2027-03-18",
       "end": "2027-03-18"
      },
      {
       "kind": "meldung",
       "n": 1,
       "label": "Meldezeitraum für alle anderen Prüfungsformen",
       "start": "2026-11-09",
       "end": "2026-11-22"
      },
      {
       "kind": "pruefung",
       "n": 1,
       "label": "Prüfungszeitraum für alle anderen Prüfungsformen",
       "start": "2026-11-30",
       "end": "2027-03-27"
      },
      {
       "kind": "bewertung",
       "n": 1,
       "label": "Bewertungsfrist für alle anderen Prüfungsformen",
       "start": "2027-04-08",
       "end": "2027-04-08"
      }
     ]
    },
    {
     "term": "SoSe 27",
     "periods": [
      {
       "kind": "vbp_meldung",
       "n": 1,
       "label": "Meldezeitraum für VbP",
       "start": "2027-04-12",
       "end": "2027-04-25"
      },
      {
       "kind": "vbp_pruefung",
       "n": 1,
       "label": "Prüfungszeitraum für VbP",
       "start": "2027-05-03",
       "end": "2027-08-28"
      },
      {
       "kind": "vbp_bewertung",
       "n": 1,
       "label": "Bewertungsfrist für VbP",
       "start": "2027-09-09",
       "end": "2027-09-09"
      },
      {
       "kind": "meldung",
       "n": 1,
       "label": "Meldezeitraum für alle anderen Prüfungsformen",
       "start": "2027-05-03",
       "end": "2027-05-16"
      },
      {
       "kind": "pruefung",
       "n": 1,
       "label": "Prüfungszeitraum für alle anderen Prüfungsformen",
       "start": "2027-05-24",
       "end": "2027-09-18"
      },
      {
       "kind": "bewertung",
       "n": 1,
       "label": "Bewertungsfrist für alle anderen Prüfungsformen",
       "start": "2027-09-30",
       "end": "2027-09-30"
      }
     ]
    }
   ]
  },
  "luh-v2": {
   "variant": "2",
   "terms": [
    {
     "term": "WiSe 26/27",
     "periods": [
      {
       "kind": "vbp_meldung",
       "n": 1,
       "label": "Meldezeitraum für VbP",
       "start": "2026-10-19",
       "end": "2026-11-01"
      },
      {
       "kind": "vbp_pruefung",
       "n": 1,
       "label": "Prüfungszeitraum für VbP",
       "start": "2026-11-09",
       "end": "2027-03-06"
      },
      {
       "kind": "vbp_bewertung",
       "n": 1,
       "label": "Bewertungsfrist für VbP",
       "start": "2027-03-18",
       "end": "2027-03-18"
      },
      {
       "kind": "meldung",
       "n": 1,
       "label": "Meldezeitraum für alle anderen Prüfungsformen",
       "start": "2026-11-09",
       "end": "2026-11-22"
      },
      {
       "kind": "pruefung",
       "n": 1,
       "label": "Prüfungszeitraum für alle anderen Prüfungsformen",
       "start": "2026-11-30",
       "end": "2027-02-13"
      },
      {
       "kind": "bewertung",
       "n": 1,
       "label": "Bewertungsfrist für alle anderen Prüfungsformen",
       "start": "2027-02-25",
       "end": "2027-02-25"
      },
      {
       "kind": "meldung",
       "n": 2,
       "label": "Meldezeitraum für alle anderen Prüfungsformen",
       "start": "2027-03-01",
       "end": "2027-03-07"
      },
      {
       "kind": "pruefung",
       "n": 2,
       "label": "Prüfungszeitraum für alle anderen Prüfungsformen",
       "start": "2027-03-08",
       "end": "2027-03-27"
      },
      {
       "kind": "bewertung",
       "n": 2,
       "label": "Bewertungsfrist für alle anderen Prüfungsformen",
       "start": "2027-04-08",
       "end": "2027-04-08"
      }
     ]
    },
    {
     "term": "SoSe 27",
     "periods": [
      {
       "kind": "vbp_meldung",
       "n": 1,
       "label": "Meldezeitraum für VbP",
       "start": "2027-04-12",
       "end": "2027-04-25"
      },
      {
       "kind": "vbp_pruefung",
       "n": 1,
       "label": "Prüfungszeitraum für VbP",
       "start": "2027-05-03",
       "end": "2027-08-28"
      },
      {
       "kind": "vbp_bewertung",
       "n": 1,
       "label": "Bewertungsfrist für VbP",
       "start": "2027-09-09",
       "end": "2027-09-09"
      },
      {
       "kind": "meldung",
       "n": 1,
       "label": "Meldezeitraum für alle anderen Prüfungsformen",
       "start": "2027-05-03",
       "end": "2027-05-16"
      },
      {
       "kind": "pruefung",
       "n": 1,
       "label": "Prüfungszeitraum für alle anderen Prüfungsformen",
       "start": "2027-05-24",
       "end": "2027-08-07"
      },
      {
       "kind": "bewertung",
       "n": 1,
       "label": "Bewertungsfrist für alle anderen Prüfungsformen",
       "start": "2027-08-19",
       "end": "2027-08-19"
      },
      {
       "kind": "meldung",
       "n": 2,
       "label": "Meldezeitraum für alle anderen Prüfungsformen",
       "start": "2027-08-23",
       "end": "2027-08-29"
      },
      {
       "kind": "pruefung",
       "n": 2,
       "label": "Prüfungszeitraum für alle anderen Prüfungsformen",
       "start": "2027-08-30",
       "end": "2027-09-18"
      },
      {
       "kind": "bewertung",
       "n": 2,
       "label": "Bewertungsfrist für alle anderen Prüfungsformen",
       "start": "2027-09-30",
       "end": "2027-09-30"
      }
     ]
    }
   ]
  }
 },
 "programs": [
  {
   "slug": "architektur-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/architektur-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "architektur-und-staedtebau-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/architektur-und-staedtebau-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "atlantic-studies-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/atlantic-studies-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "bau-und-umweltingenieurwesen-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/bau-und-umweltingenieurwesen-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "bauingenieurwesen-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/bauingenieurwesen-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "bauingenieurwesen-vertiefung-konstruktiver-ingenieurbau-fernstudium-master-of-science",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/bauingenieurwesen-vertiefung-konstruktiver-ingenieurbau-fernstudium-master-of-science/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "bildungswissenschaften-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/bildungswissenschaften-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "biochemie-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/biochemie-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "biologie-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/biologie-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "biomedizintechnik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/biomedizintechnik-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "chemie-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/chemie-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "chemie-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/chemie-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "computational-methods-in-engineering-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/computational-methods-in-engineering-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "deutsche-und-englische-linguistik-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/deutsche-und-englische-linguistik-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "elektrotechnik-und-informationstechnik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/elektrotechnik-und-informationstechnik-bsc/termine",
   "table": "luh-v1",
   "variant": "1",
   "checked_at": "2026-11-05"
  },
  {
   "slug": "elektrotechnik-und-informationstechnik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/elektrotechnik-und-informationstechnik-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "energietechnik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/energietechnik-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "energietechnik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/energietechnik-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "energy-technology-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/energy-technology-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "european-master-in-territorial-development-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/european-master-in-territorial-development-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "faecheruebergreifender-bachelorstudiengang",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/faecheruebergreifender-bachelorstudiengang/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "food-research-and-development-lebensmittelwissenschaft-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/food-research-and-development-lebensmittelwissenschaft-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "gartenbauwissenschaften-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/gartenbauwissenschaften-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "gartenbauwissenschaften-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/gartenbauwissenschaften-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "geodaesie-und-geoinformatik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/geodaesie-und-geoinformatik-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "geodaesie-und-geoinformatik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/geodaesie-und-geoinformatik-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "geographie-ba-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/geographie-ba-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "geowissenschaften-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/geowissenschaften-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "geowissenschaften-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/geowissenschaften-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "geschichte-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/geschichte-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "hochschule-wissenschaft-gesellschaft-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/hochschule-wissenschaft-gesellschaft-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "informatik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/informatik-bsc/termine",
   "table": "luh-v1",
   "variant": "1",
   "checked_at": "2026-11-05"
  },
  {
   "slug": "informatik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/informatik-msc/termine",
   "table": "luh-v1",
   "variant": "1",
   "checked_at": "2026-11-05"
  },
  {
   "slug": "international-horticulture",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/international-horticulture/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "international-mechatronics",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/international-mechatronics/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "landschaftsarchitektur-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/landschaftsarchitektur-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "landschaftsarchitektur-und-umweltplanung-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/landschaftsarchitektur-und-umweltplanung-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "landschaftswissenschaften-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/landschaftswissenschaften-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "lehramt-an-berufsbildenden-schulen-med",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/lehramt-an-berufsbildenden-schulen-med/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "lehramt-an-berufsbildenden-schulen-zweites-fach",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/lehramt-an-berufsbildenden-schulen-zweites-fach/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "lehramt-an-gymnasien-drittes-fach",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/lehramt-an-gymnasien-drittes-fach/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "lehramt-an-gymnasien-med",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/lehramt-an-gymnasien-med/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "lehramt-fuer-sonderpaedagogik-med",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/lehramt-fuer-sonderpaedagogik-med/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "lehramt-fuer-sonderpaedagogik-zweites-fach",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/lehramt-fuer-sonderpaedagogik-zweites-fach/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "life-science-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/life-science-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "life-science-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/life-science-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "maschinenbau-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/maschinenbau-bsc/termine",
   "table": "luh-v1",
   "variant": "1",
   "checked_at": "2026-11-05"
  },
  {
   "slug": "maschinenbau-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/maschinenbau-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "mathematik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/mathematik-bsc/termine",
   "table": "luh-v2",
   "variant": "2",
   "checked_at": "2026-11-05"
  },
  {
   "slug": "mathematik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/mathematik-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "mechatronik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/mechatronik-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "mechatronik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/mechatronik-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "medizintechnik",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/medizintechnik/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "meteorologie-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/meteorologie-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "meteorologie-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/meteorologie-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "molekulare-mikrobiologie-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/molekulare-mikrobiologie-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "molekulare-und-angewandte-pflanzenwissenschaften-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/molekulare-und-angewandte-pflanzenwissenschaften-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "nachhaltige-gesundheitsfoerderung-durch-sport-ms",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/nachhaltige-gesundheitsfoerderung-durch-sport-ms/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "nachhaltige-ingenieurwissenschaft-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/nachhaltige-ingenieurwissenschaft-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "nachhaltige-ingenieurwissenschaft-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/nachhaltige-ingenieurwissenschaft-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "nanotechnologie-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/nanotechnologie-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "nanotechnologie-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/nanotechnologie-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "neuere-deutsche-literaturwissenschaft-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/neuere-deutsche-literaturwissenschaft-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "north-american-studies",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/north-american-studies/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "optische-technologien-laser-und-photonik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/optische-technologien-laser-und-photonik-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "optische-technologien-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/optische-technologien-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "pflanzenbiotechnologie-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/pflanzenbiotechnologie-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "pflanzenbiotechnologie-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/pflanzenbiotechnologie-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "philosophy-of-science-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/philosophy-of-science-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "physik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/physik-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "physik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/physik-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "politikwissenschaft-ba",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/politikwissenschaft-ba/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "politikwissenschaft-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/politikwissenschaft-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "produktion-und-logistik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/produktion-und-logistik-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "produktion-und-logistik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/produktion-und-logistik-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "quantum-engineering-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/quantum-engineering-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "sonderpaedagogik-ba",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/sonderpaedagogik-ba/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "sonderpaedagogik-und-rehabilitationswissenschaften-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/sonderpaedagogik-und-rehabilitationswissenschaften-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "sozialwissenschaften-ba",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/sozialwissenschaften-ba/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "soziologie-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/soziologie-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "studiengang",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/studiengang/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "technical-education-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/technical-education-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "technische-informatik-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/technische-informatik-bsc/termine",
   "table": "luh-v1",
   "variant": "1",
   "checked_at": "2026-11-05"
  },
  {
   "slug": "technische-informatik-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/technische-informatik-msc/termine",
   "table": "luh-v1",
   "variant": "1",
   "checked_at": "2026-11-05"
  },
  {
   "slug": "umwelt-und-regionalplanung-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/umwelt-und-regionalplanung-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "umweltingenieurwesen-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/umweltingenieurwesen-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "umweltmeteorologie-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/umweltmeteorologie-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "wasser-und-umwelt-fernstudium-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/wasser-und-umwelt-fernstudium-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "water-resources-and-environmental-management-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/water-resources-and-environmental-management-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "wirtschaftsgeographie-innovation-und-nachhaltigkeit-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/wirtschaftsgeographie-innovation-und-nachhaltigkeit-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "wirtschaftsgeographie-ma",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/wirtschaftsgeographie-ma/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "wirtschaftsingenieurwesen-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/wirtschaftsingenieurwesen-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "wirtschaftsingenieurwesen-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/wirtschaftsingenieurwesen-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "wirtschaftswissenschaft-bsc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/wirtschaftswissenschaft-bsc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  },
  {
   "slug": "wirtschaftswissenschaft-msc",
   "url": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/wirtschaftswissenschaft-msc/termine",
   "table": null,
   "variant": null,
   "checked_at": null
  }
 ]
}
"""#

    static let hildesheim = #"""
{
 "v": 1,
 "university": "hildesheim",
 "note": "Uni Hildesheim: Start der POS-Anmeldung im LSF (alle Bachelor- und Masterstudiengaenge, keine einheitliche Frist, open_end; Ende = Semesterende) aus den Seiten in sources, gelesen am checked_at. programs: Pruefungsamt je Studiengang laut Zustaendigkeiten (nur Link bei Weiterbildung, Diplom/Magister und Sonderfaellen). Neu lesen: tools/gen-exam-registration-fixture.py --from-cache-hildesheim DIR. docs/PRUEFUNGSANMELDUNG-2026-11-05.md",
 "checked_at": "2026-11-05",
 "general": {
  "url": "https://www.uni-hildesheim.de/posanmeldung/haeufige-fragen-zur-online-anmeldung-zu-studien-pruefungsleistungen/",
  "title": "Online-Anmeldung zu Studien-/Prüfungsleistungen (POS, Universität Hildesheim)"
 },
 "qis_menu": "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0",
 "system": "LSF",
 "hint": "Im LSF: Meine Funktionen → POS-Management → „An-/Abmeldung zu Studien-/Prüfungsleistungen“, Semester, Modul und Veranstaltung wählen, „Zur Anmeldung“ tippen und selbst bestätigen. StudiNow füllt nichts aus und schickt nichts ab.",
 "disclaimer": "Verbindlich sind die Angaben im LSF und auf den Seiten des Prüfungsamts. Eine universitätsweit einheitliche Anmeldefrist gibt es nicht; einige Weiterbildungsmaster und Institute melden anders an.",
 "period_note": "Die Uni Hildesheim hat keine einheitliche Anmeldefrist. Ab dem Start der POS-Anmeldung meldest du dich im LSF je Prüfung an; Klausuren mit Frist sind verbindlich, die Frist steht im LSF an der Prüfung.",
 "sources": [
  {
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-2/fragen-zu-pruefungs-studienleistungen/",
   "title": "Prüfungsamt 2: Fragen zu Prüfungs-/Studienleistungen",
   "says": "Ab dem 11. November 2026 ist im LSF die POS-Anmeldung für das Wintersemester 26/27 für alle Bachelor- und Masterstudiengänge freigeschaltet (mit Ausnahme einiger Weiterbildungsmaster).",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://www.uni-hildesheim.de/dez3/it-abteilung/lsf-vergabe/lsf-termine/",
   "title": "LSF-Termine (IT-Abteilung)",
   "says": "11.11.2026: Beginn der POS Anmeldephase (Wintersemester 2026/2027).",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://www.uni-hildesheim.de/posanmeldung/haeufige-fragen-zur-online-anmeldung-zu-studien-pruefungsleistungen/",
   "title": "Häufige Fragen zur Online-Anmeldung zu Studien-/Prüfungsleistungen",
   "says": "Keine universitätsweit einheitlichen Fristen; Anmeldungen mit Frist sind verbindlich, ohne Frist unverbindlich und jederzeit stornierbar; Übersicht unter Meine Funktionen → POS-Management → Meine POS-Anmeldungen (bei Klausuren mit Ort und Zeit).",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://www.uni-hildesheim.de/posanmeldung/howto-schnellanleitung-zur-online-pruefungsanmeldung/",
   "title": "Schnellanleitung zur Online-Prüfungsanmeldung",
   "says": "LSF → Meine Funktionen → POS-Management → An-/Abmeldung zu Studien-/Prüfungsleistungen → Semester, Modul/Teilmodul, Veranstaltung → „Zur Anmeldung“ → bestätigen.",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://www.uni-hildesheim.de/termine-fristen/semesterzeiten-in-reintext-zum-barrierefreien-aufruf/",
   "title": "Semesterzeiten",
   "says": "Wintersemester 2026/27: Semesterzeit 01.10.2026 – 31.03.2027.",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/zustaendigkeiten-nach-studiengaengen/",
   "title": "Zuständigkeiten nach Studiengängen",
   "says": "Prüfungsamt je Studiengang (Link je Eintrag).",
   "checked_at": "2026-11-05"
  }
 ],
 "rules": [
  {
   "form": "Verbindliche Anmeldung",
   "withdraw_days_before": null,
   "text": "Anmeldungen mit Frist sind verbindlich: Das LSF zeigt bei der Anmeldung, bis wann du dich abmelden kannst."
  },
  {
   "form": "Unverbindliche Anmeldung",
   "withdraw_days_before": null,
   "text": "Anmeldungen ohne Frist sind unverbindlich und lassen sich im LSF jederzeit stornieren (höchstens 3 Semester rückwirkend)."
  },
  {
   "form": "Nachklausur",
   "withdraw_days_before": null,
   "text": "Nachklausuren meldest du im Semester der ursprünglichen Veranstaltung an (eigener Termin unter der Vorlesung)."
  },
  {
   "form": "Abschlussarbeit",
   "withdraw_days_before": null,
   "text": "Bachelor- und Masterarbeit: Anmeldeformular deines Prüfungsamts per Uni-E-Mail, nicht über das LSF."
  }
 ],
 "tables": {
  "hildesheim-pos": {
   "variant": null,
   "terms": [
    {
     "term": "WiSe 26/27",
     "periods": [
      {
       "kind": "meldung",
       "n": 1,
       "label": "POS-Anmeldung im LSF (Fristen je Prüfung im LSF)",
       "start": "2026-11-11",
       "end": "2027-03-31",
       "open_end": true,
       "source": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-2/fragen-zu-pruefungs-studienleistungen/"
      }
     ]
    }
   ]
  }
 },
 "programs": [
  {
   "slug": "austauschstudierende",
   "name": "Austauschstudierende",
   "faculty": "Fachbereichsübergreifende Studiengänge",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "fachbezogene-hochschulzugangsberechtigung-durch-pruefung-sog-immaturen-oder-z-pruefung",
   "name": "Fachbezogene Hochschulzugangsberechtigung durch Prüfung (sog. Immaturen- oder Z-Prüfung)",
   "faculty": "Fachbereichsübergreifende Studiengänge",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-6/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "polyvalenter-zwei-faecher-bachelor-studiengang-mit-lehramtsoption-ba",
   "name": "Polyvalenter Zwei-Fächer-Bachelor Studiengang (B. A./B. Sc.) - mit Lehramtsoption",
   "faculty": "Fachbereichsübergreifende Studiengänge",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/polyvalenter-zwei-faecher-bachelor-studiengang-mit-lehramtsoption/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "polyvalenter-zwei-faecher-bachelor-studiengang-mit-lehramtsoption-bsc",
   "name": "Polyvalenter Zwei-Fächer-Bachelor Studiengang (B. A./B. Sc.) - mit Lehramtsoption",
   "faculty": "Fachbereichsübergreifende Studiengänge",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/polyvalenter-zwei-faecher-bachelor-studiengang-mit-lehramtsoption/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "polyvalenter-zwei-faecher-bachelor-studiengang-individuelle-studienvarianten-ohne-lehramtsoption-ba",
   "name": "Polyvalenter Zwei-Fächer-Bachelor Studiengang (B. A./B. Sc.) - individuelle Studienvarianten (ohne Lehramtsoption)",
   "faculty": "Fachbereichsübergreifende Studiengänge",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/polyvalenter-zwei-faecher-bachelor-studiengang-varianten/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "polyvalenter-zwei-faecher-bachelor-studiengang-individuelle-studienvarianten-ohne-lehramtsoption-bsc",
   "name": "Polyvalenter Zwei-Fächer-Bachelor Studiengang (B. A./B. Sc.) - individuelle Studienvarianten (ohne Lehramtsoption)",
   "faculty": "Fachbereichsübergreifende Studiengänge",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/polyvalenter-zwei-faecher-bachelor-studiengang-varianten/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "lehramt-an-grund-haupt-und-realschulen-med",
   "name": "Lehramt an Grund-, Haupt- und Realschulen (M. Ed.)",
   "faculty": "Fachbereichsübergreifende Studiengänge",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/lehramt-an-grund-haupt-und-realschulen-master-of-education/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "erziehungswissenschaft-ba",
   "name": "Erziehungswissenschaft (B. A. und M. A.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-1/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "erziehungswissenschaft-ma",
   "name": "Erziehungswissenschaft (B. A. und M. A.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-1/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "psychologie-bsc",
   "name": "Psychologie (B.Sc.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-8/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "psychologie-msc",
   "name": "Psychologie (M.Sc.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-1/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "psychologie-mit-schwerpunkt-klinische-psychologie-und-psychotheraphie-msc",
   "name": "Psychologie mit Schwerpunkt Klinische Psychologie und Psychotheraphie (M. Sc.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-8/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "rechtspsychologie-msc",
   "name": "Rechtspsychologie (M. Sc.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-8/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "sozial-und-organisationspaedagogik-ba",
   "name": "Sozial- und Organisationspädagogik (B. A. und M. A.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-5/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "sozial-und-organisationspaedagogik-ma",
   "name": "Sozial- und Organisationspädagogik (B. A. und M. A.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-5/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "sozialpaedagogik-ba",
   "name": "Sozialpädagogik (B.A.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-5/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "soziale-dienste-ma",
   "name": "Soziale Dienste (M. A.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-5/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "staatliche-anerkennung-als-sozialpaedagog-in-ba",
   "name": "Staatliche Anerkennung als Sozialpädagog_in (B. A./Diplom)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-5/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "sport-gesundheit-leistung-ba",
   "name": "Sport, Gesundheit & Leistung (B. A.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/polyvalenter-zwei-faecher-bachelor-studiengang-varianten/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "sportwissenschaft-mit-dem-schwerpunkt-sport-gesundheit-und-leistung-in-der-lebensspanne-msc",
   "name": "Sportwissenschaft mit dem Schwerpunkt Sport, Gesundheit und Leistung in der Lebensspanne (M. Sc.)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-7/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "weiterbildungsprogramm-inklusive-bildung-inklusive-paedagogik-und-kommunikation-ma",
   "name": "Weiterbildungsprogramm Inklusive Bildung, Inklusive Pädagogik und Kommunikation (M.A. berufsbegleitend)",
   "faculty": "Fachbereich I: Erziehungs- und Sozialwissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-1/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "inszenierung-der-kuenste-und-der-medien-ma",
   "name": "Inszenierung der Künste und der Medien (M.A.), Künste und Gegenwartskulturen transdisziplinär (M.A.))",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-1/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "kuenste-und-gegenwartskulturen-transdisziplinaer-ma",
   "name": "Inszenierung der Künste und der Medien (M.A.), Künste und Gegenwartskulturen transdisziplinär (M.A.))",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-1/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "kreatives-schreiben-ba",
   "name": "Kreatives Schreiben (B. A.)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-2/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "kulturvermittlung-ma",
   "name": "Kulturvermittlung (M. A.)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-2/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "kulturvermittlung-kulturpolitik-und-transformation-im-kontext-der-kuenste-m-diation-culturelle-de-l-art-doppelmaster-ma",
   "name": "Kulturvermittlung, Kulturpolitik und Transformation im Kontext der Künste / Médiation Culturelle de l'Art - Doppelmaster (M.A.)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "kulturwissenschaften-und-aesthetische-praxis-ba",
   "name": "Kulturwissenschaften und ästhetische Praxis (B. A.)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-2/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "kulturwissenschaften-und-aesthetische-praxis-kulturpolitik-im-internationalen-vergleich-ba",
   "name": "Kulturwissenschaften und ästhetische Praxis - Kulturpolitik im internationalen Vergleich (B.A.+)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-2/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "kulturwissenschaftliche-dipl-studiengaenge-ausgelaufen",
   "name": "Kulturwissenschaftliche Dipl.-Studiengänge (ausgelaufen)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-2/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "literarisches-schreiben-und-lektorieren-ma",
   "name": "Literarisches Schreiben und Lektorieren (M. A.)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-2/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "philosophie-kuenste-medien-ba",
   "name": "Philosophie-Künste-Medien (B. A.)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-2/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "philosophie-und-kuenste-interkulturell-ma",
   "name": "Philosophie und Künste interkulturell (M. A.)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-2/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "szenische-kuenste-ba",
   "name": "Szenische Künste (B. A.)",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-2/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "weiterbildungsstudiengang-musik-welt-kulturelle-diversitaet-in-der-musikalischen-bildung",
   "name": "Weiterbildungsstudiengang musik.welt - kulturelle Diversität in der musikalischen Bildung",
   "faculty": "Fachbereich II: Kulturwissenschaften und Ästhetische Kommunikation",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "barrierefreie-kommunikation-ma",
   "name": "Barrierefreie Kommunikation (M. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-1/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "deutsch-als-zweitsprache-deutsch-als-fremdsprache-ma",
   "name": "Deutsch als Zweitsprache/Deutsch als Fremdsprache (M. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-1/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "english-applied-linguistics-ba",
   "name": "English Applied Linguistics (B. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/polyvalenter-zwei-faecher-bachelor-studiengang-varianten/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationale-kommunikation-und-uebersetzen-ba",
   "name": "Internationale Kommunikation und Übersetzen (B. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-8/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationale-fachkommunikation-sprachen-und-technik-ma",
   "name": "Internationale Fachkommunikation - Sprachen und Technik (M. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-7/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationale-fachkommunikation-diplom-ausgelaufen",
   "name": "Internationale Fachkommunikation (Diplom; ausgelaufen)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-3/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-ba",
   "name": "Internationales Informationsmanagement (B. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-3/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-digitale-sozialwissenschaften-ba",
   "name": "Internationales Informationsmanagement - Digitale Sozialwissenschaften (B. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-3/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-global-information-management-ba",
   "name": "Internationales Informationsmanagement - Global Information Management (B. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-interkulturelle-sprachwissenschaft-ba",
   "name": "Internationales Informationsmanagement - Interkulturelle Sprachwissenschaft (B. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-3/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-linguistik-ba",
   "name": "Internationales Informationsmanagement - Linguistik (B. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-3/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-informationswissenschaft-ma",
   "name": "Internationales Informationsmanagement - Informationswissenschaft (M. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsaemter-3-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-informationswissenschaft-joint-degree-programme-global-studies-on-management-and-information-science-glomis-ma",
   "name": "Internationales Informationsmanagement - Informationswissenschaft (M.A.) - Joint Degree Programme Global Studies on Management and Information Science (GLOMIS)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-informationswissenschaft-joint-degree-programme-european-master-in-lexicography-emlex-ma",
   "name": "Internationales Informationsmanagement - Informationswissenschaft (M.A.) - Joint Degree Programme European Master in Lexicography (EMLex)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-sprachwissenschaft-und-interkulturelle-kommunikation-ma",
   "name": "Internationales Informationsmanagement - Sprachwissenschaft und Interkulturelle Kommunikation (M. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsaemter-3-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "internationales-informationsmanagement-magister-ausgelaufen",
   "name": "Internationales Informationsmanagement (Magister; ausgelaufen)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-3/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "medientext-und-medienuebersetzung-ma",
   "name": "Medientext und Medienübersetzung (M. A.)",
   "faculty": "Fachbereich III: Sprach- und Informationswissenschaften",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsaemter-3-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "angewandte-informatik-bsc",
   "name": "Angewandte Informatik (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "angewandte-informatik-msc",
   "name": "Angewandte Informatik (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "angewandte-informatik-studienvariante-im-studiengang-informationsmanagement-und-informationstechnologie-bsc",
   "name": "Angewandte Informatik (Studienvariante im Studiengang Informationsmanagement und Informationstechnologie) (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "angewandte-informatik-studienvariante-im-studiengang-informationsmanagement-und-informationstechnologie-msc",
   "name": "Angewandte Informatik (Studienvariante im Studiengang Informationsmanagement und Informationstechnologie) (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "data-analytics-studienvariante-im-masterstudiengang-informationsmanagement-und-informationstechnologie-msc",
   "name": "Data Analytics (Studienvariante im Masterstudiengang Informationsmanagement und Informationstechnologie) (M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-international/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "data-analytics-studienvariante-im-masterstudiengang-angewandte-informatik-msc",
   "name": "Data Analytics (Studienvariante im Masterstudiengang Angewandte Informatik) (M.Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "international-master-in-data-analytics-msc",
   "name": "International Master in Data Analytics (M.Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "international-master-in-software-engineering-msc",
   "name": "International Master in Software Engineering (M.Sc)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-international/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "informationsmanagement-und-informationstechnologie-bsc",
   "name": "Informationsmanagement und Informationstechnologie (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsaemter-3-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "informationsmanagement-und-informationstechnologie-msc",
   "name": "Informationsmanagement und Informationstechnologie (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsaemter-3-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "informationsmanagement-u-informationstechnologie-studienvariante-im-studiengang-angewandte-informatik-bsc",
   "name": "Informationsmanagement u. Informationstechnologie (Studienvariante im Studiengang Angewandte Informatik) (B.Sc. und M.Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "informationsmanagement-u-informationstechnologie-studienvariante-im-studiengang-angewandte-informatik-msc",
   "name": "Informationsmanagement u. Informationstechnologie (Studienvariante im Studiengang Angewandte Informatik) (B.Sc. und M.Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "medieninformatik-studienvariante-im-studiengang-angewandte-informatik-bsc",
   "name": "Medieninformatik (Studienvariante im Studiengang Angewandte Informatik) (B.Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "umweltsicherung-bsc",
   "name": "Umweltsicherung (B. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/polyvalenter-zwei-faecher-bachelor-studiengang-varianten/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "umwelt-naturschutz-und-nachhaltigkeit-msc",
   "name": "Umwelt, Naturschutz und Nachhaltigkeit (M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsamt-7/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "umweltinformatik-studienvariante-im-studiengang-angewandte-informatik-bsc",
   "name": "Umweltinformatik (Studienvariante im Studiengang Angewandte Informatik) (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "umweltinformatik-studienvariante-im-studiengang-angewandte-informatik-msc",
   "name": "Umweltinformatik (Studienvariante im Studiengang Angewandte Informatik) (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wirtschaftsinformatik-bsc",
   "name": "Wirtschaftsinformatik (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsaemter-3-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wirtschaftsinformatik-msc",
   "name": "Wirtschaftsinformatik (B. Sc. und M. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/dez3/pruefungsamt/pruefungsaemter-3-4/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wirtschaft-plus-bsc",
   "name": "Wirtschaft Plus (B. Sc.)",
   "faculty": "Fachbereich IV: Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/polyvalenter-zwei-faecher-bachelor-studiengang-varianten/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "alle-bachelor-und-masterstudiengaenge",
   "name": "Alle Bachelor- und Masterstudiengänge",
   "faculty": null,
   "url": "https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-2/fragen-zu-pruefungs-studienleistungen/",
   "table": "hildesheim-pos",
   "variant": null,
   "checked_at": "2026-11-05",
   "default": true
  }
 ]
}
"""#

    static let hsh = #"""
{
 "v": 1,
 "university": "hsh",
 "note": "HsH: Meldezeitraeume je Abteilung aus den oeffentlichen Termin- und Informationsseiten der Fakultaeten (sources, gelesen am checked_at); angemeldet wird im Campusmanagement (HISinOne). Abteilungen ohne gefundenen Zeitraum nur mit Link (table null). Neu lesen: tools/hsh-exam-registration.py. docs/STUDIENGAENGE-HSH-2026-11-05.md",
 "checked_at": "2026-11-05",
 "general": {
  "url": "https://campusmanagement.hs-hannover.de/qisserver/pages/cm/exa/nominalactualcomparison/sollistvergleichBaum.xhtml?_flowId=sollistvergleich-flow",
  "title": "Prüfungen anmelden (Campusmanagement der Hochschule Hannover)"
 },
 "qis_menu": "https://campusmanagement.hs-hannover.de/qisserver/pages/cm/exa/nominalactualcomparison/sollistvergleichBaum.xhtml?_flowId=sollistvergleich-flow",
 "system": "HISinOne",
 "hint": "Im Campusmanagement: Mein Studium → „Prüfungen anmelden“, Prüfung im Baum suchen und „Anmelden“ selbst auslösen. StudiNow füllt nichts aus und schickt nichts ab.",
 "disclaimer": "Verbindlich sind die Angaben im Campusmanagement und auf den Seiten deiner Fakultät. Jede Abteilung legt ihren Anmeldezeitraum selbst fest; Labore, Projekte und Abschlussarbeiten melden teils anders an.",
 "sources": [
  {
   "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/Informatik/Termine/2026-09-28-Abt_I_Termine_Wintersemester_26-27.pdf",
   "title": "Fakultät IV, Abteilung Informatik",
   "says": "Anmeldung zu den Prüfungen (Prüfungszeitraum A): 2026-09-07 bis 2026-09-14; Anmeldung zu den Prüfungen (Prüfungszeitraum B): 2026-11-30 bis 2026-12-13",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Termine-Sprechzeiten/26-09-29-WiSe2026-Abt.WI-Semestertermine.pdf",
   "title": "Fakultät IV, Abteilung Wirtschaftsinformatik",
   "says": "Anmeldung zu den Prüfungen (Januar 2027): 2026-11-02 bis 2026-11-29",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/BWL/Formulare_Und_Informationen/Semestertermine_Abteilung_BWL_WiSe26-27.pdf",
   "title": "Fakultät IV, Abteilung Betriebswirtschaft",
   "says": "Prüfungsanmeldung: 2026-11-02 bis 2026-11-22",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Sonstiges/Informationen_Pruefungsanmeldung.pdf",
   "title": "Fakultät II, Abteilung Maschinenbau",
   "says": "Online-Anmeldung zu den Prüfungen: 2026-10-14 bis 2026-10-28",
   "checked_at": "2026-11-05"
  },
  {
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "title": "Fakultät III, Abteilung Information und Kommunikation",
   "says": "Anmeldezeitraum Wintersemester: 2026-11-15 bis 2026-11-30; Anmeldezeitraum Sommersemester (jährlich gleich): 2027-05-15 bis 2027-05-31",
   "checked_at": "2026-11-05"
  }
 ],
 "rules": [
  {
   "form": "Fakultät IV, Abteilung Wirtschaftsinformatik",
   "withdraw_days_before": null,
   "text": "Abmeldung bis zum 29.11.2026 im Campusmanagement."
  },
  {
   "form": "Fakultät II, Abteilung Maschinenbau",
   "withdraw_days_before": 7,
   "text": "Abmeldung bis eine Woche vor dem Prüfungstermin ohne Angabe von Gründen."
  },
  {
   "form": "Fakultät II, Abteilung Bioverfahrenstechnik",
   "withdraw_days_before": 7,
   "text": "Abmeldung bis eine Woche vor dem Prüfungstermin ohne Angabe von Gründen."
  }
 ],
 "tables": {
  "hsh-f4-informatik": {
   "variant": null,
   "title": "Fakultät IV, Abteilung Informatik",
   "terms": [
    {
     "term": "WiSe 26/27",
     "periods": [
      {
       "kind": "meldung",
       "n": 1,
       "label": "Anmeldung zu den Prüfungen (Prüfungszeitraum A)",
       "start": "2026-09-07",
       "end": "2026-09-14",
       "source": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/Informatik/Termine/2026-09-28-Abt_I_Termine_Wintersemester_26-27.pdf"
      },
      {
       "kind": "meldung",
       "n": 2,
       "label": "Anmeldung zu den Prüfungen (Prüfungszeitraum B)",
       "start": "2026-11-30",
       "end": "2026-12-13",
       "source": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/Informatik/Termine/2026-09-28-Abt_I_Termine_Wintersemester_26-27.pdf"
      }
     ]
    }
   ]
  },
  "hsh-f4-wi": {
   "variant": null,
   "title": "Fakultät IV, Abteilung Wirtschaftsinformatik",
   "terms": [
    {
     "term": "WiSe 26/27",
     "periods": [
      {
       "kind": "meldung",
       "n": 1,
       "label": "Anmeldung zu den Prüfungen (Januar 2027)",
       "start": "2026-11-02",
       "end": "2026-11-29",
       "source": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Termine-Sprechzeiten/26-09-29-WiSe2026-Abt.WI-Semestertermine.pdf"
      }
     ]
    }
   ]
  },
  "hsh-f4-bwl": {
   "variant": null,
   "title": "Fakultät IV, Abteilung Betriebswirtschaft",
   "terms": [
    {
     "term": "WiSe 26/27",
     "periods": [
      {
       "kind": "meldung",
       "n": 1,
       "label": "Prüfungsanmeldung",
       "start": "2026-11-02",
       "end": "2026-11-22",
       "source": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/BWL/Formulare_Und_Informationen/Semestertermine_Abteilung_BWL_WiSe26-27.pdf"
      }
     ]
    }
   ]
  },
  "hsh-f2-m": {
   "variant": null,
   "title": "Fakultät II, Abteilung Maschinenbau",
   "terms": [
    {
     "term": "WiSe 26/27",
     "periods": [
      {
       "kind": "meldung",
       "n": 1,
       "label": "Online-Anmeldung zu den Prüfungen",
       "start": "2026-10-14",
       "end": "2026-10-28",
       "source": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Sonstiges/Informationen_Pruefungsanmeldung.pdf"
      }
     ]
    }
   ]
  },
  "hsh-f3-ik": {
   "variant": null,
   "title": "Fakultät III, Abteilung Information und Kommunikation",
   "terms": [
    {
     "term": "WiSe 26/27",
     "periods": [
      {
       "kind": "meldung",
       "n": 1,
       "label": "Anmeldezeitraum Wintersemester",
       "start": "2026-11-15",
       "end": "2026-11-30",
       "source": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten"
      }
     ]
    },
    {
     "term": "SoSe 27",
     "periods": [
      {
       "kind": "meldung",
       "n": 1,
       "label": "Anmeldezeitraum Sommersemester (jährlich gleich)",
       "start": "2027-05-15",
       "end": "2027-05-31",
       "source": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten"
      }
     ]
    }
   ]
  }
 },
 "programs": [
  {
   "slug": "angewandte-informatik-bsc",
   "name": "Angewandte Informatik",
   "degree": "B.Sc.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-informatik/termine",
   "table": "hsh-f4-informatik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "angewandte-informatik-msc",
   "name": "Angewandte Informatik",
   "degree": "M.Sc.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-informatik/termine",
   "table": "hsh-f4-informatik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "angewandte-mathematik-und-data-science-bsc",
   "name": "Angewandte Mathematik und Data Science",
   "degree": "B.Sc.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "bank-und-versicherungswesen-ba",
   "name": "Bank- und Versicherungswesen",
   "degree": "B.A.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-betriebswirtschaft/termine",
   "table": "hsh-f4-bwl",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "betriebswirtschaftslehre-bsc",
   "name": "Betriebswirtschaftslehre",
   "degree": "B.Sc.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-betriebswirtschaft/termine",
   "table": "hsh-f4-bwl",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "bildungswissenschaften-fuer-pflege-und-gesundheitsberufe-ma",
   "name": "Bildungswissenschaften für Pflege- und Gesundheitsberufe",
   "degree": "M.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "biotechnologie-und-umwelttechnik-beng",
   "name": "Biotechnologie und Umwelttechnik",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-bv/pruefungsplaene-abt-bv",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "design-und-medien-ma",
   "name": "Design und Medien",
   "degree": "M.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "digitale-transformation-msc",
   "name": "Digitale Transformation",
   "degree": "M.Sc.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-wirtschaftsinformatik/termine",
   "table": "hsh-f4-wi",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "dual-studieren-in-der-elektro-und-informationstechnik-beng",
   "name": "Dual Studieren in der Elektro- und Informationstechnik",
   "degree": "B.Eng.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "elektrische-energiesysteme-und-elektromobilitaet-meng",
   "name": "Elektrische Energiesysteme und Elektromobilität",
   "degree": "M.Eng.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "elektrotechnik-und-informationstechnik-beng",
   "name": "Elektrotechnik und Informationstechnik",
   "degree": "B.Eng.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "erweiterte-pflegepraxis-advanced-nursing-practice-anp-community-health-nursing-chn-msc",
   "name": "Erweiterte Pflegepraxis – Advanced Nursing Practice [ANP]/ Community Health Nursing [CHN]",
   "degree": "M.Sc.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "fernsehjournalismus-und-dokumentarfilm-ma",
   "name": "Fernsehjournalismus und Dokumentarfilm",
   "degree": "M.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "forschung-und-professionalisierung-sozialer-arbeit-ma",
   "name": "Forschung und Professionalisierung Sozialer Arbeit",
   "degree": "M.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "future-food-systems-beng",
   "name": "Future Food Systems",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-bv/pruefungsplaene-abt-bv",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "future-food-systems-meng",
   "name": "Future Food Systems",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-bv/pruefungsplaene-abt-bv",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "green-engineering-energietechnik-und-verfahrenstechnik-beng",
   "name": "Green Engineering – Energietechnik und Verfahrenstechnik",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "green-engineering-nachhaltige-energie-und-verfahrenstechnik-fuer-die-biooekonomie-meng",
   "name": "Green Engineering - Nachhaltige Energie- und Verfahrenstechnik für die Bioökonomie",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://campusmanagement.hs-hannover.de/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "heilpaedagogik-inklusive-bildung-und-begleitung-ba",
   "name": "Heilpädagogik - Inklusive Bildung und Begleitung",
   "degree": "B.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "heilpaedagogik-inklusive-bildung-und-begleitung-berufsbegleitend-ba",
   "name": "Heilpädagogik - Inklusive Bildung und Begleitung - berufsbegleitend",
   "degree": "B.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "informationsmanagement-ba",
   "name": "Informationsmanagement",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "informationsmanagement-berufsbegleitend-ba",
   "name": "Informationsmanagement berufsbegleitend",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "ingenieurinformatik-maschinenbau-beng",
   "name": "Ingenieurinformatik Maschinenbau",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "ingenieurinformatik-maschinenbau-dual-beng",
   "name": "Ingenieurinformatik Maschinenbau dual",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "innenarchitektur-ba",
   "name": "Innenarchitektur",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "integrated-media-communication-imc-dual-ba",
   "name": "Integrated Media & Communication (IMC) Dual",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "intelligente-produktion-meng",
   "name": "Intelligente Produktion",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "international-business-studies-bsc",
   "name": "International Business Studies",
   "degree": "B.Sc.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-betriebswirtschaft/termine",
   "table": "hsh-f4-bwl",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "journalistik-ba",
   "name": "Journalistik",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "kommunikationsmanagement-ma",
   "name": "Kommunikationsmanagement",
   "degree": "M.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "konstruktionstechnik-dual-beng",
   "name": "Konstruktionstechnik dual",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "lbs-sprint-berufliche-fachrichtung-pflege-master",
   "name": "LBS-Sprint - berufliche Fachrichtung Pflege",
   "degree": "Master",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "lebensmittelverpackungstechnologie-beng",
   "name": "Lebensmittelverpackungstechnologie",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-bv/pruefungsplaene-abt-bv",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "management-fuer-pflege-und-gesundheitsberufe-ma",
   "name": "Management für Pflege- und Gesundheitsberufe",
   "degree": "M.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "maschinenbau-beng",
   "name": "Maschinenbau",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "maschinenbau-entwicklung-meng",
   "name": "Maschinenbau – Entwicklung",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "maschinenbau-produktionssysteme-dual-meng",
   "name": "Maschinenbau - Produktionssysteme dual",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "mechatronik-beng",
   "name": "Mechatronik",
   "degree": "B.Eng.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "mechatronik-dual-beng",
   "name": "Mechatronik dual",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "mediendesign-ba",
   "name": "Mediendesign",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "mediendesigninformatik-bsc",
   "name": "Mediendesigninformatik",
   "degree": "B.Sc.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-informatik/termine",
   "table": "hsh-f4-informatik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "medizinisches-informationsmanagement-bsc",
   "name": "Medizinisches Informationsmanagement",
   "degree": "B.Sc.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "medizinisches-informationsmanagement-msc",
   "name": "Medizinisches Informationsmanagement",
   "degree": "M.Sc.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "milch-und-verpackungswirtschaft-meng",
   "name": "Milch- und Verpackungswirtschaft",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-bv/pruefungsplaene-abt-bv",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "milchwirtschaftliche-lebensmitteltechnologie-beng",
   "name": "Milchwirtschaftliche Lebensmitteltechnologie",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-bv/pruefungsplaene-abt-bv",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "mittelstaendische-unternehmensfuehrung-in-entrepreneurship-mba",
   "name": "Mittelständische Unternehmensführung in Entrepreneurship",
   "degree": "MBA",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-betriebswirtschaft/termine",
   "table": "hsh-f4-bwl",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "mode-konzept-design-kommunikation-ba",
   "name": "MODE: konzept. design. kommunikation.",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "nachhaltige-elektrische-energieversorgung-beng",
   "name": "Nachhaltige Elektrische Energieversorgung",
   "degree": "B.Eng.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "pflege-ba",
   "name": "Pflege",
   "degree": "B.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "produktdesign-ba",
   "name": "Produktdesign",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "produktionstechnik-dual-beng",
   "name": "Produktionstechnik dual",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "prozess-engineering-und-produktionsmanagement-meng",
   "name": "Prozess-Engineering und Produktionsmanagement",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "public-relations-ba",
   "name": "Public Relations",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "religionspaedagogik-und-soziale-arbeit-ba",
   "name": "Religionspädagogik und Soziale Arbeit",
   "degree": "B.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "sensor-und-automatisierungstechnik-meng",
   "name": "Sensor- und Automatisierungstechnik",
   "degree": "M.Eng.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "soziale-arbeit-berufsbegleitend-ba",
   "name": "Soziale Arbeit - berufsbegleitend",
   "degree": "B.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "soziale-arbeit-grundstaendig-ba",
   "name": "Soziale Arbeit - grundständig",
   "degree": "B.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "szenografie-kostuem-experimentelle-gestaltung-ba",
   "name": "Szenografie – Kostüm – Experimentelle Gestaltung",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "technische-produktentwicklung-meng",
   "name": "Technische Produktentwicklung",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "technisches-informationsdesign-und-technische-redaktion-bsc",
   "name": "Technisches Informationsdesign und Technische Redaktion",
   "degree": "B.Sc.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "technologie-nachwachsender-rohstoffe-beng",
   "name": "Technologie Nachwachsender Rohstoffe",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-bv/pruefungsplaene-abt-bv",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "therapeutische-arbeit-mit-kindern-und-jugendlichen-ma",
   "name": "Therapeutische Arbeit mit Kindern und Jugendlichen",
   "degree": "M.A.",
   "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
   "url": "https://f5.hs-hannover.de/studium/studieninformationen/ordnungen",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "unternehmensentwicklung-msc",
   "name": "Unternehmensentwicklung",
   "degree": "M.Sc.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-betriebswirtschaft/termine",
   "table": "hsh-f4-bwl",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "veranstaltungsmanagement-ba",
   "name": "Veranstaltungsmanagement",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": "hsh-f3-ik",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "verfahrenstechnik-energietechnik-und-umwelttechnik-beng",
   "name": "Verfahrenstechnik, Energietechnik und Umwelttechnik",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://campusmanagement.hs-hannover.de/",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "verwaltungsinformatik-bsc",
   "name": "Verwaltungsinformatik",
   "degree": "B.Sc.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-wirtschaftsinformatik/termine",
   "table": "hsh-f4-wi",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "visual-journalism-and-documentary-photography-ba",
   "name": "Visual Journalism and Documentary Photography",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "visuelle-kommunikation-ba",
   "name": "Visuelle Kommunikation",
   "degree": "B.A.",
   "faculty": "Fakultät III – Medien, Information und Design",
   "url": "https://f3.hs-hannover.de/studium/pruefungsangelegenheiten",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wertschoepfungsmanagement-im-maschinenbau-dual-meng",
   "name": "Wertschöpfungsmanagement im Maschinenbau dual",
   "degree": "M.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wirtschaftsinformatik-bsc",
   "name": "Wirtschaftsinformatik",
   "degree": "B.Sc.",
   "faculty": "Fakultät IV – Wirtschaft und Informatik",
   "url": "https://f4.hs-hannover.de/service/formulare-und-informationen/abteilung-wirtschaftsinformatik/termine",
   "table": "hsh-f4-wi",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wirtschaftsingenieur-elektrotechnik-beng",
   "name": "Wirtschaftsingenieur Elektrotechnik",
   "degree": "B.Eng.",
   "faculty": "Fakultät I – Elektro- und Informationstechnik",
   "url": "https://f1.hs-hannover.de/service/f1-quicklinks/zeit-stunden-u-pruefungsplan",
   "table": null,
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wirtschaftsingenieur-in-technischer-vertrieb-dual-beng",
   "name": "Wirtschaftsingenieur/in (Technischer Vertrieb) dual",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wirtschaftsingenieurwesen-maschinenbau-beng",
   "name": "Wirtschaftsingenieurwesen Maschinenbau",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  },
  {
   "slug": "wirtschaftsingenieurwesen-maschinenbau-dual-beng",
   "name": "Wirtschaftsingenieurwesen Maschinenbau dual",
   "degree": "B.Eng.",
   "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
   "url": "https://f2.hs-hannover.de/service/quicklinks-abteilung-mmd/pruefungsplaene-abt-m-md",
   "table": "hsh-f2-m",
   "variant": null,
   "checked_at": "2026-11-05"
  }
 ]
}
"""#
}
