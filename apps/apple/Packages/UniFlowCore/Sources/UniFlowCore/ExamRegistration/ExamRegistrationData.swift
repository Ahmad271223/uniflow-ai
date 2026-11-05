// Erzeugt von tools/gen-exam-registration-fixture.py aus packages/shared-contracts/exam-registration-luh.json - nicht von Hand aendern.
enum ExamRegistrationData {
    static let json = #"""
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
}
