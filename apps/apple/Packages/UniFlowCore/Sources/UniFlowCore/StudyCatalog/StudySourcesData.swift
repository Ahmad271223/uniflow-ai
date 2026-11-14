// Erzeugt von tools/gen-study-catalog-fixture.py aus packages/shared-contracts/study-sources-all.json - nicht von Hand aendern.
enum StudySourcesData {
    static let json = #"""
{
 "v": 1,
 "note": "ERZEUGT von tools/gen-study-catalog-fixture.py aus study-sources.json (gepflegt, vorn), study-sources-luh.json (alle LUH-Studiengaenge; Quelle luh-grundstock = nur aus dem Grundstock der App), study-sources-hildesheim.json (Universitaet Hildesheim; Quelle hildesheim-grundstock) und study-sources-hsh.json (Hochschule Hannover; Quelle hsh-grundstock) - nicht von Hand aendern. Register der Modulkatalog-Quellen (docs/STUDIENVERLAUF-2026-11-04.md). Nur oeffentliche Kataloge ohne Anmeldung. Die breite Erhebung aller LUH-Studiengaenge steht in study-sources-luh.json (tools/luh-programs.py); hier stehen nur Quellen, deren Format der Parser liest. study_plan je PO (null = keiner bekannt): Studienverlaufsplan der Fakultaet (format luh-fei-verlaufsplan, eine PDF-Seite, Semester als Zeilen); page_url = Seite des Studiengangs, auf der der aktuelle Plan verlinkt ist.",
 "formats": [
  "luh-modkat",
  "luh-fei-verlaufsplan",
  "grundstock"
 ],
 "universities": [
  {
   "id": "luh",
   "name": "Leibniz Universität Hannover",
   "sources": [
    {
     "id": "luh-fei-modkat",
     "format": "luh-modkat",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "url_pattern": "https://modkat.fei.uni-hannover.de/material/modkat-full-{code}-{term}.pdf",
     "mirror_patterns": [
      "https://modkat.fei.uni-hannover.de/material/modkat-{code}-{term}.pdf"
     ],
     "overview_url": "https://modkat.fei.uni-hannover.de/",
     "term_pattern": "WS_JJJJ_JJ | SS_JJJJ",
     "probe_current_term": true
    },
    {
     "id": "luh-grundstock",
     "format": "grundstock",
     "note": "Kataloge ausserhalb von modkat: nur aus dem StudiNow-Grundstock (App-Ressource StudyCatalogSeed), auf dem Geraet wird nichts geladen (tools/build-luh-seed.py)",
     "probe_current_term": false
    }
   ],
   "programs": [
    {
     "id": "technische-informatik-bsc",
     "program": "Technische Informatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Technische Informatik"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_techinf_bpo26.pdf",
     "pos": [
      {
       "po": "2025",
       "code": "TIBSc25",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": {
        "url": "https://www.fei.uni-hannover.de/fileadmin/fei/Dateien-Studium/Studiengaenge_Technische_Informatik/B.Sc/Studienverlaufsplan_Bachelor_Technische_Informatik_WS2026-27.pdf",
        "format": "luh-fei-verlaufsplan",
        "page_url": "https://www.fei.uni-hannover.de/studium/studienangebot/technische-informatik"
       }
      },
      {
       "po": "2022",
       "code": "TIBSc22",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null
      }
     ]
    },
    {
     "id": "informatik-bsc",
     "program": "Informatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Informatik"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_inform_bpo26.pdf",
     "pos": [
      {
       "po": "2022",
       "code": "INFBSc22",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2024/25",
        "WS 2026/27"
       ],
       "study_plan": {
        "url": "https://www.fei.uni-hannover.de/fileadmin/fei/Dateien-Studium/Studiengaenge_Informatik/B.Sc/Studienverlaufsplan_Bachelor_Informatik_WS2026-27.pdf",
        "format": "luh-fei-verlaufsplan",
        "page_url": "https://www.fei.uni-hannover.de/studium/studienangebot/informatik"
       }
      }
     ]
    },
    {
     "id": "aesthetische-bildung-zertifikat",
     "program": "Ästhetische Bildung",
     "degree": "Zertifikat",
     "qis_names": [
      "Ästhetische Bildung",
      "Ästhetische Bildung (PO 2017)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_aesth_bildung_zpo2017.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "arbeitswissenschaft-berufsbegleitend-m-a",
     "program": "Arbeitswissenschaft berufsbegleitend",
     "degree": "M.A.",
     "qis_names": [
      "Arbeitswissenschaft berufsbegleitend",
      "Arbeitswissenschaft berufsbegleitend (PO 2018)"
     ],
     "regular_semesters": 7,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_arbeitswiss_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "arbeitswissenschaft-weiterbildungsstudium-zertifikat",
     "program": "Arbeitswissenschaft (Weiterbildungsstudium)",
     "degree": "Zertifikat",
     "qis_names": [
      "Arbeitswissenschaft (Weiterbildungsstudium)",
      "Arbeitswissenschaft (Weiterbildungsstudium) (PO 2018)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_arbeitswiss_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "architektur-und-staedtebau-m-sc",
     "program": "Architektur und Städtebau",
     "degree": "M.Sc.",
     "qis_names": [
      "Architektur und Städtebau",
      "Architektur und Städtebau (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_archstadt_mpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": [
      {
       "po": "2020",
       "code": "architektur-und-staedtebau|m.sc.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|architektur-und-staedtebau|m.sc.|2020",
       "format": "luh-modulbeschreibung",
       "url": "https://www.archland.uni-hannover.de/fileadmin/archland/STUDIUM/architektur_und_staedtebau/Modulkatalog_MSc-ArchStaedtebau_PO2020_01.pdf"
      }
     ]
    },
    {
     "id": "architektur-b-sc",
     "program": "Architektur",
     "degree": "B.Sc.",
     "qis_names": [
      "Architektur",
      "Architektur (PO 2019)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_archit_bpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": [
      {
       "po": "2019",
       "code": "architektur|b.sc.|2019",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|architektur|b.sc.|2019",
       "format": "luh-modulbeschreibung",
       "url": "https://www.archland.uni-hannover.de/fileadmin/archland/STUDIUM/architektur/Modulkatalog_BSc-Architektur_PO2019_01.pdf"
      }
     ]
    },
    {
     "id": "atlantic-studies-history-culture-and-society-m-a",
     "program": "Atlantic Studies/ History, Culture and Society",
     "degree": "M.A.",
     "qis_names": [
      "Atlantic Studies/ History, Culture and Society",
      "Atlantic Studies/ History, Culture and Society (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_atlantic_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "atlantic-studies-in-history-culture-and-society|m.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|atlantic-studies-in-history-culture-and-society|m.a.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.hist.uni-hannover.de/fileadmin/hist/News_und_Veranstaltungen/PDF/Modulkatalog_Atlantic_Studies_ab_WiSe_2026_2027.pdf"
      }
     ]
    },
    {
     "id": "bau-und-umweltingenieurwesen-b-sc",
     "program": "Bau- und Umweltingenieurwesen",
     "degree": "B.Sc.",
     "qis_names": [
      "Bau- und Umweltingenieurwesen",
      "Bau- und Umweltingenieurwesen (PO 2025)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_bauuming_bpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2025",
       "code": "bau-und-umweltingenieurwesen|b.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|bau-und-umweltingenieurwesen|b.sc.|2025",
       "format": "fbg-modulhandbuch",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Studium/Bauingenieurwesen/Modulhandbuecher/PO_25/Modulhandbuch_PO25_BU.pdf"
      }
     ]
    },
    {
     "id": "bauingenieurwesen-m-sc",
     "program": "Bauingenieurwesen",
     "degree": "M.Sc.",
     "qis_names": [
      "Bauingenieurwesen",
      "Bauingenieurwesen (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_bauing_po_m_2026.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2025",
       "code": "bauingenieurwesen|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|bauingenieurwesen|m.sc.|2025",
       "format": "fbg-modulhandbuch",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Studium/Bauingenieurwesen/Modulhandbuecher/PO_25/Modulhandbuch_PO25_BAU.pdf"
      }
     ]
    },
    {
     "id": "bildungswissenschaften-m-a",
     "program": "Bildungswissenschaften",
     "degree": "M.A.",
     "qis_names": [
      "Bildungswissenschaften",
      "Bildungswissenschaften (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_bildwiss_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2020",
       "code": "bildungswissenschaften|m.a.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|bildungswissenschaften|m.a.|2020",
       "format": "luh-modulbeschreibung",
       "url": "https://www.ifbe.uni-hannover.de/fileadmin/ifbe/PDF/MA_BW_Modulkatalog_ab_WS_26-27_Stand_2026-09-08.pdf"
      }
     ]
    },
    {
     "id": "biochemie-m-sc",
     "program": "Biochemie",
     "degree": "M.Sc.",
     "qis_names": [
      "Biochemie",
      "Biochemie (PO 2024)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_Biochemie_mpo_24.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": []
    },
    {
     "id": "biochemie-b-sc",
     "program": "Biochemie",
     "degree": "B.Sc.",
     "qis_names": [
      "Biochemie",
      "Biochemie (PO 2024)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_biochem_bpo26_3.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2024",
       "code": "biochemie|b.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|biochemie|b.sc.|2024",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Biochemie-BSc/20251001_Modulhandbuch_BScBC_Pflicht.pdf",
       "label": "Pflichtmodule"
      }
     ]
    },
    {
     "id": "biologie-b-sc",
     "program": "Biologie",
     "degree": "B.Sc.",
     "qis_names": [
      "Biologie",
      "Biologie (PO 2018)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_bio_bpo2026_1.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2018",
       "code": "biologie|b.sc.|2018",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|biologie|b.sc.|2018",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Biologie/Detail-Biologie-BSc/Modulkataloge/2026_Modulkatalog_Biologie_WiSe26-27_final.pdf"
      }
     ]
    },
    {
     "id": "biomedizintechnik-m-sc",
     "program": "Biomedizintechnik",
     "degree": "M.Sc.",
     "qis_names": [
      "Biomedizintechnik",
      "Biomedizintechnik (PO 2017)",
      "Biomedizintechnik (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_biomed_mpo_2015_26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2017",
       "code": "biomedizintechnik|m.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|biomedizintechnik|m.sc.|2017",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_BMT_MSc_PO_17.pdf"
      },
      {
       "po": "2026",
       "code": "biomedizintechnik|m.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|biomedizintechnik|m.sc.|2026",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_BMT_MSC_PO_26.pdf"
      }
     ]
    },
    {
     "id": "chemie-m-sc",
     "program": "Chemie",
     "degree": "M.Sc.",
     "qis_names": [
      "Chemie",
      "Chemie (PO 2017)",
      "Chemie (PO 2024)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_chemie_mpo2026.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2017",
       "code": "chemie-1|m.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie-1|m.sc.|2017",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-MSc/Modulhandbuch-Chemie-Master-PO2017.pdf"
      },
      {
       "po": "2024",
       "code": "chemie-1|m.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie-1|m.sc.|2024",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-MSc/Modulkatalog-Chemie-Master-PO2024.pdf"
      }
     ]
    },
    {
     "id": "chemie-b-sc",
     "program": "Chemie",
     "degree": "B.Sc.",
     "qis_names": [
      "Chemie",
      "Chemie (PO 2016)",
      "Chemie (PO 2024)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_chemie_bpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "chemie|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie|b.sc.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-BSc/Modulhandbuch_Bachelor_Chemie_20230918.pdf"
      },
      {
       "po": "2024",
       "code": "chemie|b.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie|b.sc.|2024",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-BSc/20240827_Modulkatalog_Bachelor_Chemie.pdf"
      }
     ]
    },
    {
     "id": "computational-methods-in-engineering-m-sc",
     "program": "Computational Methods in Engineering",
     "degree": "M.Sc.",
     "qis_names": [
      "Computational Methods in Engineering",
      "Computational Methods in Engineering (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_comping_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2025",
       "code": "computational-methods-in-engineering|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|computational-methods-in-engineering|m.sc.|2025",
       "format": "fbg-modulhandbuch",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Studium/Bauingenieurwesen/Modulhandbuecher/PO_25/Modulhandbuch_PO25_CME.pdf"
      }
     ]
    },
    {
     "id": "deutsche-und-englische-linguistik-m-a",
     "program": "Deutsche und Englische Linguistik",
     "degree": "M.A.",
     "qis_names": [
      "Deutsche und Englische Linguistik",
      "Deutsche und Englische Linguistik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_dlitwiss_mpo2026.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "digital-business-b-sc",
     "program": "Digital Business",
     "degree": "B.Sc.",
     "qis_names": [
      "Digital Business",
      "Digital Business (PO 2026)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_digbuis_bpo26.pdf",
     "faculty": "Wirtschaftswissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2026",
       "code": "digital-business|b.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|digital-business|b.sc.|2026",
       "format": "wiwi-modulhandbuch",
       "url": "https://www.wiwi.uni-hannover.de/fileadmin/wiwi/pdf/modulhandbuch/semesterunabhaengig/Modulhandbuch_Bachelor_Digital_Business.pdf"
      },
      {
       "po": "2026",
       "code": "DiBu",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|digital-business|b.sc.|2026",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-DiBu-WS_2026_27.pdf",
       "label": "Informatik-Anteil (FEI)"
      }
     ]
    },
    {
     "id": "elektrotechnik-und-informationstechnik-m-sc",
     "program": "Elektrotechnik und Informationstechnik",
     "degree": "M.Sc.",
     "qis_names": [
      "Elektrotechnik und Informationstechnik",
      "Elektrotechnik und Informationstechnik (PO 2017)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_etec_inf_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "ETMSc17",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|elektrotechnik-und-informationstechnik-1|m.sc.|2017",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-ETMSc17-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "elektrotechnik-und-informationstechnik-b-sc",
     "program": "Elektrotechnik und Informationstechnik",
     "degree": "B.Sc.",
     "qis_names": [
      "Elektrotechnik und Informationstechnik",
      "Elektrotechnik und Informationstechnik (PO 2017)",
      "Elektrotechnik und Informationstechnik (PO 2025)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_etec_inf_bpo26_2.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "ETBSc17",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|elektrotechnik-und-informationstechnik|b.sc.|2017",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-ETBSc17-WS_2026_27.pdf"
      },
      {
       "po": "2025",
       "code": "ETBSc25",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|elektrotechnik-und-informationstechnik|b.sc.|2025",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-ETBSc25-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "energietechnik-m-sc",
     "program": "Energietechnik",
     "degree": "M.Sc.",
     "qis_names": [
      "Energietechnik",
      "Energietechnik (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_energietech_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2020",
       "code": "EntMsc24",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|energietechnik-1|m.sc.|2020",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-EntMsc24-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "energietechnik-b-sc",
     "program": "Energietechnik",
     "degree": "B.Sc.",
     "qis_names": [
      "Energietechnik",
      "Energietechnik (PO 2020)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_energietech_bpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2020",
       "code": "EntBsc24",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|energietechnik|b.sc.|2020",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-EntBsc24-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "energy-technology-m-sc",
     "program": "Energy Technology",
     "degree": "M.Sc.",
     "qis_names": [
      "Energy Technology"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": null,
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": []
    },
    {
     "id": "erwachsenenbildung-weiterbildung-zertifikat",
     "program": "Erwachsenenbildung/Weiterbildung",
     "degree": "Zertifikat",
     "qis_names": [
      "Erwachsenenbildung/Weiterbildung",
      "Erwachsenenbildung/Weiterbildung (PO 2020)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_Erwachsenenbild_zpo20.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "european-legal-practice-ll-m-joint-degree-ll-m",
     "program": "European Legal Practice LL.M Joint Degree",
     "degree": "LL.M.",
     "qis_names": [
      "European Legal Practice LL.M Joint Degree",
      "European Legal Practice LL.M Joint Degree (PO 2018)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_eurorecht_llmpo26.pdf",
     "faculty": "Juristische Fakultät",
     "pos": []
    },
    {
     "id": "european-master-in-territorial-development-m-sc",
     "program": "European Master in Territorial Development",
     "degree": "M.Sc.",
     "qis_names": [
      "European in Territorial Development",
      "European in Territorial Development (PO 2015)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/content/pruefungsamt/formulare/EuropMATerritoDevelop/po/f_territdev_mpo22.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": []
    },
    {
     "id": "faecheruebergreifender-bachelor-b-a-b-sc",
     "program": "Fächerübergreifender Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "food-research-and-development-lebensmittelwissenschaft-m-sc",
     "program": "Food Research and Development / Lebensmittelwissenschaft",
     "degree": "M.Sc.",
     "qis_names": [
      "Food Research and Development / Lebensmittelwissenschaft",
      "Food Research and Development / Lebensmittelwissenschaft (PO 2018)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_foodres_mpo24.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": []
    },
    {
     "id": "gartenbauwissenschaften-b-sc",
     "program": "Gartenbauwissenschaften",
     "degree": "B.Sc.",
     "qis_names": [
      "Gartenbauwissenschaften",
      "Gartenbauwissenschaften (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/760_bpo2018.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": []
    },
    {
     "id": "gartenbauwissenschaften-m-sc",
     "program": "Gartenbauwissenschaften",
     "degree": "M.Sc.",
     "qis_names": [
      "Gartenbauwissenschaften",
      "Gartenbauwissenschaften (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_gartenwiss_mpo2018.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": []
    },
    {
     "id": "geodaesie-und-geoinformatik-b-sc",
     "program": "Geodäsie und Geoinformatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Geodäsie und Geoinformatik",
      "Geodäsie und Geoinformatik (PO 2025)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_geod_bpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2025",
       "code": "geodaesie-und-geoinformatik|b.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geodaesie-und-geoinformatik|b.sc.|2025",
       "format": "luh-modulbeschreibung",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Geodaesie/Dokumente/Bachelor_GuG/20260305_Modulkatalog_GuG_Bachelor_PO25.pdf"
      }
     ]
    },
    {
     "id": "geographie-b-a-b-sc",
     "program": "Geographie",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Geographie",
      "Geographie (PO 2015)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/content/pruefungsamt/formulare/geographie/po/f_geo_bpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2015",
       "code": "geographie|b.a.-b.sc.|2015",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geographie|b.a.-b.sc.|2015",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geographie/Studiengangsuebergreifende_Dokumente/Modulkatalog_Bachelor_Geographie.pdf"
      }
     ]
    },
    {
     "id": "geowissenschaften-m-sc",
     "program": "Geowissenschaften",
     "degree": "M.Sc.",
     "qis_names": [
      "Geowissenschaften",
      "Geowissenschaften (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/content/pruefungsamt/formulare/geowiss/po/f_geowiss_mpo2026.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2020",
       "code": "geowissenschaften-1|m.sc.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geowissenschaften-1|m.sc.|2020",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geowissenschaften/Detail-Geowissenschaften-MSc/Modulkatalog_Master_Geowissenschaften2025.pdf"
      }
     ]
    },
    {
     "id": "geowissenschaften-b-sc",
     "program": "Geowissenschaften",
     "degree": "B.Sc.",
     "qis_names": [
      "Geowissenschaften",
      "Geowissenschaften (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/content/pruefungsamt/formulare/geowiss/po/f_geowiss_bpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "geowissenschaften|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geowissenschaften|b.sc.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geowissenschaften/Detail-Geowissenschaften-BSc/Modulkatalog_Bachelor_Geowissenschaften2025.pdf"
      }
     ]
    },
    {
     "id": "geschichte-m-a",
     "program": "Geschichte",
     "degree": "M.A.",
     "qis_names": [
      "Geschichte",
      "Geschichte (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_geschichte_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2020",
       "code": "geschichte-ma|m.a.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|geschichte-ma|m.a.|2020",
       "format": "luh-modulbeschreibung",
       "url": "https://www.hist.uni-hannover.de/fileadmin/hist/News_und_Veranstaltungen/PDF/Modulkataloge_MA_Geschichte_WS_26_27.pdf"
      }
     ]
    },
    {
     "id": "hochschule-wissenschaft-gesellschaft-m-a",
     "program": "Hochschule, Wissenschaft, Gesellschaft",
     "degree": "M.A.",
     "qis_names": [
      "Hochschule, Wissenschaft, Gesellschaft",
      "Hochschule, Wissenschaft, Gesellschaft (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_hochschwissges_mpo2026.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "hochschule-wissenschaft-gesellschaft|m.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|hochschule-wissenschaft-gesellschaft|m.a.|2016",
       "format": "scanned",
       "url": "https://www.ish.uni-hannover.de/fileadmin/ish/ma_wug/Dokumente/Modulhandbuch/Modulhandbuch_MA_Hochschule__Wissenschaft__Gesellschaft_Stand_10_09_2025.pdf"
      }
     ]
    },
    {
     "id": "informatik-m-sc",
     "program": "Informatik",
     "degree": "M.Sc.",
     "qis_names": [
      "Informatik",
      "Informatik (PO 2017)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_inform_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "INFMSc25",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-1|m.sc.|2017",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-INFMSc25-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "informationstechnologierecht-und-recht-des-geistigen-eigentums-ll-b-ll-b",
     "program": "Informationstechnologierecht und Recht des geistigen Eigentums (LL.B)",
     "degree": "LL.B.",
     "qis_names": [
      "Informationstechnologierecht und Recht des geistigen Eigentums (LL.B)",
      "Informationstechnologierecht und Recht des geistigen Eigentums (LL.B) (PO 2018)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_itrecht_bpo22.pdf",
     "faculty": "Juristische Fakultät",
     "pos": []
    },
    {
     "id": "informationstechnologierecht-und-recht-des-geistigen-eigentums-ll-m-ll-m",
     "program": "Informationstechnologierecht und Recht des geistigen Eigentums (LL.M)",
     "degree": "LL.M.",
     "qis_names": [
      "Informationstechnologierecht und Recht des geistigen Eigentums (LL.M)",
      "Informationstechnologierecht und Recht des geistigen Eigentums (LL.M) (PO 2017)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_itrecht_mpo22.pdf",
     "faculty": "Juristische Fakultät",
     "pos": []
    },
    {
     "id": "international-horticulture-m-sc",
     "program": "International Horticulture",
     "degree": "M.Sc.",
     "qis_names": [
      "International Horticulture",
      "International Horticulture (PO 2018)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_horti_mpo22.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": []
    },
    {
     "id": "international-mechatronics-m-sc",
     "program": "International Mechatronics",
     "degree": "M.Sc.",
     "qis_names": [
      "International Mechatronics"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": null,
     "faculty": "Fakultät für Maschinenbau",
     "pos": []
    },
    {
     "id": "kautschuktechnologie-zertifikat",
     "program": "Kautschuktechnologie",
     "degree": "Zertifikat",
     "qis_names": [
      "Kautschuktechnologie",
      "Kautschuktechnologie (PO 2016)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_kautschuk_po.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": []
    },
    {
     "id": "konstruktiver-ingenieurbau-fernstudium-m-sc",
     "program": "Konstruktiver Ingenieurbau (Fernstudium)",
     "degree": "M.Sc.",
     "qis_names": [
      "Konstruktiver Ingenieurbau (Fernstudium)",
      "Konstruktiver Ingenieurbau (Fernstudium) (PO 2019)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_bauing_po_m_2019.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2019",
       "code": "konstruktiver-ingenieurbau-fernstudium|m.sc.|2019",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|konstruktiver-ingenieurbau-fernstudium|m.sc.|2019",
       "format": "fbg-modulhandbuch",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Studium/Bauingenieurwesen/Modulhandbuecher/PO_25/Modulhandbuch_PO25_BAU.pdf",
       "label": "Modulhandbuch Bauingenieurwesen (M.Sc.)"
      }
     ]
    },
    {
     "id": "landschaftsarchitektur-und-umweltplanung-b-sc",
     "program": "Landschaftsarchitektur und Umweltplanung",
     "degree": "B.Sc.",
     "qis_names": [
      "Landschaftsarchitektur und Umweltplanung",
      "Landschaftsarchitektur und Umweltplanung (PO 2024)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_laum_bpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": [
      {
       "po": "2024",
       "code": "landschaftsarchitektur-und-umweltplanung|b.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|landschaftsarchitektur-und-umweltplanung|b.sc.|2024",
       "format": "luh-modulbeschreibung",
       "url": "https://www.archland.uni-hannover.de/fileadmin/archland/STUDIUM/LAUM/Modulbeschreibungen/Bachelor_LaUp_Modulkatalog_Pflicht_20231205.pdf",
       "label": "Pflichtmodule"
      }
     ]
    },
    {
     "id": "landschaftsarchitektur-m-sc",
     "program": "Landschaftsarchitektur",
     "degree": "M.Sc.",
     "qis_names": [
      "Landschaftsarchitektur",
      "Landschaftsarchitektur (PO 2015)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_landschaft_mpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": [
      {
       "po": "2015",
       "code": "landschaftsarchitektur|m.sc.|2015",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|landschaftsarchitektur|m.sc.|2015",
       "format": "luh-modulbeschreibung",
       "url": "https://www.archland.uni-hannover.de/fileadmin/archland/STUDIUM/LAUM/Modulbeschreibungen/Modulkatalog_MA_LA_Pflicht_2026.pdf",
       "label": "Pflichtmodule"
      }
     ]
    },
    {
     "id": "landschaftswissenschaften-m-sc",
     "program": "Landschaftswissenschaften",
     "degree": "M.Sc.",
     "qis_names": [
      "Landschaftswissenschaften",
      "Landschaftswissenschaften (PO 2019)",
      "Landschaftswissenschaften (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_landwiss_mpo22_3.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2019",
       "code": "landschaftswissenschaften|m.sc.|2019",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|landschaftswissenschaften|m.sc.|2019",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geographie/Detail-Landschaftswissens-MSc/ModulkatalogLawi_PO19_2026.pdf"
      },
      {
       "po": "2026",
       "code": "landschaftswissenschaften|m.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|landschaftswissenschaften|m.sc.|2026",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geographie/Detail-Landschaftswissens-MSc/ModulkatalogLawi_PO2026.pdf"
      }
     ]
    },
    {
     "id": "lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "lehramt-an-berufsbildenden-schulen-zweites-fach-zertifikat",
     "program": "Lehramt an berufsbildenden Schulen, zweites Fach",
     "degree": "Zertifikat",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen, zweites Fach",
      "Lehramt an berufsbildenden Schulen, zweites Fach (PO 2016)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f-lehrbs_2fpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "lehramt-an-gymnasien-drittes-fach-zertifikat",
     "program": "Lehramt an Gymnasien, drittes Fach",
     "degree": "Zertifikat",
     "qis_names": [
      "Lehramt an Gymnasien, drittes Fach",
      "Lehramt an Gymnasien, drittes Fach (PO 2016)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_3fpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "lehramt-an-gymnasien-m-ed",
     "program": "Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "lehramt-fuer-sonderpaedagogik-zweites-fach-zertifikat",
     "program": "Lehramt für Sonderpädagogik, zweites Fach",
     "degree": "Zertifikat",
     "qis_names": [
      "Lehramt für Sonderpädagogik, zweites Fach",
      "Lehramt für Sonderpädagogik, zweites Fach (PO 2016)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_2fpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "life-science-m-sc",
     "program": "Life Science",
     "degree": "M.Sc.",
     "qis_names": [
      "Life Science",
      "Life Science (PO 2022)",
      "Life Science (PO 2024)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lifesc_mpo22_1.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2022",
       "code": "life-science-1-1|m.sc.|2022",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|life-science-1-1|m.sc.|2022",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/LifeScience/Detail-LifeScience-MSc/Dokumente/2023_Modulhandbuch_Master_LS-PO-2022.pdf"
      },
      {
       "po": "2024",
       "code": "life-science-1-1|m.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|life-science-1-1|m.sc.|2024",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/LifeScience/Detail-LifeScience-MSc/Dokumente/2025_07_16_Modulkatalog_MSc_LS__final.pdf"
      }
     ]
    },
    {
     "id": "life-science-b-sc",
     "program": "Life Science",
     "degree": "B.Sc.",
     "qis_names": [
      "Life Science",
      "Life Science (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lifesc_bpo2026.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "life-science|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|life-science|b.sc.|2016",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/LifeScience/Detail-LifeScience-BSc/Dokumente/Modulkatalog_Bachelor_Life_Science_Pflicht.pdf",
       "label": "Pflichtmodule"
      }
     ]
    },
    {
     "id": "maschinenbau-m-sc",
     "program": "Maschinenbau",
     "degree": "M.Sc.",
     "qis_names": [
      "Maschinenbau",
      "Maschinenbau (PO 2017)",
      "Maschinenbau (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_maschbau_mpo26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2017",
       "code": "maschinenbau-1|m.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|maschinenbau-1|m.sc.|2017",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_MB_MSc_PO_17.pdf"
      },
      {
       "po": "2026",
       "code": "maschinenbau-1|m.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|maschinenbau-1|m.sc.|2026",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_MB_MSc_PO_26.pdf"
      }
     ]
    },
    {
     "id": "maschinenbau-b-sc",
     "program": "Maschinenbau",
     "degree": "B.Sc.",
     "qis_names": [
      "Maschinenbau",
      "Maschinenbau (PO 2017)",
      "Maschinenbau (PO 2026)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_maschbau_bpo26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2017",
       "code": "maschinenbau|b.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|maschinenbau|b.sc.|2017",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_MB_BSC_PO_17.pdf"
      },
      {
       "po": "2026",
       "code": "maschinenbau|b.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|maschinenbau|b.sc.|2026",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_MB_BSC_PO_26.pdf"
      }
     ]
    },
    {
     "id": "mathematik-m-sc",
     "program": "Mathematik",
     "degree": "M.Sc.",
     "qis_names": [
      "Mathematik",
      "Mathematik (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_mathe_mpo2026.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2020",
       "code": "mathematik-1|m.sc.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik-1|m.sc.|2020",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_fach_mathe_2026.pdf"
      }
     ]
    },
    {
     "id": "mathematik-b-sc",
     "program": "Mathematik",
     "degree": "B.Sc.",
     "qis_names": [
      "Mathematik",
      "Mathematik (PO 2020)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_mathe_bpo2026.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2020",
       "code": "mathematik|b.sc.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik|b.sc.|2020",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_fach_mathe_2026.pdf"
      }
     ]
    },
    {
     "id": "mechatronik-und-robotik-m-sc",
     "program": "Mechatronik und Robotik",
     "degree": "M.Sc.",
     "qis_names": [
      "Mechatronik und Robotik",
      "Mechatronik und Robotik (PO 2017)",
      "Mechatronik und Robotik (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": null,
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2017",
       "code": "mechatronik-und-robotik|m.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|mechatronik-und-robotik|m.sc.|2017",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modukatalog_Mech_MSc_PO_17.pdf"
      },
      {
       "po": "2025",
       "code": "mechatronik-und-robotik|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|mechatronik-und-robotik|m.sc.|2025",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_Mech_MSc_PO_25.pdf"
      }
     ]
    },
    {
     "id": "mechatronik-b-sc",
     "program": "Mechatronik",
     "degree": "B.Sc.",
     "qis_names": [
      "Mechatronik",
      "Mechatronik (PO 2017)",
      "Mechatronik (PO 2025)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_mechatr_bpo26_2017.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "MechBSc17",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|mechatronik|b.sc.|2017",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-MechBSc17-WS_2026_27.pdf"
      },
      {
       "po": "2025",
       "code": "MechBSc25",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|mechatronik|b.sc.|2025",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-MechBSc25-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "medizintechnik-b-sc",
     "program": "Medizintechnik",
     "degree": "B.Sc.",
     "qis_names": [
      "Medizintechnik",
      "Medizintechnik (PO 2026)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": null,
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2026",
       "code": "medizintechnik|b.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|medizintechnik|b.sc.|2026",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_MT_BSC_PO_26.pdf"
      }
     ]
    },
    {
     "id": "meteorologie-m-sc",
     "program": "Meteorologie",
     "degree": "M.Sc.",
     "qis_names": [
      "Meteorologie",
      "Meteorologie (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_meteo_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": []
    },
    {
     "id": "meteorologie-b-sc",
     "program": "Meteorologie",
     "degree": "B.Sc.",
     "qis_names": [
      "Meteorologie",
      "Meteorologie (PO 2020)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_meteo_bpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": []
    },
    {
     "id": "molekulare-mikrobiologie-m-sc",
     "program": "Molekulare Mikrobiologie",
     "degree": "M.Sc.",
     "qis_names": [
      "Molekulare Mikrobiologie",
      "Molekulare Mikrobiologie (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_mikrobio_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "molekulare-mikrobiologie|m.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|molekulare-mikrobiologie|m.sc.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Biologie/Detail-MolekulareMikrobiologie-MSc/PDF/Modulkatalog_Molekulare_Mikrobiologie_26-27.pdf"
      }
     ]
    },
    {
     "id": "molekulare-und-angewandte-pflanzenwissenschaften-b-sc",
     "program": "Molekulare und Angewandte Pflanzenwissenschaften",
     "degree": "B.Sc.",
     "qis_names": [
      "Molekulare und Angewandte Pflanzenwissenschaften",
      "Molekulare und Angewandte Pflanzenwissenschaften (PO 2018)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_moleangepflanz_bpo22_2.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": []
    },
    {
     "id": "nachhaltige-gesundheitsfoerderung-durch-sport-m-sc",
     "program": "Nachhaltige Gesundheitsförderung durch Sport",
     "degree": "M.Sc.",
     "qis_names": [
      "Nachhaltige Gesundheitsförderung durch Sport",
      "Nachhaltige Gesundheitsförderung durch Sport (PO 2019)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_nachgesund_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2019",
       "code": "nachhaltige-gesundheitsfoerderung-durch-sport|m.sc.|2019",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|nachhaltige-gesundheitsfoerderung-durch-sport|m.sc.|2019",
       "format": "luh-modulbeschreibung",
       "url": "https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Master_Nachhaltige_Gesundheitsfoerderung_durch_Sport_WiSe26.27.pdf"
      }
     ]
    },
    {
     "id": "nachhaltige-ingenieurwissenschaft-m-sc",
     "program": "Nachhaltige Ingenieurwissenschaft",
     "degree": "M.Sc.",
     "qis_names": [
      "Nachhaltige Ingenieurwissenschaft",
      "Nachhaltige Ingenieurwissenschaft (PO 2024)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_nachhaltIngW_mpo26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2024",
       "code": "nachhaltige-ingenieurwissenschaft-1|m.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|nachhaltige-ingenieurwissenschaft-1|m.sc.|2024",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_NIng_MSc_PO_24.pdf"
      }
     ]
    },
    {
     "id": "nachhaltige-ingenieurwissenschaft-b-sc",
     "program": "Nachhaltige Ingenieurwissenschaft",
     "degree": "B.Sc.",
     "qis_names": [
      "Nachhaltige Ingenieurwissenschaft",
      "Nachhaltige Ingenieurwissenschaft (PO 2021)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_nachhaltIngW_bpo26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2021",
       "code": "nachhaltige-ingenieurwissenschaft|b.sc.|2021",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|nachhaltige-ingenieurwissenschaft|b.sc.|2021",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_NIng_BSC_PO_21.pdf"
      }
     ]
    },
    {
     "id": "nanotechnologie-m-sc",
     "program": "Nanotechnologie",
     "degree": "M.Sc.",
     "qis_names": [
      "Nanotechnologie",
      "Nanotechnologie (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_nano_mpo26.pdf",
     "faculty": "fakultätsübergreifend (Laboratorium für Nano- und Quantenengineering, LNQE)",
     "pos": [
      {
       "po": "2016",
       "code": "nanotechnologie-1|m.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|nanotechnologie-1|m.sc.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.lnqe.uni-hannover.de/fileadmin/lnqe/downloads/Studiengang_Allgemein/Modulkatalog_Nanotechnologie.pdf",
       "label": "Kurs- und Modulkatalog Nanotechnologie"
      }
     ]
    },
    {
     "id": "nanotechnologie-b-sc",
     "program": "Nanotechnologie",
     "degree": "B.Sc.",
     "qis_names": [
      "Nanotechnologie",
      "Nanotechnologie (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_nano_bpo26.pdf",
     "faculty": "fakultätsübergreifend (Laboratorium für Nano- und Quantenengineering, LNQE)",
     "pos": [
      {
       "po": "2016",
       "code": "nanotechnologie|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|nanotechnologie|b.sc.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.lnqe.uni-hannover.de/fileadmin/lnqe/downloads/Studiengang_Allgemein/Modulkatalog_Nanotechnologie.pdf",
       "label": "Kurs- und Modulkatalog Nanotechnologie"
      }
     ]
    },
    {
     "id": "neuere-deutsche-literaturwissenschaft-m-a",
     "program": "Neuere Deutsche Literaturwissenschaft",
     "degree": "M.A.",
     "qis_names": [
      "Neuere Deutsche Literaturwissenschaft",
      "Neuere Deutsche Literaturwissenschaft (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_NDL_mpo2026.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "north-american-studies-m-a",
     "program": "North American Studies",
     "degree": "M.A.",
     "qis_names": [
      "North American Studies",
      "North American Studies (PO 2022)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_north_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "optische-technologien-laser-und-photonik-b-sc",
     "program": "Optische Technologien: Laser und Photonik",
     "degree": "B.Sc.",
     "qis_names": [
      "Optische Technologien: Laser und Photonik",
      "Optische Technologien: Laser und Photonik (PO 2022)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_optech_bpo22_24.1_.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2022",
       "code": "optische-technologien-laser-und-photonik-bsc|b.sc.|2022",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|optische-technologien-laser-und-photonik-bsc|b.sc.|2022",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_OT_BSC_PO_22.pdf"
      }
     ]
    },
    {
     "id": "optische-technologien-m-sc",
     "program": "Optische Technologien",
     "degree": "M.Sc.",
     "qis_names": [
      "Optische Technologien",
      "Optische Technologien (PO 2017)",
      "Optische Technologien (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_optech_mpo_2015_26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2017",
       "code": "optische-technologien|m.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|optische-technologien|m.sc.|2017",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_OT_MSC_PO_17_Deu.pdf"
      },
      {
       "po": "2026",
       "code": "optische-technologien|m.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|optische-technologien|m.sc.|2026",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_OT_MSc_PO_26_Deu.pdf"
      }
     ]
    },
    {
     "id": "pflanzenbiotechnologie-b-sc",
     "program": "Pflanzenbiotechnologie",
     "degree": "B.Sc.",
     "qis_names": [
      "Pflanzenbiotechnologie",
      "Pflanzenbiotechnologie (PO 2022)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_pflanzenbio_bpo2026.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2022",
       "code": "pflanzenbiotechnologie-2|b.sc.|2022",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|pflanzenbiotechnologie-2|b.sc.|2022",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Pflanzenwissenschaften/Detail-Pflanzenbiotechnologie-BSc-PO2022/Modulkatalog_BSc_Pflanzenbiotechnologie_26-27.pdf"
      }
     ]
    },
    {
     "id": "pflanzenbiotechnologie-m-sc",
     "program": "Pflanzenbiotechnologie",
     "degree": "M.Sc.",
     "qis_names": [
      "Pflanzenbiotechnologie",
      "Pflanzenbiotechnologie (PO 2022)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_pflanzenbio_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2022",
       "code": "pflanzenbiotechnologie|m.sc.|2022",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|pflanzenbiotechnologie|m.sc.|2022",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Pflanzenwissenschaften/Detail-Pflanzenbiotechnologie-MSc/Modulkatalog_MSc_PBT_26-27.pdf"
      }
     ]
    },
    {
     "id": "philosophy-of-science-m-a",
     "program": "Philosophy of Science",
     "degree": "M.A.",
     "qis_names": [
      "Philosophy of Science",
      "Philosophy of Science (PO 2018)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_philSci_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2018",
       "code": "philosophy-of-science|m.a.|2018",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|philosophy-of-science|m.a.|2018",
       "format": "luh-modulbeschreibung",
       "url": "https://www.philos.uni-hannover.de/fileadmin/philos/Dateien/Modulkataloge/Modulkatalog_Philosophy_of_Science_WiSe2022.23.pdf"
      }
     ]
    },
    {
     "id": "physik-m-sc",
     "program": "Physik",
     "degree": "M.Sc.",
     "qis_names": [
      "Physik",
      "Physik (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_phy_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2020",
       "code": "physik-1|m.sc.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|physik-1|m.sc.|2020",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_fach_physik_2026.pdf"
      }
     ]
    },
    {
     "id": "physik-b-sc",
     "program": "Physik",
     "degree": "B.Sc.",
     "qis_names": [
      "Physik",
      "Physik (PO 2020)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_phy_bpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2020",
       "code": "physik|b.sc.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|physik|b.sc.|2020",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_fach_physik_2026.pdf"
      }
     ]
    },
    {
     "id": "politikwissenschaft-m-a",
     "program": "Politikwissenschaft",
     "degree": "M.A.",
     "qis_names": [
      "Politikwissenschaft",
      "Politikwissenschaft (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_polwiss_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "politikwissenschaft-1|m.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|politikwissenschaft-1|m.a.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.ipw.uni-hannover.de/fileadmin/ipw/Institut_Dateien/Modulkataloge_WiSe_2026-27/MA_Polwiss_Modulkatalog_Stand_10_26.pdf"
      }
     ]
    },
    {
     "id": "politikwissenschaft-b-a",
     "program": "Politikwissenschaft",
     "degree": "B.A.",
     "qis_names": [
      "Politikwissenschaft",
      "Politikwissenschaft (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_polwiss_bpo2026.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "politikwissenschaft|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|politikwissenschaft|b.a.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.ipw.uni-hannover.de/fileadmin/ipw/Institut_Dateien/Modulkataloge_WiSe_2026-27/BA_Polwiss_Modulkatalog_Stand_10_26.pdf"
      }
     ]
    },
    {
     "id": "produktion-und-logistik-b-sc",
     "program": "Produktion und Logistik",
     "degree": "B.Sc.",
     "qis_names": [
      "Produktion und Logistik",
      "Produktion und Logistik (PO 2017)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_prodlog_bpo26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2017",
       "code": "produktion-und-logistik-bsc|b.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|produktion-und-logistik-bsc|b.sc.|2017",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_PL_BSC_PO_17.pdf"
      }
     ]
    },
    {
     "id": "produktion-und-logistik-m-sc",
     "program": "Produktion und Logistik",
     "degree": "M.Sc.",
     "qis_names": [
      "Produktion und Logistik",
      "Produktion und Logistik (PO 2017)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_prodlog_mpo17.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2017",
       "code": "produktion-und-logistik-msc|m.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|produktion-und-logistik-msc|m.sc.|2017",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_PL_MSc_PO_17.pdf"
      }
     ]
    },
    {
     "id": "quantum-engineering-m-sc",
     "program": "Quantum Engineering",
     "degree": "M.Sc.",
     "qis_names": [
      "Quantum Engineering",
      "Quantum Engineering (PO 2022)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_quantum_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2022",
       "code": "quantum-engineering|m.sc.|2022",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|quantum-engineering|m.sc.|2022",
       "format": "luh-modulbeschreibung",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/Modulkatalog_QE_03112026.pdf"
      }
     ]
    },
    {
     "id": "rechtswissenschaften-staatsexamen-ll-b",
     "program": "Rechtswissenschaften",
     "degree": "Staatsexamen/LL.B.",
     "qis_names": [
      "Rechtswissenschaften",
      "Rechtswissenschaften (PO 2026)"
     ],
     "regular_semesters": 10,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/content/pruefungsamt/formulare/Rechtswiss/f_BRecht2026pdf.pdf",
     "faculty": "Juristische Fakultät",
     "pos": []
    },
    {
     "id": "religion-in-the-public-sphere-m-a",
     "program": "Religion in the Public Sphere",
     "degree": "M.A.",
     "qis_names": [
      "Religion in the Public Sphere",
      "Religion in the Public Sphere (PO 2021)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_relips_mpo2026.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2021",
       "code": "religion-in-the-public-sphere-1|m.a.|2021",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|religion-in-the-public-sphere-1|m.a.|2021",
       "format": "scanned",
       "url": "https://www.irw.uni-hannover.de/fileadmin/rewi/Relpub/2026_08_28_RELPUB_module_catalogue.pdf"
      }
     ]
    },
    {
     "id": "sonderpaedagogik-und-rehabilitationswissenschaften-m-a",
     "program": "Sonderpädagogik und Rehabilitationswissenschaften",
     "degree": "M.A.",
     "qis_names": [
      "Sonderpädagogik und Rehabilitationswissenschaften",
      "Sonderpädagogik und Rehabilitationswissenschaften (PO 2019)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderreha_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2019",
       "code": "sonderpaedagogik-und-rehabilitationswissenschaften|m.a.|2019",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|sonderpaedagogik-und-rehabilitationswissenschaften|m.a.|2019",
       "format": "phil-kv-tabelle",
       "url": "https://www.ifs.uni-hannover.de/fileadmin/ifs/Studium/Studiengaenge/Studium_M.A._Sonderpaedagogik_und_Rehabilitationswissenschaften/Modulkataloge_M.A._10_2026.pdf"
      }
     ]
    },
    {
     "id": "sonderpaedagogik-b-a",
     "program": "Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "sonderpaedagogik|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|sonderpaedagogik|b.a.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.ifs.uni-hannover.de/fileadmin/ifs/Studium/Studiengaenge/Studium_B.A._Sonderpaedagogik/BA_Modulkataloge_10_2026.pdf"
      }
     ]
    },
    {
     "id": "sozialwissenschaften-b-a",
     "program": "Sozialwissenschaften",
     "degree": "B.A.",
     "qis_names": [
      "Sozialwissenschaften",
      "Sozialwissenschaften (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sozialwiss_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "sozialwissenschaften|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|sozialwissenschaften|b.a.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.ish.uni-hannover.de/fileadmin/ish/institut/dokumente/Modulkatalog_Sowi_November_2025.pdf"
      }
     ]
    },
    {
     "id": "soziologie-m-a",
     "program": "Soziologie",
     "degree": "M.A.",
     "qis_names": [
      "Soziologie",
      "Soziologie (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_soziologie_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "soziologie|m.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|soziologie|m.a.|2016",
       "format": "scanned",
       "url": "https://www.ish.uni-hannover.de/fileadmin/ish/institut/dokumente/Modulkatalog_MA_Soziologie_April_2025_.pdf"
      }
     ]
    },
    {
     "id": "technical-education-b-sc",
     "program": "Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "technische-informatik-m-sc",
     "program": "Technische Informatik",
     "degree": "M.Sc.",
     "qis_names": [
      "Technische Informatik",
      "Technische Informatik (PO 2017)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_techinf_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "TIMSc25",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|technische-informatik-1|m.sc.|2017",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-TIMSc25-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "umweltingenieurwesen-m-sc",
     "program": "Umweltingenieurwesen",
     "degree": "M.Sc.",
     "qis_names": [
      "Umweltingenieurwesen",
      "Umweltingenieurwesen (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_umwelting_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2025",
       "code": "umweltingenieurwesen|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|umweltingenieurwesen|m.sc.|2025",
       "format": "fbg-modulhandbuch",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Studium/Bauingenieurwesen/Modulhandbuecher/PO_25/Modulhandbuch_PO25_UIW.pdf"
      }
     ]
    },
    {
     "id": "umweltmeteorologie-b-sc",
     "program": "Umweltmeteorologie",
     "degree": "B.Sc.",
     "qis_names": [
      "Umweltmeteorologie",
      "Umweltmeteorologie (PO 2022)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_umweltmeteo_bpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2022",
       "code": "umweltmeteorologie|b.sc.|2022",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|umweltmeteorologie|b.sc.|2022",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_fach_umweltmeteorlogie_2026.pdf"
      }
     ]
    },
    {
     "id": "wasser-und-umwelt-fernstudium-m-sc",
     "program": "Wasser und Umwelt (Fernstudium)",
     "degree": "M.Sc.",
     "qis_names": [
      "Wasser und Umwelt (Fernstudium)",
      "Wasser und Umwelt (Fernstudium) (PO 2015)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_wasser-mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": []
    },
    {
     "id": "water-resources-and-environmental-engineering-m-sc",
     "program": "Water Resources and Environmental Engineering",
     "degree": "M.Sc.",
     "qis_names": [
      "Water Resources and Environmental Engineering",
      "Water Resources and Environmental Engineering (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_water_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": []
    },
    {
     "id": "wirtschaftsgeographie-innovation-und-nachhaltigkeit-m-sc",
     "program": "Wirtschaftsgeographie, Innovation und Nachhaltigkeit",
     "degree": "M.Sc.",
     "qis_names": [
      "Wirtschaftsgeographie, Innovation und Nachhaltigkeit",
      "Wirtschaftsgeographie, Innovation und Nachhaltigkeit (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_wirtgeoInno_mpo25.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2025",
       "code": "wirtschaftsgeographie-innovation-und-nachhaltigkeit|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|wirtschaftsgeographie-innovation-und-nachhaltigkeit|m.sc.|2025",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geographie/Detail-Wirtschaftsgeographie-MSc/Modulkatalog_MSc_WIN.pdf"
      }
     ]
    },
    {
     "id": "wirtschaftsgeographie-m-a",
     "program": "Wirtschaftsgeographie",
     "degree": "M.A.",
     "qis_names": [
      "Wirtschaftsgeographie",
      "Wirtschaftsgeographie (PO 2022)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_wirtgeo_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2022",
       "code": "wirtschaftsgeographie-ma|m.a.|2022",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|wirtschaftsgeographie-ma|m.a.|2022",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geographie/Detail-Wirtschaftsgeographie-MA/Modulkatalog_MA_WiGeo_Feb_2025.pdf"
      }
     ]
    },
    {
     "id": "wirtschaftsingenieurwesen-m-sc",
     "program": "Wirtschaftsingenieurwesen",
     "degree": "M.Sc.",
     "qis_names": [
      "Wirtschaftsingenieurwesen",
      "Wirtschaftsingenieurwesen (PO 2018)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_wi_ing_mpo26.pdf",
     "faculty": "Wirtschaftswissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2018",
       "code": "wirtschaftsingenieurwesen-1|m.sc.|2018",
       "source": "luh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "luh|wirtschaftsingenieurwesen-1|m.sc.|2018",
       "format": "wiwi-modulhandbuch",
       "url": "https://www.wiwi.uni-hannover.de/fileadmin/wiwi/pdf/modulhandbuch/sose2026/Modulhandbuch_Master_Wirtschaftsingenieurwesen_Sommersemester_2026.pdf"
      }
     ]
    },
    {
     "id": "wirtschaftsingenieurwesen-b-sc",
     "program": "Wirtschaftsingenieurwesen",
     "degree": "B.Sc.",
     "qis_names": [
      "Wirtschaftsingenieurwesen",
      "Wirtschaftsingenieurwesen (PO 2022)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_wi_ing_bpo22_26_.pdf",
     "faculty": "Wirtschaftswissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2022",
       "code": "wirtschaftsingenieurwesen|b.sc.|2022",
       "source": "luh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "luh|wirtschaftsingenieurwesen|b.sc.|2022",
       "format": "wiwi-modulhandbuch",
       "url": "https://www.wiwi.uni-hannover.de/fileadmin/wiwi/pdf/modulhandbuch/sose2026/Modulhandbuch_Bachelor_Wirtschaftsingenieurwesen_Sommersemester_2026.pdf"
      },
      {
       "po": "2022",
       "code": "WiIngBSc22",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|wirtschaftsingenieurwesen|b.sc.|2022",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-WiIngBSc22-WS_2026_27.pdf",
       "label": "technischer Teil (FEI)"
      }
     ]
    },
    {
     "id": "wirtschaftswissenschaft-m-sc",
     "program": "Wirtschaftswissenschaft",
     "degree": "M.Sc.",
     "qis_names": [
      "Wirtschaftswissenschaft",
      "Wirtschaftswissenschaft (PO 2018)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_wiwi_mpo26.pdf",
     "faculty": "Wirtschaftswissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2018",
       "code": "wirtschaftswissenschaft-1|m.sc.|2018",
       "source": "luh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "luh|wirtschaftswissenschaft-1|m.sc.|2018",
       "format": "wiwi-modulhandbuch",
       "url": "https://www.wiwi.uni-hannover.de/fileadmin/wiwi/pdf/modulhandbuch/sose2026/Modulhandbuch_Master_Wirtschaftswissenschaft_Sommersemester_2026.pdf"
      }
     ]
    },
    {
     "id": "wirtschaftswissenschaft-b-sc",
     "program": "Wirtschaftswissenschaft",
     "degree": "B.Sc.",
     "qis_names": [
      "Wirtschaftswissenschaft",
      "Wirtschaftswissenschaft (PO 2017)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_wiwi_bpo26.pdf",
     "faculty": "Wirtschaftswissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2017",
       "code": "wirtschaftswissenschaft|b.sc.|2017",
       "source": "luh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "luh|wirtschaftswissenschaft|b.sc.|2017",
       "format": "wiwi-modulhandbuch",
       "url": "https://www.wiwi.uni-hannover.de/fileadmin/wiwi/pdf/modulhandbuch/sose2026/Modulhandbuch_Bachelor_Wirtschaftswissenschaft_Sommersemester_2026.pdf"
      }
     ]
    },
    {
     "id": "ai-driven-mechatronics-and-robotics-m-sc",
     "program": "AI-driven Mechatronics and Robotics",
     "degree": "M.Sc.",
     "qis_names": [
      "AI-driven Mechatronics and Robotics",
      "AI-driven Mechatronics and Robotics (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_mechatr_mpo26_PO26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2025",
       "code": "ai-driven-mechatronics-and-robotics|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|ai-driven-mechatronics-and-robotics|m.sc.|2025",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_AI-driven_MSc_PO_25.pdf"
      }
     ]
    },
    {
     "id": "european-master-in-landscape-architecture-emila-m-sc",
     "program": "European Master in Landscape Architecture (EMiLA)",
     "degree": "M.Sc.",
     "qis_names": [
      "European in Landscape Architecture (EMiLA)",
      "European in Landscape Architecture (EMiLA) (PO 2015)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_landschaft_mpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": [
      {
       "po": "2015",
       "code": "european-master-in-landscape-architecture-emila|m.sc.|2015",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|european-master-in-landscape-architecture-emila|m.sc.|2015",
       "format": "luh-modulbeschreibung",
       "url": "https://www.archland.uni-hannover.de/fileadmin/archland/STUDIUM/LAUM/Modulbeschreibungen/Modulkatalog_MA_LA_Pflicht_2026.pdf",
       "label": "Pflichtmodule Landschaftsarchitektur (M.Sc.)"
      }
     ]
    },
    {
     "id": "geodaesie-und-geoinformatik-vertiefung-geomatik-m-sc",
     "program": "Geodäsie und Geoinformatik – Vertiefung Geomatik",
     "degree": "M.Sc.",
     "qis_names": [
      "Geodäsie und Geoinformatik – Vertiefung Geomatik",
      "Geodäsie und Geoinformatik – Vertiefung Geomatik (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_geod_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2025",
       "code": "geodaesie-und-geoinformatik-vertiefung-geomatik|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geodaesie-und-geoinformatik-vertiefung-geomatik|m.sc.|2025",
       "format": "luh-modulbeschreibung",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Geodaesie/Dokumente/Master_GuG/20260310_Modulkatalog_GuG_Master_PO25.pdf"
      }
     ]
    },
    {
     "id": "geodaesie-und-geoinformatik-vertiefung-navigation-und-umweltrobotik-m-sc",
     "program": "Geodäsie und Geoinformatik – Vertiefung Navigation und Umweltrobotik",
     "degree": "M.Sc.",
     "qis_names": [
      "Geodäsie und Geoinformatik – Vertiefung Navigation und Umweltrobotik",
      "Geodäsie und Geoinformatik – Vertiefung Navigation und Umweltrobotik (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_geod_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2025",
       "code": "geodaesie-und-geoinformatik-vertiefung-navigation-und-umweltrobotik|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geodaesie-und-geoinformatik-vertiefung-navigation-und-umweltrobotik|m.sc.|2025",
       "format": "luh-modulbeschreibung",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Geodaesie/Dokumente/Master_GuG/20260310_Modulkatalog_GuG_Master_PO25.pdf"
      }
     ]
    },
    {
     "id": "geodaesie-und-geoinformatik-vertiefung-remote-sensing-and-gis-m-sc",
     "program": "Geodäsie und Geoinformatik – Vertiefung Remote Sensing and GIS",
     "degree": "M.Sc.",
     "qis_names": [
      "Geodäsie und Geoinformatik – Vertiefung Remote Sensing and GIS",
      "Geodäsie und Geoinformatik – Vertiefung Remote Sensing and GIS (PO 2025)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_geod_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": [
      {
       "po": "2025",
       "code": "geodaesie-und-geoinformatik-vertiefung-remote-sensing-and-gis|m.sc.|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geodaesie-und-geoinformatik-vertiefung-remote-sensing-and-gis|m.sc.|2025",
       "format": "luh-modulbeschreibung",
       "url": "https://www.fbg.uni-hannover.de/fileadmin/fbg/Geodaesie/Dokumente/Master_GuG/20260310_Modulkatalog_GuG_Master_PO25.pdf"
      }
     ]
    },
    {
     "id": "computer-science-logic-and-computation-track-m-sc-double-degree",
     "program": "Computer Science – Logic and Computation Track",
     "degree": "M.Sc. (Double Degree)",
     "qis_names": [
      "Computer Science – Logic and Computation Track",
      "Computer Science – Logic and Computation Track (PO 2017)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_inform_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "INFMSc25",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-vertiefung-logic-and-computation|m.sc.-double-degree|2017",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-INFMSc25-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "mechanical-engineering-maschinenbau-track-m-sc",
     "program": "Mechanical Engineering - Maschinenbau Track",
     "degree": "M.Sc.",
     "qis_names": [
      "Mechanical Engineering - Maschinenbau Track",
      "Mechanical Engineering - Maschinenbau Track (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_maschbau_mpo26_PO2026.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": [
      {
       "po": "2026",
       "code": "mechanical-engineering-mechanical-engineering-track|m.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|mechanical-engineering-mechanical-engineering-track|m.sc.|2026",
       "format": "mb-modulkatalog",
       "url": "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/Modulkatalog_ME_MSc_PO_26.pdf"
      }
     ]
    },
    {
     "id": "microelectronics-engineering-elektrotechnik-und-informationstechnik-track-m-sc",
     "program": "Microelectronics Engineering - Elektrotechnik und Informationstechnik Track",
     "degree": "M.Sc.",
     "qis_names": [
      "Microelectronics Engineering - Elektrotechnik und Informationstechnik Track",
      "Microelectronics Engineering - Elektrotechnik und Informationstechnik Track (PO 2017)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_etec_inf_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "ETMSc17",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|microelectronics-engineering-electrical-engineering-and-information-technology-track-master-of-science|m.sc.|2017",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-ETMSc17-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "religion-in-the-public-sphere-double-degree-track-m-a-double-degree",
     "program": "Religion in the Public Sphere – Double Degree Track",
     "degree": "M.A. (Double Degree)",
     "qis_names": [
      "Religion in the Public Sphere – Double Degree Track",
      "Religion in the Public Sphere – Double Degree Track (PO 2021)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_relips_mpo2026.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2021",
       "code": "religion-in-the-public-sphere-double-degree-track|m.a.-double-degree|2021",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|religion-in-the-public-sphere-double-degree-track|m.a.-double-degree|2021",
       "format": "scanned",
       "url": "https://www.irw.uni-hannover.de/fileadmin/rewi/Relpub/2026_08_28_RELPUB_module_catalogue.pdf"
      }
     ]
    },
    {
     "id": "power-engineering-renewable-energy-and-electrical-power-engineering-track-m-sc-double-degree",
     "program": "Power Engineering – Renewable Energy and Electrical Power Engineering Track",
     "degree": "M.Sc. (Double Degree)",
     "qis_names": [
      "Power Engineering – Renewable Energy and Electrical Power Engineering Track"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "unbekannt",
       "code": "EntMsc24",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|renewable-energy-and-electrical-power-engineering-track|m.sc.-double-degree|unbekannt",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-EntMsc24-WS_2026_27.pdf",
       "label": "Zuordnung geschaetzt"
      }
     ]
    },
    {
     "id": "umwelt-und-regionalplanung-vertiefung-naturschutz-und-landschaftsplanung-m-sc",
     "program": "Umwelt- und Regionalplanung – Vertiefung Naturschutz und Landschaftsplanung",
     "degree": "M.Sc.",
     "qis_names": [
      "Umwelt- und Regionalplanung – Vertiefung Naturschutz und Landschaftsplanung",
      "Umwelt- und Regionalplanung – Vertiefung Naturschutz und Landschaftsplanung (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_umweltplan_mpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": [
      {
       "po": "2020",
       "code": "umwelt-und-regionalplanung-major-naturschutz-und-landschaftsplanung|m.sc.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|umwelt-und-regionalplanung-major-naturschutz-und-landschaftsplanung|m.sc.|2020",
       "format": "luh-modulbeschreibung",
       "url": "https://www.archland.uni-hannover.de/fileadmin/archland/STUDIUM/LAUM/Modulbeschreibungen/Modulkatalog_MA_URP_Pflicht_2026.pdf",
       "label": "Pflichtmodule"
      }
     ]
    },
    {
     "id": "umwelt-und-regionalplanung-vertiefung-regionalplanung-m-sc",
     "program": "Umwelt- und Regionalplanung – Vertiefung Regionalplanung",
     "degree": "M.Sc.",
     "qis_names": [
      "Umwelt- und Regionalplanung – Vertiefung Regionalplanung",
      "Umwelt- und Regionalplanung – Vertiefung Regionalplanung (PO 2020)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_umweltplan_mpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": [
      {
       "po": "2020",
       "code": "umwelt-und-regionalplanung-major-regionalplanung|m.sc.|2020",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|umwelt-und-regionalplanung-major-regionalplanung|m.sc.|2020",
       "format": "luh-modulbeschreibung",
       "url": "https://www.archland.uni-hannover.de/fileadmin/archland/STUDIUM/LAUM/Modulbeschreibungen/Modulkatalog_MA_URP_Pflicht_2026.pdf",
       "label": "Pflichtmodule"
      }
     ]
    },
    {
     "id": "wirtschaftsgeographie-innovation-und-nachhaltigkeit-double-degree-track-m-sc-double-degree",
     "program": "Wirtschaftsgeographie, Innovation und Nachhaltigkeit – Double Degree Track",
     "degree": "M.Sc. (Double Degree)",
     "qis_names": [
      "Wirtschaftsgeographie, Innovation und Nachhaltigkeit – Double Degree Track",
      "Wirtschaftsgeographie, Innovation und Nachhaltigkeit – Double Degree Track (PO 2025)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_wirtgeoInno_mpo25.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2025",
       "code": "wirtschaftsgeographie-innovation-und-nachhaltigkeit-double-degree-track|m.sc.-double-degree|2025",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|wirtschaftsgeographie-innovation-und-nachhaltigkeit-double-degree-track|m.sc.-double-degree|2025",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geographie/Detail-Wirtschaftsgeographie-MSc/Modulkatalog_MSc_WIN.pdf"
      }
     ]
    },
    {
     "id": "angewandte-sprachwissenschaft-im-bachelorstudiengang-sonderpaedagogik-ausserschulisch-b-a",
     "program": "Angewandte Sprachwissenschaft im Bachelorstudiengang Sonderpädagogik, außerschulisch",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik, außerschulisch",
      "Sonderpädagogik, außerschulisch (PO 2016)",
      "Angewandte Sprachwissenschaft",
      "Angewandte Sprachwissenschaft (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "bautechnik-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Bautechnik im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Bautechnik",
      "Bautechnik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": []
    },
    {
     "id": "bautechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Bautechnik im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Bautechnik",
      "Bautechnik (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": []
    },
    {
     "id": "bautechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Bautechnik im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Bautechnik",
      "Bautechnik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": []
    },
    {
     "id": "biologie-im-faecheruebergreifenden-bachelor-b-sc",
     "program": "Biologie im Fächerübergreifenden Bachelor",
     "degree": "B.Sc.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Biologie",
      "Biologie (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "biologie-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|biologie-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Biologie/Detail-Biologie-FueBa/Modulkataloge/2026_Modulkatalog_FueBa_Biologie_WiSe26-27_draft.pdf"
      }
     ]
    },
    {
     "id": "biologie-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Biologie im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Biologie",
      "Biologie (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "biologie-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|biologie-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Biologie/Detail-Biologie-MEd/Modulkataloge/2026_Modulkatalog_MEd_Biologie_WiSe26-27_draft.pdf"
      }
     ]
    },
    {
     "id": "chemie-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Chemie im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Chemie",
      "Chemie (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "chemie-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-TEd/Modulkatalog_TE_LBS_Chemie.pdf"
      }
     ]
    },
    {
     "id": "chemie-im-faecheruebergreifenden-bachelor-b-sc",
     "program": "Chemie im Fächerübergreifenden Bachelor",
     "degree": "B.Sc.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Chemie",
      "Chemie (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "chemie-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-FueBa/Modulkatalog_FUEBA_Chemie.pdf"
      }
     ]
    },
    {
     "id": "chemie-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Chemie im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Chemie",
      "Chemie (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2026",
       "code": "chemie-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-TEd/Modulkatalog_TE_LBS_Chemie.pdf"
      }
     ]
    },
    {
     "id": "chemie-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Chemie im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Chemie",
      "Chemie (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "chemie-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-TEd/Modulkatalog_TE_LBS_Chemie.pdf"
      }
     ]
    },
    {
     "id": "chemie-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Chemie im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Chemie",
      "Chemie (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "chemie-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "scanned",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Chemie-Biochemie/Detail-Chemie-MEd/Modulhandbuch_MEd_LaG_Chemie.pdf"
      }
     ]
    },
    {
     "id": "darstellendes-spiel-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Darstellendes Spiel im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Darstellendes Spiel",
      "Darstellendes Spiel (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "darstellendes-spiel-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Darstellendes Spiel im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Darstellendes Spiel",
      "Darstellendes Spiel (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "deutsch-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Deutsch im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Deutsch",
      "Deutsch (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "deutsch-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Deutsch im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Deutsch",
      "Deutsch (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "deutsch-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Deutsch im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Deutsch",
      "Deutsch (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "deutsch-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Deutsch im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Deutsch",
      "Deutsch (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "deutsch-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Deutsch im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Deutsch",
      "Deutsch (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "deutsch-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Deutsch im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Deutsch",
      "Deutsch (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "deutsch-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Deutsch im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Deutsch",
      "Deutsch (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "elektrotechnik-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Elektrotechnik im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Elektrotechnik",
      "Elektrotechnik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2016",
       "code": "L_BSc_ET",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|elektrotechnik-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_BSc_ET-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "elektrotechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Elektrotechnik im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Elektrotechnik",
      "Elektrotechnik (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "L_MEd_Sp_ET",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|elektrotechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_MEd_Sp_ET-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "elektrotechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Elektrotechnik im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Elektrotechnik",
      "Elektrotechnik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2016",
       "code": "L_MEd_ET",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|elektrotechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_MEd_ET-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "englisch-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Englisch im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Englisch",
      "Englisch (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "englisch-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "luh|englisch-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "scanned",
       "url": "https://www.engsem.uni-hannover.de/fileadmin/engsem/Studium/Modulkatalog_Fach_Englisch_WiSe2025-26.pdf"
      }
     ]
    },
    {
     "id": "englisch-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Englisch im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Englisch",
      "Englisch (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "englisch-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "luh|englisch-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "format": "scanned",
       "url": "https://www.engsem.uni-hannover.de/fileadmin/engsem/Studium/Modulkatalog_Fach_Englisch_WiSe2025-26.pdf"
      }
     ]
    },
    {
     "id": "englisch-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Englisch im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Englisch",
      "Englisch (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "englisch-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "luh|englisch-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "scanned",
       "url": "https://www.engsem.uni-hannover.de/fileadmin/engsem/Studium/Modulkatalog_Fach_Englisch_WiSe2025-26.pdf"
      }
     ]
    },
    {
     "id": "englisch-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Englisch im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Englisch",
      "Englisch (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "englisch-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "luh|englisch-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "scanned",
       "url": "https://www.engsem.uni-hannover.de/fileadmin/engsem/Studium/Modulkatalog_Fach_Englisch_WiSe2025-26.pdf"
      }
     ]
    },
    {
     "id": "erdkunde-geographie-im-faecheruebergreifenden-bachelor-b-a-b-sc",
     "program": "Erdkunde / Geographie im Fächerübergreifenden Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Erdkunde / Geographie",
      "Erdkunde / Geographie (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "erdkunde-geographie-im-faecheruebergreifenden-bachelor|b.a.-b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|erdkunde-geographie-im-faecheruebergreifenden-bachelor|b.a.-b.sc.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geographie/Studiengangsuebergreifende_Dokumente/Modulkatalog_Bachelor_Geographie.pdf"
      }
     ]
    },
    {
     "id": "erdkunde-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Erdkunde im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Erdkunde",
      "Erdkunde (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "erdkunde-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|erdkunde-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Geographie/Studiengangsuebergreifende_Dokumente/Modulkatalog_Bachelor_Geographie.pdf"
      }
     ]
    },
    {
     "id": "evangelische-religion-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Evangelische Religion im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Evangelische Religion",
      "Evangelische Religion (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "evangelische-religion-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Evangelische Religion im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Evangelische Religion",
      "Evangelische Religion (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "evangelische-religion-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Evangelische Religion im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Evangelische Religion",
      "Evangelische Religion (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "evangelische-religion-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Evangelische Religion im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Evangelische Religion",
      "Evangelische Religion (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "evangelische-religion-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Evangelische Religion im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Evangelische Religion",
      "Evangelische Religion (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "evangelische-religion-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Evangelische Religion im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Evangelische Religion",
      "Evangelische Religion (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "evangelische-theologie-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Evangelische Theologie im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Evangelische Theologie",
      "Evangelische Theologie (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "farbtechnik-und-raumgestaltung-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Farbtechnik und Raumgestaltung im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Farbtechnik und Raumgestaltung",
      "Farbtechnik und Raumgestaltung (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": []
    },
    {
     "id": "farbtechnik-und-raumgestaltung-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Farbtechnik und Raumgestaltung im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Farbtechnik und Raumgestaltung",
      "Farbtechnik und Raumgestaltung (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": []
    },
    {
     "id": "farbtechnik-und-raumgestaltung-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Farbtechnik und Raumgestaltung im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Farbtechnik und Raumgestaltung",
      "Farbtechnik und Raumgestaltung (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Fakultät für Architektur und Landschaft",
     "pos": []
    },
    {
     "id": "geschichte-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Geschichte im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Geschichte",
      "Geschichte (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "geschichte-im-bachelorstudiengang-sonderpaedagogik|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geschichte-im-bachelorstudiengang-sonderpaedagogik|b.a.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.hist.uni-hannover.de/fileadmin/hist/News_und_Veranstaltungen/PDF/Modulkatalog_LAG_FueBa_SoPaed.pdf",
       "label": "Modulkatalog Lehramt Gymnasium, FueBa, Sonderpaedagogik"
      }
     ]
    },
    {
     "id": "geschichte-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Geschichte im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Geschichte",
      "Geschichte (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "geschichte-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geschichte-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.hist.uni-hannover.de/fileadmin/hist/News_und_Veranstaltungen/PDF/Modulkatalog_LAG_FueBa_SoPaed.pdf",
       "label": "Modulkatalog Lehramt Gymnasium, FueBa, Sonderpaedagogik"
      }
     ]
    },
    {
     "id": "geschichte-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Geschichte im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Geschichte",
      "Geschichte (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "geschichte-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geschichte-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.hist.uni-hannover.de/fileadmin/hist/News_und_Veranstaltungen/PDF/Modulkatalog_LAG_FueBa_SoPaed.pdf",
       "label": "Modulkatalog Lehramt Gymnasium, FueBa, Sonderpaedagogik"
      }
     ]
    },
    {
     "id": "geschichte-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Geschichte im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Geschichte",
      "Geschichte (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "geschichte-im-masterstudiengang-lehramt-fuer-sonderpaedagogik|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|geschichte-im-masterstudiengang-lehramt-fuer-sonderpaedagogik|m.ed.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.hist.uni-hannover.de/fileadmin/hist/News_und_Veranstaltungen/PDF/Modulkatalog_LAG_FueBa_SoPaed.pdf",
       "label": "Modulkatalog Lehramt Gymnasium, FueBa, Sonderpaedagogik"
      }
     ]
    },
    {
     "id": "holztechnik-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Holztechnik im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Holztechnik",
      "Holztechnik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": []
    },
    {
     "id": "holztechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Holztechnik im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Holztechnik",
      "Holztechnik (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": []
    },
    {
     "id": "holztechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Holztechnik im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Holztechnik",
      "Holztechnik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Fakultät für Bauingenieurwesen und Geodäsie",
     "pos": []
    },
    {
     "id": "informatik-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Informatik im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Informatik",
      "Informatik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2016",
       "code": "L_BSc_INF",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_BSc_INF-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "informatik-im-faecheruebergreifenden-bachelor-b-sc",
     "program": "Informatik im Fächerübergreifenden Bachelor",
     "degree": "B.Sc.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Informatik",
      "Informatik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2016",
       "code": "L_BSc_EINF",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_BSc_EINF-WS_2026_27.pdf",
       "label": "Erstfach"
      },
      {
       "po": "2016",
       "code": "L_BSc_ZINF",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_BSc_ZINF-WS_2026_27.pdf",
       "label": "Zweitfach"
      }
     ]
    },
    {
     "id": "informatik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Informatik im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Informatik",
      "Informatik (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "L_MEd_Sp-INF",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_MEd_Sp-INF-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "informatik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Informatik im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Informatik",
      "Informatik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2016",
       "code": "L_MEd_INF",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_MEd_INF-WS_2026_27.pdf"
      }
     ]
    },
    {
     "id": "informatik-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Informatik im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Informatik",
      "Informatik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Fakultät für Elektrotechnik und Informatik",
     "pos": [
      {
       "po": "2016",
       "code": "L_MEd_EINF",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_MEd_EINF-WS_2026_27.pdf",
       "label": "Erstfach"
      },
      {
       "po": "2016",
       "code": "L_MEd_ZINF",
       "source": "luh-fei-modkat",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|informatik-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "modkat-FEI",
       "url": "https://modkat.fei.uni-hannover.de/material/modkat-full-L_MEd_ZINF-WS_2026_27.pdf",
       "label": "Zweitfach"
      }
     ]
    },
    {
     "id": "katholische-religion-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Katholische Religion im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Katholische Religion",
      "Katholische Religion (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "katholische-religion-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Katholische Religion im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Katholische Religion",
      "Katholische Religion (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "katholische-religion-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Katholische Religion im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Katholische Religion",
      "Katholische Religion (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "katholische-religion-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Katholische Religion im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Katholische Religion",
      "Katholische Religion (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "katholische-religion-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Katholische Religion im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Katholische Religion",
      "Katholische Religion (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "katholische-religion-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Katholische Religion im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Katholische Religion",
      "Katholische Religion (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "katholische-theologie-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Katholische Theologie im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Katholische Theologie",
      "Katholische Theologie (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "kunst-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Kunst im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Kunst",
      "Kunst (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "kunst-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Kunst im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Kunst",
      "Kunst (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "lebensmittelwissenschaft-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Lebensmittelwissenschaft im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Lebensmittelwissenschaft",
      "Lebensmittelwissenschaft (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "lebensmittelwissenschaft-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|lebensmittelwissenschaft-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Lebensmittelwissenschaft/Detail-Lebensmittelwissens-TEd/___Modulkatalog-BA-Tec.Ed.-LMW_2026-10-01.pdf"
      }
     ]
    },
    {
     "id": "lebensmittelwissenschaft-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Lebensmittelwissenschaft im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Lebensmittelwissenschaft",
      "Lebensmittelwissenschaft (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2026",
       "code": "lebensmittelwissenschaft-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|lebensmittelwissenschaft-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Lebensmittelwissenschaft/Detail-Lebensmittelwissens-MEd-sprint/Modulkatalog-MA-LBS-Sprint_LMW.pdf"
      }
     ]
    },
    {
     "id": "lebensmittelwissenschaft-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Lebensmittelwissenschaft im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Lebensmittelwissenschaft",
      "Lebensmittelwissenschaft (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Naturwissenschaftliche Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "lebensmittelwissenschaft-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|lebensmittelwissenschaft-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/Lebensmittelwissenschaft/Detail-Lebensmittelwissens-MEd/___Modulkatalog-MA-LBS-LMW_2026-10-01.pdf"
      }
     ]
    },
    {
     "id": "mathematik-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Mathematik im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Mathematik",
      "Mathematik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "mathematik-im-bachelorstudiengang-sonderpaedagogik|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik-im-bachelorstudiengang-sonderpaedagogik|b.a.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_mathe_PO_2026.pdf",
       "label": "Modulkatalog Lehraemter Mathematik"
      }
     ]
    },
    {
     "id": "mathematik-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Mathematik im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Mathematik",
      "Mathematik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "mathematik-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_mathe_PO_2026.pdf",
       "label": "Modulkatalog Lehraemter Mathematik"
      }
     ]
    },
    {
     "id": "mathematik-im-faecheruebergreifenden-bachelor-b-sc",
     "program": "Mathematik im Fächerübergreifenden Bachelor",
     "degree": "B.Sc.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Mathematik",
      "Mathematik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "mathematik-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_mathe_PO_2026.pdf",
       "label": "Modulkatalog Lehraemter Mathematik"
      }
     ]
    },
    {
     "id": "mathematik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Mathematik im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Mathematik",
      "Mathematik (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2026",
       "code": "mathematik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_mathe_PO_2026.pdf",
       "label": "Modulkatalog Lehraemter Mathematik"
      }
     ]
    },
    {
     "id": "mathematik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Mathematik im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Mathematik",
      "Mathematik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "mathematik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_mathe_PO_2026.pdf",
       "label": "Modulkatalog Lehraemter Mathematik"
      }
     ]
    },
    {
     "id": "mathematik-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Mathematik im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Mathematik",
      "Mathematik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "mathematik-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_mathe_PO_2026.pdf",
       "label": "Modulkatalog Lehraemter Mathematik"
      }
     ]
    },
    {
     "id": "mathematik-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Mathematik im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Mathematik",
      "Mathematik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "mathematik-im-masterstudiengang-lehramt-fuer-sonderpaedagogik|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|mathematik-im-masterstudiengang-lehramt-fuer-sonderpaedagogik|m.ed.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_mathe_PO_2026.pdf",
       "label": "Modulkatalog Lehraemter Mathematik"
      }
     ]
    },
    {
     "id": "metalltechnik-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Metalltechnik im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Metalltechnik",
      "Metalltechnik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": []
    },
    {
     "id": "metalltechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Metalltechnik im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Metalltechnik",
      "Metalltechnik (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": []
    },
    {
     "id": "metalltechnik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Metalltechnik im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Metalltechnik",
      "Metalltechnik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Fakultät für Maschinenbau",
     "pos": []
    },
    {
     "id": "musik-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Musik im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Musik",
      "Musik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "musik-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Musik im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Musik",
      "Musik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "musik-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Musik im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Musik",
      "Musik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "musik-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Musik im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Musik",
      "Musik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "pflege-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Pflege im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Pflege",
      "Pflege (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "philosophie-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Philosophie im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Philosophie",
      "Philosophie (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "philosophie-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|philosophie-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.philos.uni-hannover.de/fileadmin/philos/Dateien/Modulkataloge/Modulkatalog_Philosophie_Fu__BaMasterLGZertifikat_WiSe_2025.26_20250801.pdf"
      }
     ]
    },
    {
     "id": "philosophie-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Philosophie im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Philosophie",
      "Philosophie (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "philosophie-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|philosophie-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.philos.uni-hannover.de/fileadmin/philos/Dateien/Modulkataloge/Modulkatalog_Philosophie_Fu__BaMasterLGZertifikat_WiSe_2025.26_20250801.pdf"
      }
     ]
    },
    {
     "id": "physik-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Physik im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Physik",
      "Physik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "physik-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|physik-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_physik_2026.pdf",
       "label": "Modulkatalog Lehraemter Physik"
      }
     ]
    },
    {
     "id": "physik-im-faecheruebergreifenden-bachelor-b-sc",
     "program": "Physik im Fächerübergreifenden Bachelor",
     "degree": "B.Sc.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Physik",
      "Physik (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "physik-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|physik-im-faecheruebergreifenden-bachelor|b.sc.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_physik_2026.pdf",
       "label": "Modulkatalog Lehraemter Physik"
      }
     ]
    },
    {
     "id": "physik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Physik im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Physik",
      "Physik (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2026",
       "code": "physik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|physik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_physik_2026.pdf",
       "label": "Modulkatalog Lehraemter Physik"
      }
     ]
    },
    {
     "id": "physik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Physik im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Physik",
      "Physik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "physik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|physik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_physik_2026.pdf",
       "label": "Modulkatalog Lehraemter Physik"
      }
     ]
    },
    {
     "id": "physik-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Physik im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Physik",
      "Physik (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Fakultät für Mathematik und Physik",
     "pos": [
      {
       "po": "2016",
       "code": "physik-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|physik-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "maphy-katalog",
       "url": "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/katalog_LA_physik_2026.pdf",
       "label": "Modulkatalog Lehraemter Physik"
      }
     ]
    },
    {
     "id": "politikwissenschaft-politik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Politikwissenschaft (Politik) im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Politikwissenschaft (Politik)",
      "Politikwissenschaft (Politik) (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2026",
       "code": "politik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|politik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "format": "phil-kv-tabelle",
       "url": "https://www.ipw.uni-hannover.de/fileadmin/ipw/Institut_Dateien/Modulkataloge_WiSe_2026-27/MA_LBS-Sprint_Pol_Modulkatalog_Stand_10_26__1_.pdf"
      }
     ]
    },
    {
     "id": "politikwissenschaft-politik-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Politikwissenschaft (Politik) im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Politikwissenschaft (Politik)",
      "Politikwissenschaft (Politik) (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "politikwissenschaft-politik-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|politikwissenschaft-politik-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.ipw.uni-hannover.de/fileadmin/ipw/Institut_Dateien/Modulkataloge_WiSe_2026-27/BSc_TE_Pol_Modulkatalog_Stand_10_26.pdf"
      }
     ]
    },
    {
     "id": "politikwissenschaft-politik-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Politikwissenschaft (Politik) im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Politikwissenschaft (Politik)",
      "Politikwissenschaft (Politik) (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "politikwissenschaft-politik-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|politikwissenschaft-politik-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.ipw.uni-hannover.de/fileadmin/ipw/Institut_Dateien/Modulkataloge_WiSe_2026-27/FUEBA_Pol_Modulkatalog_Stand_10_26.pdf"
      }
     ]
    },
    {
     "id": "politikwissenschaft-politik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Politikwissenschaft (Politik) im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Politikwissenschaft (Politik)",
      "Politikwissenschaft (Politik) (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "politikwissenschaft-politik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|politikwissenschaft-politik-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.ipw.uni-hannover.de/fileadmin/ipw/Institut_Dateien/Modulkataloge_WiSe_2026-27/MA_Lbs_Pol_Modulkatalog_Stand_10_26.pdf"
      }
     ]
    },
    {
     "id": "politikwissenschaft-politik-wirtschaft-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Politikwissenschaft (Politik-Wirtschaft) im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Politikwissenschaft (Politik-Wirtschaft)",
      "Politikwissenschaft (Politik-Wirtschaft) (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "politikwissenschaft-politik-wirtschaft-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|politikwissenschaft-politik-wirtschaft-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.ipw.uni-hannover.de/fileadmin/ipw/Institut_Dateien/Modulkataloge_WiSe_2026-27/MA_LG_Pol_Wi_Modulkatalog_Stand_10_26.pdf"
      }
     ]
    },
    {
     "id": "religionswissenschaft-werte-und-normen-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Religionswissenschaft / Werte und Normen im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Religionswissenschaft / Werte und Normen",
      "Religionswissenschaft / Werte und Normen (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "religionswissenschaft-werte-und-normen-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|religionswissenschaft-werte-und-normen-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "format": "scanned",
       "url": "https://www.irw.uni-hannover.de/fileadmin/rewi/studium/261001_Modulhandbuch_FueBA_Stand_Oktober_26.pdf"
      }
     ]
    },
    {
     "id": "sachunterricht-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Sachunterricht im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Sachunterricht",
      "Sachunterricht (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "sachunterricht-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Sachunterricht im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Sachunterricht",
      "Sachunterricht (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "spanisch-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Spanisch im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Spanisch",
      "Spanisch (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "spanisch-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Spanisch im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Spanisch",
      "Spanisch (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "spanisch-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Spanisch im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Spanisch",
      "Spanisch (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "spanisch-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Spanisch im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Spanisch",
      "Spanisch (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": []
    },
    {
     "id": "sport-im-bachelorstudiengang-sonderpaedagogik-b-a",
     "program": "Sport im Bachelorstudiengang Sonderpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sonderpädagogik",
      "Sonderpädagogik (PO 2016)",
      "Sport",
      "Sport (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_sonderpaed_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "sport-im-bachelorstudiengang-sonderpaedagogik|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|sport-im-bachelorstudiengang-sonderpaedagogik|b.a.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Fach_Sport_WiSe2026-27.pdf",
       "label": "Modulkatalog der Lehramtsstudiengaenge Sport"
      }
     ]
    },
    {
     "id": "sport-im-bachelorstudiengang-technical-education-b-sc",
     "program": "Sport im Bachelorstudiengang Technical Education",
     "degree": "B.Sc.",
     "qis_names": [
      "Technical Education",
      "Technical Education (PO 2016)",
      "Sport",
      "Sport (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_technical_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "sport-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|sport-im-bachelorstudiengang-technical-education|b.sc.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Fach_Sport_WiSe2026-27.pdf",
       "label": "Modulkatalog der Lehramtsstudiengaenge Sport"
      }
     ]
    },
    {
     "id": "sport-im-faecheruebergreifenden-bachelor-b-a",
     "program": "Sport im Fächerübergreifenden Bachelor",
     "degree": "B.A.",
     "qis_names": [
      "Fächerübergreifender",
      "Fächerübergreifender (PO 2016)",
      "Sport",
      "Sport (PO 2016)"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_fbachelor_bpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "sport-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|sport-im-faecheruebergreifenden-bachelor|b.a.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Fach_Sport_WiSe2026-27.pdf",
       "label": "Modulkatalog der Lehramtsstudiengaenge Sport"
      }
     ]
    },
    {
     "id": "sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint-m-ed",
     "program": "Sport im Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)",
      "Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint) (PO 2026)",
      "Sport",
      "Sport (PO 2026)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lbsSprint_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2026",
       "code": "sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
       "format": "phil-kv-tabelle",
       "url": "https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Fach_Sport_WiSe2026-27.pdf",
       "label": "Modulkatalog der Lehramtsstudiengaenge Sport"
      }
     ]
    },
    {
     "id": "sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-m-ed",
     "program": "Sport im Masterstudiengang Lehramt an berufsbildenden Schulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an berufsbildenden Schulen",
      "Lehramt an berufsbildenden Schulen (PO 2016)",
      "Sport",
      "Sport (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrbs_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Fach_Sport_WiSe2026-27.pdf",
       "label": "Modulkatalog der Lehramtsstudiengaenge Sport"
      }
     ]
    },
    {
     "id": "sport-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Sport im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Sport",
      "Sport (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "sport-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|sport-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Fach_Sport_WiSe2026-27.pdf",
       "label": "Modulkatalog der Lehramtsstudiengaenge Sport"
      }
     ]
    },
    {
     "id": "sport-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-m-ed",
     "program": "Sport im Masterstudiengang Lehramt für Sonderpädagogik",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt für Sonderpädagogik",
      "Lehramt für Sonderpädagogik (PO 2016)",
      "Sport",
      "Sport (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrso_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "sport-im-masterstudiengang-lehramt-fuer-sonderpaedagogik|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "luh|sport-im-masterstudiengang-lehramt-fuer-sonderpaedagogik|m.ed.|2016",
       "format": "phil-kv-tabelle",
       "url": "https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Fach_Sport_WiSe2026-27.pdf",
       "label": "Modulkatalog der Lehramtsstudiengaenge Sport"
      }
     ]
    },
    {
     "id": "werte-und-normen-im-masterstudiengang-lehramt-an-gymnasien-m-ed",
     "program": "Werte und Normen im Masterstudiengang Lehramt an Gymnasien",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Gymnasien",
      "Lehramt an Gymnasien (PO 2016)",
      "Werte und Normen",
      "Werte und Normen (PO 2016)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hannover.de/fileadmin/luh/studium/ordnungen/stpo/f_lehrgym_mpo26.pdf",
     "faculty": "Philosophische Fakultät",
     "pos": [
      {
       "po": "2016",
       "code": "werte-und-normen-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|werte-und-normen-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016",
       "format": "luh-modulbeschreibung",
       "url": "https://www.philos.uni-hannover.de/fileadmin/philos/Dateien/Modulkataloge/Modulkatalog_Werte_und_Normen_WiSe_2026.27.pdf"
      }
     ]
    }
   ]
  },
  {
   "id": "hildesheim",
   "name": "Universität Hildesheim",
   "sources": [
    {
     "id": "hildesheim-grundstock",
     "format": "grundstock",
     "note": "Kataloge nur aus dem StudiNow-Grundstock (App-Ressource StudyCatalogSeed), auf dem Geraet wird nichts geladen (tools/build-hildesheim-seed.py)",
     "probe_current_term": false
    }
   ],
   "programs": [
    {
     "id": "angewandte-informatik-b-sc",
     "program": "Angewandte Informatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Angewandte Informatik"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5076",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "angewandte-informatik|b.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|angewandte-informatik|b.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-AI_PO2023-PO2024_Stand_2026.04.03.pdf"
      }
     ],
     "lsf": {
      "nummer": 983,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=983&idcol=k_abstgv.abstgvnr&idval=983&purge=n&getglobal=n",
      "text": "B.Sc. Angewandte Informatik"
     },
     "lsf_names": [
      "B.Sc. Angewandte Informatik"
     ]
    },
    {
     "id": "angewandte-informatik-m-sc",
     "program": "Angewandte Informatik",
     "degree": "M.Sc.",
     "qis_names": [
      "Angewandte Informatik"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5132",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "angewandte-informatik|m.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|angewandte-informatik|m.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-AI_PO2023-PO2024_Stand_2026.04.03.pdf"
      }
     ],
     "lsf": {
      "nummer": 985,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=985&idcol=k_abstgv.abstgvnr&idval=985&purge=n&getglobal=n",
      "text": "M.Sc. Angewandte Informatik"
     },
     "lsf_names": [
      "M.Sc. Angewandte Informatik"
     ]
    },
    {
     "id": "barrierefreie-kommunikation-m-a",
     "program": "Barrierefreie Kommunikation",
     "degree": "M.A.",
     "qis_names": [
      "Barrierefreie Kommunikation"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4669",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": []
    },
    {
     "id": "data-analytics-m-sc",
     "program": "Data Analytics",
     "degree": "M.Sc.",
     "qis_names": [
      "Data Analytics"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5132",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "data-analytics|m.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2023/24"
       ],
       "study_plan": null,
       "key": "hildesheim|data-analytics|m.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5143"
      }
     ],
     "lsf": {
      "nummer": 840,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=840&idcol=k_abstgv.abstgvnr&idval=840&purge=n&getglobal=n",
      "text": "M.Sc. Data Analytics"
     },
     "lsf_names": [
      "M.Sc. Data Analytics"
     ]
    },
    {
     "id": "data-science-b-sc",
     "program": "Data Science",
     "degree": "B.Sc.",
     "qis_names": [
      "Data Science"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5076",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": []
    },
    {
     "id": "deutsch-als-zweitsprache-deutsch-als-fremdsprache-m-a",
     "program": "Deutsch als Zweitsprache/Deutsch als Fremdsprache",
     "degree": "M.A.",
     "qis_names": [
      "Deutsch als Zweitsprache/Deutsch als Fremdsprache"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4646",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2018",
       "code": "deutsch-als-zweitsprache-deutsch-als-fremdsprache|m.a.|2018",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|deutsch-als-zweitsprache-deutsch-als-fremdsprache|m.a.|2018",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4867"
      }
     ],
     "lsf": {
      "nummer": 680,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=680&idcol=k_abstgv.abstgvnr&idval=680&purge=n&getglobal=n",
      "text": "M.A. Deutsch als Zweitsprache/Deutsch als Fremdsprache"
     },
     "lsf_names": [
      "M.A. Deutsch als Zweitsprache/Deutsch als Fremdsprache"
     ]
    },
    {
     "id": "deutsch-franzoesischer-doppel-master-kulturvermittlung-mediation-culturelle-de-l-art-m-a",
     "program": "Deutsch-Französischer Doppel-Master Kulturvermittlung/Médiation Culturelle de l'Art",
     "degree": "M.A.",
     "qis_names": [
      "Deutsch-Französischer Doppel- Kulturvermittlung/Médiation Culturelle de l'Art"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": null,
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": []
    },
    {
     "id": "erziehungswissenschaft-mit-den-schwerpunkten-kindheitspaedagogik-diversitaet-m-a",
     "program": "Erziehungswissenschaft mit den Schwerpunkten Kindheitspädagogik/Diversität",
     "degree": "M.A.",
     "qis_names": [
      "Erziehungswissenschaft mit den Schwerpunkten Kindheitspädagogik/Diversität"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5091",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2023",
       "code": "erziehungswissenschaft-mit-den-schwerpunkten-kindheitspaedagogik-diversitaet|m.a.|2023",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2022"
       ],
       "study_plan": null,
       "key": "hildesheim|erziehungswissenschaft-mit-den-schwerpunkten-kindheitspaedagogik-diversitaet|m.a.|2023",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/media/fb1/erziehungswissenschaft_allg/Info_zum_Studiengang_Erziehungswissenschaft/Modulhandbuch_fuer_den_Master.pdf"
      }
     ],
     "lsf": {
      "nummer": 182,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=182&idcol=k_abstgv.abstgvnr&idval=182&purge=n&getglobal=n",
      "text": "M.A. Erziehungswissenschaft mit den Schwerpunkten Kindheitspädagogik/Diversität"
     },
     "lsf_names": [
      "M.A. Erziehungswissenschaft mit den Schwerpunkten Kindheitspädagogik/Diversität"
     ]
    },
    {
     "id": "erziehungswissenschaft-b-a",
     "program": "Erziehungswissenschaft",
     "degree": "B.A.",
     "qis_names": [
      "Erziehungswissenschaft"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5090",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2023",
       "code": "erziehungswissenschaft|b.a.|2023",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2022"
       ],
       "study_plan": null,
       "key": "hildesheim|erziehungswissenschaft|b.a.|2023",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/media/fb1/erziehungswissenschaft_allg/Info_zum_Studiengang_Erziehungswissenschaft/Modulhandbuch_fuer_den_Bachelor.pdf"
      }
     ],
     "lsf": {
      "nummer": 174,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=174&idcol=k_abstgv.abstgvnr&idval=174&purge=n&getglobal=n",
      "text": "B.A. Erziehungswissenschaft"
     },
     "lsf_names": [
      "B.A. Erziehungswissenschaft"
     ]
    },
    {
     "id": "future-analytics-ai-audio-worlds-m-sc",
     "program": "Future Analytics: AI & Audio Worlds",
     "degree": "M.Sc.",
     "qis_names": [
      "Future Analytics: AI & Audio Worlds"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": null,
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": []
    },
    {
     "id": "informationsmanagement-und-informationstechnologie-b-sc",
     "program": "Informationsmanagement und Informationstechnologie",
     "degree": "B.Sc.",
     "qis_names": [
      "Informationsmanagement und Informationstechnologie"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5067",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "informationsmanagement-und-informationstechnologie|b.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|informationsmanagement-und-informationstechnologie|b.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-IMIT_PO2023-PO2024_Stand_2024.10.24.pdf"
      }
     ],
     "lsf": {
      "nummer": 216,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=216&idcol=k_abstgv.abstgvnr&idval=216&purge=n&getglobal=n",
      "text": "B.Sc. Informationsmanagement/-technologie"
     },
     "lsf_names": [
      "B.Sc. Informationsmanagement/-technologie",
      "B.Sc. Angewandte Informatik / Studienprogramm Informationsmanagement/Informationstechnologie"
     ]
    },
    {
     "id": "informationsmanagement-und-informationstechnologie-m-sc",
     "program": "Informationsmanagement und Informationstechnologie",
     "degree": "M.Sc.",
     "qis_names": [
      "Informationsmanagement und Informationstechnologie"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5067",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "informationsmanagement-und-informationstechnologie|m.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|informationsmanagement-und-informationstechnologie|m.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-IMIT_PO2023-PO2024_Stand_2024.10.24.pdf"
      }
     ],
     "lsf": {
      "nummer": 188,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=188&idcol=k_abstgv.abstgvnr&idval=188&purge=n&getglobal=n",
      "text": "M.Sc. Informationsmanagement/-technologie"
     },
     "lsf_names": [
      "M.Sc. Informationsmanagement/-technologie",
      "M.Sc. Angewandte Informatik / Studienprogramm Informationsmanagement/Informationstechnologie"
     ]
    },
    {
     "id": "inklusive-paedagogik-und-kommunikation-m-a",
     "program": "Inklusive Pädagogik und Kommunikation",
     "degree": "M.A.",
     "qis_names": [
      "Inklusive Pädagogik und Kommunikation"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": null,
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "unbekannt",
       "code": "inklusive-paedagogik-und-kommunikation|m.a.|unbekannt",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2020"
       ],
       "study_plan": null,
       "key": "hildesheim|inklusive-paedagogik-und-kommunikation|m.a.|unbekannt",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4728"
      }
     ]
    },
    {
     "id": "internationale-fachkommunikation-sprachen-und-technik-m-a",
     "program": "Internationale Fachkommunikation - Sprachen und Technik",
     "degree": "M.A.",
     "qis_names": [
      "Internationale Fachkommunikation - Sprachen und Technik"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4784",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2020",
       "code": "internationale-fachkommunikation-sprachen-und-technik|m.a.|2020",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2020/21"
       ],
       "study_plan": null,
       "key": "hildesheim|internationale-fachkommunikation-sprachen-und-technik|m.a.|2020",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4785"
      }
     ],
     "lsf": {
      "nummer": 826,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=826&idcol=k_abstgv.abstgvnr&idval=826&purge=n&getglobal=n",
      "text": "M.A. Internationale Fachkommunikation - Sprachen u. Technik"
     },
     "lsf_names": [
      "M.A. Internationale Fachkommunikation - Sprachen u. Technik"
     ]
    },
    {
     "id": "internationale-kommunikation-und-uebersetzen-b-a",
     "program": "Internationale Kommunikation und Übersetzen",
     "degree": "B.A.",
     "qis_names": [
      "Internationale Kommunikation und Übersetzen"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5108",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "internationale-kommunikation-und-uebersetzen|b.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2023/24"
       ],
       "study_plan": null,
       "key": "hildesheim|internationale-kommunikation-und-uebersetzen|b.a.|2024",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5107"
      }
     ],
     "lsf": {
      "nummer": 896,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=896&idcol=k_abstgv.abstgvnr&idval=896&purge=n&getglobal=n",
      "text": "B.A. Internationale Kommunikation u. Übersetzen"
     },
     "lsf_names": [
      "B.A. Internationale Kommunikation u. Übersetzen"
     ]
    },
    {
     "id": "internationales-informationsmanagement-digitale-sozialwissenschaften-b-a",
     "program": "Internationales Informationsmanagement - Digitale Sozialwissenschaften",
     "degree": "B.A.",
     "qis_names": [
      "Internationales Informationsmanagement - Digitale Sozialwissenschaften"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5210",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "internationales-informationsmanagement-digitale-sozialwissenschaften|b.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|internationales-informationsmanagement-digitale-sozialwissenschaften|b.a.|2024",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5209"
      }
     ],
     "lsf": {
      "nummer": 911,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=911&idcol=k_abstgv.abstgvnr&idval=911&purge=n&getglobal=n",
      "text": "B.A. Internationales Informationsmanagement - Studienvariante Digitale Sozialwissenschaften"
     },
     "lsf_names": [
      "B.A. Internationales Informationsmanagement - Studienvariante Digitale Sozialwissenschaften"
     ]
    },
    {
     "id": "internationales-informationsmanagement-informationswissenschaft-und-interkulturelle-kommunikation-b-a",
     "program": "Internationales Informationsmanagement – Informationswissenschaft und interkulturelle Kommunikation",
     "degree": "B.A.",
     "qis_names": [
      "Internationales Informationsmanagement – Informationswissenschaft und interkulturelle Kommunikation"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5210",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "internationales-informationsmanagement-informationswissenschaft-und-interkulturelle-kommunikation|b.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|internationales-informationsmanagement-informationswissenschaft-und-interkulturelle-kommunikation|b.a.|2024",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5209"
      }
     ],
     "lsf": {
      "nummer": 992,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=992&idcol=k_abstgv.abstgvnr&idval=992&purge=n&getglobal=n",
      "text": "B.A. Internationales Informationsmanagement - Studienvariante Informationswissenschaft und Interkulturelle Kommunikation"
     },
     "lsf_names": [
      "B.A. Internationales Informationsmanagement - Studienvariante Informationswissenschaft und Interkulturelle Kommunikation"
     ]
    },
    {
     "id": "internationales-informationsmanagement-informationswissenschaft-m-a",
     "program": "Internationales Informationsmanagement – Informationswissenschaft",
     "degree": "M.A.",
     "qis_names": [
      "Internationales Informationsmanagement – Informationswissenschaft"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5153",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "internationales-informationsmanagement-informationswissenschaft|m.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2024"
       ],
       "study_plan": null,
       "key": "hildesheim|internationales-informationsmanagement-informationswissenschaft|m.a.|2024",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5154"
      }
     ],
     "lsf": {
      "nummer": 479,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=479&idcol=k_abstgv.abstgvnr&idval=479&purge=n&getglobal=n",
      "text": "M.A. Internationales Informationsmanagement - Informationswissenschaft"
     },
     "lsf_names": [
      "M.A. Internationales Informationsmanagement - Informationswissenschaft"
     ]
    },
    {
     "id": "internationales-informationsmanagement-interkulturelle-sprachwissenschaft-b-a",
     "program": "Internationales Informationsmanagement - Interkulturelle Sprachwissenschaft",
     "degree": "B.A.",
     "qis_names": [
      "Internationales Informationsmanagement - Interkulturelle Sprachwissenschaft"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5210",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "internationales-informationsmanagement-interkulturelle-sprachwissenschaft|b.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|internationales-informationsmanagement-interkulturelle-sprachwissenschaft|b.a.|2024",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5209"
      }
     ],
     "lsf": {
      "nummer": 912,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=912&idcol=k_abstgv.abstgvnr&idval=912&purge=n&getglobal=n",
      "text": "B.A. Internationales Informationsmanagement - Studienvariante Interkulturelle Sprachwissenschaft"
     },
     "lsf_names": [
      "B.A. Internationales Informationsmanagement - Studienvariante Interkulturelle Sprachwissenschaft"
     ]
    },
    {
     "id": "internationales-informationsmanagement-linguistik-b-a",
     "program": "Internationales Informationsmanagement – Linguistik",
     "degree": "B.A.",
     "qis_names": [
      "Internationales Informationsmanagement – Linguistik"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5210",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "internationales-informationsmanagement-linguistik|b.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|internationales-informationsmanagement-linguistik|b.a.|2024",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5209"
      }
     ],
     "lsf": {
      "nummer": 968,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=968&idcol=k_abstgv.abstgvnr&idval=968&purge=n&getglobal=n",
      "text": "B.A. Internationales Informationsmanagement - Studienvariante Linguistik"
     },
     "lsf_names": [
      "B.A. Internationales Informationsmanagement - Studienvariante Linguistik"
     ]
    },
    {
     "id": "internationales-informationsmanagement-sprachwissenschaft-und-interkulturelle-kommunikation-m-a",
     "program": "Internationales Informationsmanagement – Sprachwissenschaft und Interkulturelle Kommunikation",
     "degree": "M.A.",
     "qis_names": [
      "Internationales Informationsmanagement – Sprachwissenschaft und Interkulturelle Kommunikation"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5213",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "internationales-informationsmanagement-sprachwissenschaft-und-interkulturelle-kommunikation|m.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|internationales-informationsmanagement-sprachwissenschaft-und-interkulturelle-kommunikation|m.a.|2024",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5211"
      }
     ],
     "lsf": {
      "nummer": 476,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=476&idcol=k_abstgv.abstgvnr&idval=476&purge=n&getglobal=n",
      "text": "M.A. Internationales Informationsmanagement - Sprachwissenschaft und Interkulturelle Kommunikation"
     },
     "lsf_names": [
      "M.A. Internationales Informationsmanagement - Sprachwissenschaft und Interkulturelle Kommunikation"
     ]
    },
    {
     "id": "internationales-informationsmanagement-b-a",
     "program": "Internationales Informationsmanagement",
     "degree": "B.A.",
     "qis_names": [
      "Internationales Informationsmanagement"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5210",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "internationales-informationsmanagement|b.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|internationales-informationsmanagement|b.a.|2024",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5209"
      }
     ],
     "lsf": {
      "nummer": 805,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=805&idcol=k_abstgv.abstgvnr&idval=805&purge=n&getglobal=n",
      "text": "B.A. Internationales Informationsmanagement"
     },
     "lsf_names": [
      "B.A. Internationales Informationsmanagement"
     ]
    },
    {
     "id": "kuenste-und-gegenwartskulturen-transdisziplinaer-m-a",
     "program": "Künste und Gegenwartskulturen transdisziplinär",
     "degree": "M.A.",
     "qis_names": [
      "Künste und Gegenwartskulturen transdisziplinär",
      "Inszenierung der Künste und Medien"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5150",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2024",
       "code": "kuenste-und-gegenwartskulturen-transdisziplinaer|m.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2023"
       ],
       "study_plan": null,
       "key": "hildesheim|kuenste-und-gegenwartskulturen-transdisziplinaer|m.a.|2024",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5043"
      }
     ],
     "lsf": {
      "nummer": 976,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=976&idcol=k_abstgv.abstgvnr&idval=976&purge=n&getglobal=n",
      "text": "M.A. Künste und Gegenwartskulturen transdisziplinär"
     },
     "lsf_names": [
      "M.A. Künste und Gegenwartskulturen transdisziplinär"
     ]
    },
    {
     "id": "kulturvermittlung-kulturpolitik-und-transformation-im-kontext-der-kuenste-m-a",
     "program": "Kulturvermittlung, Kulturpolitik und Transformation im Kontext der Künste",
     "degree": "M.A.",
     "qis_names": [
      "Kulturvermittlung, Kulturpolitik und Transformation im Kontext der Künste",
      "Kulturvermittlung"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5150",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2024",
       "code": "kulturvermittlung-kulturpolitik-und-transformation-im-kontext-der-kuenste|m.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2023"
       ],
       "study_plan": null,
       "key": "hildesheim|kulturvermittlung-kulturpolitik-und-transformation-im-kontext-der-kuenste|m.a.|2024",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5044"
      }
     ],
     "lsf": {
      "nummer": 978,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=978&idcol=k_abstgv.abstgvnr&idval=978&purge=n&getglobal=n",
      "text": "M.A. Kulturvermittlung, Kulturpolitik und Transformation im Kontext der Künste"
     },
     "lsf_names": [
      "M.A. Kulturvermittlung, Kulturpolitik und Transformation im Kontext der Künste"
     ]
    },
    {
     "id": "kulturwissenschaften-und-kuenstlerische-praxis-b-a",
     "program": "Kulturwissenschaften und künstlerische Praxis",
     "degree": "B.A.",
     "qis_names": [
      "Kulturwissenschaften und künstlerische Praxis",
      "Kulturwissenschaften und ästhetische Praxis"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4935",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2022",
       "code": "kulturwissenschaften-und-kuenstlerische-praxis|b.a.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2023/24"
       ],
       "study_plan": null,
       "key": "hildesheim|kulturwissenschaften-und-kuenstlerische-praxis|b.a.|2022",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5109"
      }
     ],
     "lsf": {
      "nummer": 941,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=941&idcol=k_abstgv.abstgvnr&idval=941&purge=n&getglobal=n",
      "text": "B.A. Kulturwissenschaften und künstlerische Praxis"
     },
     "lsf_names": [
      "B.A. Kulturwissenschaften und künstlerische Praxis"
     ]
    },
    {
     "id": "lehramt-an-grund-haupt-und-realschulen-staatsexamen",
     "program": "Lehramt an Grund-, Haupt- und Realschulen",
     "degree": "Staatsexamen",
     "qis_names": [
      "Lehramt an Grund-, Haupt- und Realschulen"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": "fachbereichsübergreifend (Lehrerbildung)",
     "pos": []
    },
    {
     "id": "lehramt-an-grund-und-hauptschulen-m-ed",
     "program": "Lehramt an Grund- und Hauptschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Grund- und Hauptschulen"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=2380",
     "faculty": "fachbereichsübergreifend (Lehrerbildung)",
     "pos": []
    },
    {
     "id": "lehramt-an-grundschulen-m-ed",
     "program": "Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Grundschulen"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "fachbereichsübergreifend (Lehrerbildung)",
     "pos": [
      {
       "po": "2026",
       "code": "lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5320"
      }
     ]
    },
    {
     "id": "lehramt-an-haupt-und-realschulen-quereinstieg-fuer-fachbachelor-m-ed",
     "program": "Lehramt an Haupt- und Realschulen (Quereinstieg für Fachbachelor)",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Haupt- und Realschulen (Quereinstieg für Fachbachelor)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "fachbereichsübergreifend (Lehrerbildung)",
     "pos": []
    },
    {
     "id": "lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Haupt- und Realschulen"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "fachbereichsübergreifend (Lehrerbildung)",
     "pos": [
      {
       "po": "2026",
       "code": "lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5320"
      }
     ]
    },
    {
     "id": "lehramt-an-realschulen-m-ed",
     "program": "Lehramt an Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Lehramt an Realschulen"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=2381",
     "faculty": "fachbereichsübergreifend (Lehrerbildung)",
     "pos": []
    },
    {
     "id": "literarisches-schreiben-und-kulturjournalismus-b-a",
     "program": "Literarisches Schreiben und Kulturjournalismus",
     "degree": "B.A.",
     "qis_names": [
      "Literarisches Schreiben und Kulturjournalismus",
      "Kreatives Schreiben und Kulturjournalismus"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4935",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2022",
       "code": "literarisches-schreiben-und-kulturjournalismus|b.a.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2022/23"
       ],
       "study_plan": null,
       "key": "hildesheim|literarisches-schreiben-und-kulturjournalismus|b.a.|2022",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5021"
      }
     ],
     "lsf": {
      "nummer": 951,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=951&idcol=k_abstgv.abstgvnr&idval=951&purge=n&getglobal=n",
      "text": "B.A. Literarisches Schreiben und Kulturjournalismus"
     },
     "lsf_names": [
      "B.A. Literarisches Schreiben und Kulturjournalismus"
     ]
    },
    {
     "id": "literarisches-schreiben-und-lektorieren-m-a",
     "program": "Literarisches Schreiben und Lektorieren",
     "degree": "M.A.",
     "qis_names": [
      "Literarisches Schreiben und Lektorieren"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5150",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2024",
       "code": "literarisches-schreiben-und-lektorieren|m.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2023"
       ],
       "study_plan": null,
       "key": "hildesheim|literarisches-schreiben-und-lektorieren|m.a.|2024",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5045"
      }
     ],
     "lsf": {
      "nummer": 848,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=848&idcol=k_abstgv.abstgvnr&idval=848&purge=n&getglobal=n",
      "text": "M.A. Literarisches Schreiben und Lektorieren"
     },
     "lsf_names": [
      "M.A. Literarisches Schreiben und Lektorieren"
     ]
    },
    {
     "id": "medieninformatik-b-sc",
     "program": "Medieninformatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Medieninformatik"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5076",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2023",
       "code": "medieninformatik|b.sc.|2023",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|medieninformatik|b.sc.|2023",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-MINF_BSc_PO2023_Stand_2026.04.03.pdf"
      }
     ],
     "lsf": {
      "nummer": 994,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=994&idcol=k_abstgv.abstgvnr&idval=994&purge=n&getglobal=n",
      "text": "B.Sc. Angewandte Informatik / Studienprogramm Medieninformatik"
     },
     "lsf_names": [
      "B.Sc. Angewandte Informatik / Studienprogramm Medieninformatik"
     ]
    },
    {
     "id": "medientext-und-medienuebersetzung-m-a",
     "program": "Medientext und Medienübersetzung",
     "degree": "M.A.",
     "qis_names": [
      "Medientext und Medienübersetzung"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5197",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2024",
       "code": "medientext-und-medienuebersetzung|m.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|medientext-und-medienuebersetzung|m.a.|2024",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5196"
      }
     ],
     "lsf": {
      "nummer": 835,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=835&idcol=k_abstgv.abstgvnr&idval=835&purge=n&getglobal=n",
      "text": "M.A. Medientext und Medienübersetzung"
     },
     "lsf_names": [
      "M.A. Medientext und Medienübersetzung"
     ]
    },
    {
     "id": "musik-welt-kulturelle-diversitaet-in-der-musikalischen-bildung-m-a",
     "program": "musik.welt -- Kulturelle Diversität in der musikalischen Bildung",
     "degree": "M.A.",
     "qis_names": [
      "musik.welt -- Kulturelle Diversität in der musikalischen Bildung"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4610",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2018",
       "code": "musik-welt-kulturelle-diversitaet-in-der-musikalischen-bildung|m.a.|2018",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2017/18"
       ],
       "study_plan": null,
       "key": "hildesheim|musik-welt-kulturelle-diversitaet-in-der-musikalischen-bildung|m.a.|2018",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4607"
      }
     ]
    },
    {
     "id": "organization-studies-m-a",
     "program": "Organization Studies",
     "degree": "M.A.",
     "qis_names": [
      "Organization Studies"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4567",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": []
    },
    {
     "id": "philosophie-kuenste-medien-b-a",
     "program": "Philosophie – Künste – Medien",
     "degree": "B.A.",
     "qis_names": [
      "Philosophie – Künste – Medien"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4935",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2022",
       "code": "philosophie-kuenste-medien|b.a.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "hildesheim|philosophie-kuenste-medien|b.a.|2022",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5359"
      }
     ],
     "lsf": {
      "nummer": 175,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=175&idcol=k_abstgv.abstgvnr&idval=175&purge=n&getglobal=n",
      "text": "B.A. Philosophie - Künste - Medien"
     },
     "lsf_names": [
      "B.A. Philosophie - Künste - Medien"
     ]
    },
    {
     "id": "philosophie-und-kuenste-interkulturell-m-a",
     "program": "Philosophie und Künste interkulturell",
     "degree": "M.A.",
     "qis_names": [
      "Philosophie und Künste interkulturell"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5150",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2024",
       "code": "philosophie-und-kuenste-interkulturell|m.a.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2020"
       ],
       "study_plan": null,
       "key": "hildesheim|philosophie-und-kuenste-interkulturell|m.a.|2024",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4717"
      }
     ],
     "lsf": {
      "nummer": 729,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=729&idcol=k_abstgv.abstgvnr&idval=729&purge=n&getglobal=n",
      "text": "M.A. Philosophie und Künste interkulturell"
     },
     "lsf_names": [
      "M.A. Philosophie und Künste interkulturell"
     ]
    },
    {
     "id": "polyvalenter-zwei-faecher-bachelor-studiengang-b-a",
     "program": "Polyvalenter Zwei-Fächer-Bachelor-Studiengang",
     "degree": "B.A.",
     "qis_names": [
      "Polyvalenter Zwei-Fächer-Bachelor-Studiengang",
      "Polyvalenter Zwei-Fächer- -Studiengang"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "fachbereichsübergreifend (Lehrerbildung)",
     "pos": [
      {
       "po": "2026",
       "code": "polyvalenter-zwei-faecher-bachelor-studiengang|b.a.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|polyvalenter-zwei-faecher-bachelor-studiengang|b.a.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5317"
      }
     ]
    },
    {
     "id": "polyvalenter-zwei-faecher-bachelor-studiengang-b-sc",
     "program": "Polyvalenter Zwei-Fächer-Bachelor-Studiengang",
     "degree": "B.Sc.",
     "qis_names": [
      "Polyvalenter Zwei-Fächer-Bachelor-Studiengang",
      "Polyvalenter Zwei-Fächer- -Studiengang"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5319",
     "faculty": "fachbereichsübergreifend (Lehrerbildung)",
     "pos": [
      {
       "po": "2026",
       "code": "polyvalenter-zwei-faecher-bachelor-studiengang|b.sc.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|polyvalenter-zwei-faecher-bachelor-studiengang|b.sc.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5317"
      }
     ]
    },
    {
     "id": "psychologie-mit-dem-schwerpunkt-klinische-psychologie-und-psychotherapie-m-sc",
     "program": "Psychologie mit dem Schwerpunkt Klinische Psychologie und Psychotherapie",
     "degree": "M.Sc.",
     "qis_names": [
      "Psychologie mit dem Schwerpunkt Klinische Psychologie und Psychotherapie"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4844",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "psychologie-mit-dem-schwerpunkt-klinische-psychologie-und-psychotherapie|m.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|psychologie-mit-dem-schwerpunkt-klinische-psychologie-und-psychotherapie|m.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5282"
      }
     ],
     "lsf": {
      "nummer": 929,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=929&idcol=k_abstgv.abstgvnr&idval=929&purge=n&getglobal=n",
      "text": "M.Sc. Psychologie mit Schwerpunkt Klinische Psychologie und Psychotherapie"
     },
     "lsf_names": [
      "M.Sc. Psychologie mit Schwerpunkt Klinische Psychologie und Psychotherapie"
     ]
    },
    {
     "id": "psychologie-mit-schwerpunkt-paedagogische-psychologie-b-sc",
     "program": "Psychologie mit Schwerpunkt Pädagogische Psychologie",
     "degree": "B.Sc.",
     "qis_names": [
      "Psychologie mit Schwerpunkt Pädagogische Psychologie"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4019",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": []
    },
    {
     "id": "psychologie-b-sc",
     "program": "Psychologie",
     "degree": "B.Sc.",
     "qis_names": [
      "Psychologie"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4825",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "psychologie|b.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|psychologie|b.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5281"
      }
     ],
     "lsf": {
      "nummer": 894,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=894&idcol=k_abstgv.abstgvnr&idval=894&purge=n&getglobal=n",
      "text": "B.Sc. Psychologie"
     },
     "lsf_names": [
      "B.Sc. Psychologie"
     ]
    },
    {
     "id": "psychologie-m-sc",
     "program": "Psychologie",
     "degree": "M.Sc.",
     "qis_names": [
      "Psychologie"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4843",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "psychologie|m.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|psychologie|m.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5283"
      }
     ],
     "lsf": {
      "nummer": 723,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=723&idcol=k_abstgv.abstgvnr&idval=723&purge=n&getglobal=n",
      "text": "M.Sc. Psychologie"
     },
     "lsf_names": [
      "M.Sc. Psychologie"
     ]
    },
    {
     "id": "rechtspsychologie-m-sc",
     "program": "Rechtspsychologie",
     "degree": "M.Sc.",
     "qis_names": [
      "Rechtspsychologie"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4982",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": []
    },
    {
     "id": "software-engineering-m-sc",
     "program": "Software Engineering",
     "degree": "M.Sc.",
     "qis_names": [
      "Software Engineering"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5132",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "software-engineering|m.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2023/24"
       ],
       "study_plan": null,
       "key": "hildesheim|software-engineering|m.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5146"
      }
     ],
     "lsf": {
      "nummer": 1002,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=1002&idcol=k_abstgv.abstgvnr&idval=1002&purge=n&getglobal=n",
      "text": "M.Sc. Software Engineering"
     },
     "lsf_names": [
      "M.Sc. Software Engineering"
     ]
    },
    {
     "id": "sozial-und-organisationspaedagogik-m-a",
     "program": "Sozial- und Organisationspädagogik",
     "degree": "M.A.",
     "qis_names": [
      "Sozial- und Organisationspädagogik"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5274",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2025",
       "code": "sozial-und-organisationspaedagogik|m.a.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|sozial-und-organisationspaedagogik|m.a.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5275"
      }
     ],
     "lsf": {
      "nummer": 717,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=717&idcol=k_abstgv.abstgvnr&idval=717&purge=n&getglobal=n",
      "text": "M.A. Sozial- und Organisationspädagogik"
     },
     "lsf_names": [
      "M.A. Sozial- und Organisationspädagogik"
     ]
    },
    {
     "id": "soziale-dienste-m-a",
     "program": "Soziale Dienste",
     "degree": "M.A.",
     "qis_names": [
      "Soziale Dienste"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5276",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2025",
       "code": "soziale-dienste|m.a.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|soziale-dienste|m.a.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5277"
      }
     ],
     "lsf": {
      "nummer": 862,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=862&idcol=k_abstgv.abstgvnr&idval=862&purge=n&getglobal=n",
      "text": "M.A. Soziale Dienste"
     },
     "lsf_names": [
      "M.A. Soziale Dienste"
     ]
    },
    {
     "id": "sozialpaedagogik-b-a",
     "program": "Sozialpädagogik",
     "degree": "B.A.",
     "qis_names": [
      "Sozialpädagogik"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5272",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2025",
       "code": "sozialpaedagogik|b.a.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|sozialpaedagogik|b.a.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5273"
      }
     ],
     "lsf": {
      "nummer": 1008,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=1008&idcol=k_abstgv.abstgvnr&idval=1008&purge=n&getglobal=n",
      "text": "B.A. Sozialpädagogik"
     },
     "lsf_names": [
      "B.A. Sozialpädagogik"
     ]
    },
    {
     "id": "sportwissenschaft-mit-dem-schwerpunkt-sport-gesundheit-und-leistung-in-der-lebensspanne-m-sc",
     "program": "Sportwissenschaft mit dem Schwerpunkt Sport, Gesundheit und Leistung in der Lebensspanne",
     "degree": "M.Sc.",
     "qis_names": [
      "Sportwissenschaft mit dem Schwerpunkt Sport, Gesundheit und Leistung in der Lebensspanne"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4856",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "sportwissenschaft-mit-dem-schwerpunkt-sport-gesundheit-und-leistung-in-der-lebensspanne|m.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|sportwissenschaft-mit-dem-schwerpunkt-sport-gesundheit-und-leistung-in-der-lebensspanne|m.sc.|2021",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4855"
      }
     ],
     "lsf": {
      "nummer": 721,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=721&idcol=k_abstgv.abstgvnr&idval=721&purge=n&getglobal=n",
      "text": "M.Sc. Sportwissenschaft mit dem Schwerpunkt Sport, Gesundheit und Leistung in der Lebensspanne"
     },
     "lsf_names": [
      "M.Sc. Sportwissenschaft mit dem Schwerpunkt Sport, Gesundheit und Leistung in der Lebensspanne"
     ]
    },
    {
     "id": "szenische-kuenste-b-a",
     "program": "Szenische Künste",
     "degree": "B.A.",
     "qis_names": [
      "Szenische Künste"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4935",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2022",
       "code": "szenische-kuenste|b.a.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2022/23"
       ],
       "study_plan": null,
       "key": "hildesheim|szenische-kuenste|b.a.|2022",
       "format": "hildesheim-modultabelle",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5019"
      }
     ],
     "lsf": {
      "nummer": 202,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=202&idcol=k_abstgv.abstgvnr&idval=202&purge=n&getglobal=n",
      "text": "B.A. Szenische Künste"
     },
     "lsf_names": [
      "B.A. Szenische Künste"
     ]
    },
    {
     "id": "umwelt-naturschutz-und-nachhaltigkeit-m-sc",
     "program": "Umwelt, Naturschutz und Nachhaltigkeit",
     "degree": "M.Sc.",
     "qis_names": [
      "Umwelt, Naturschutz und Nachhaltigkeit"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4862",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2021",
       "code": "umwelt-naturschutz-und-nachhaltigkeit|m.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|umwelt-naturschutz-und-nachhaltigkeit|m.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4853"
      }
     ],
     "lsf": {
      "nummer": 913,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=913&idcol=k_abstgv.abstgvnr&idval=913&purge=n&getglobal=n",
      "text": "M.Sc. Umwelt, Naturschutz und Nachhaltigkeit"
     },
     "lsf_names": [
      "M.Sc. Umwelt, Naturschutz und Nachhaltigkeit"
     ]
    },
    {
     "id": "umweltinformatik-b-sc",
     "program": "Umweltinformatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Umweltinformatik"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5076",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "umweltinformatik|b.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|umweltinformatik|b.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-UINF_PO2023-PO2024_Stand_2024.10.24.pdf"
      }
     ],
     "lsf": {
      "nummer": 995,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=995&idcol=k_abstgv.abstgvnr&idval=995&purge=n&getglobal=n",
      "text": "B.Sc. Angewandte Informatik / Studienprogramm Umweltinformatik"
     },
     "lsf_names": [
      "B.Sc. Angewandte Informatik / Studienprogramm Umweltinformatik"
     ]
    },
    {
     "id": "umweltinformatik-m-sc",
     "program": "Umweltinformatik",
     "degree": "M.Sc.",
     "qis_names": [
      "Umweltinformatik"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5132",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "umweltinformatik|m.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|umweltinformatik|m.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-UINF_PO2023-PO2024_Stand_2024.10.24.pdf"
      }
     ],
     "lsf": {
      "nummer": 998,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=998&idcol=k_abstgv.abstgvnr&idval=998&purge=n&getglobal=n",
      "text": "M.Sc. Angewandte Informatik / Studienprogramm Umweltinformatik"
     },
     "lsf_names": [
      "M.Sc. Angewandte Informatik / Studienprogramm Umweltinformatik"
     ]
    },
    {
     "id": "umweltwissenschaft-und-naturschutz-m-sc",
     "program": "Umweltwissenschaft und Naturschutz",
     "degree": "M.Sc.",
     "qis_names": [
      "Umweltwissenschaft und Naturschutz"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=3908",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2011",
       "code": "umweltwissenschaft-und-naturschutz|m.sc.|2011",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2011"
       ],
       "study_plan": null,
       "key": "hildesheim|umweltwissenschaft-und-naturschutz|m.sc.|2011",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=3909"
      }
     ]
    },
    {
     "id": "wirtschaftsinformatik-b-sc",
     "program": "Wirtschaftsinformatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Wirtschaftsinformatik"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5068",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "wirtschaftsinformatik|b.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|wirtschaftsinformatik|b.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-AI_PO2023-PO2024_Stand_2026.04.03.pdf"
      }
     ],
     "lsf": {
      "nummer": 781,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=781&idcol=k_abstgv.abstgvnr&idval=781&purge=n&getglobal=n",
      "text": "B.Sc. Wirtschaftsinformatik"
     },
     "lsf_names": [
      "B.Sc. Wirtschaftsinformatik"
     ]
    },
    {
     "id": "wirtschaftsinformatik-m-sc",
     "program": "Wirtschaftsinformatik",
     "degree": "M.Sc.",
     "qis_names": [
      "Wirtschaftsinformatik"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5073",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "wirtschaftsinformatik|m.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|wirtschaftsinformatik|m.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/media/fb4/dekanat/Ordnungen/AINF/PO2023-PO2024/MHB/Modulhandbuch_AI-AI_PO2023-PO2024_Stand_2026.04.03.pdf"
      }
     ],
     "lsf": {
      "nummer": 816,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=816&idcol=k_abstgv.abstgvnr&idval=816&purge=n&getglobal=n",
      "text": "M.Sc. Wirtschaftsinformatik"
     },
     "lsf_names": [
      "M.Sc. Wirtschaftsinformatik"
     ]
    },
    {
     "id": "data-analytics-advanced-track-m-sc",
     "program": "Data Analytics (Advanced Track)",
     "degree": "M.Sc.",
     "qis_names": [
      "Data Analytics (Advanced Track)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5132",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "data-analytics-advanced-track|m.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2023/24"
       ],
       "study_plan": null,
       "key": "hildesheim|data-analytics-advanced-track|m.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5144"
      }
     ],
     "lsf": {
      "nummer": 1003,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=1003&idcol=k_abstgv.abstgvnr&idval=1003&purge=n&getglobal=n",
      "text": "M.Sc. Data Analytics / Advanced Track"
     },
     "lsf_names": [
      "M.Sc. Data Analytics / Advanced Track"
     ]
    },
    {
     "id": "data-analytics-cognitive-systems-m-sc",
     "program": "Data Analytics (Cognitive Systems)",
     "degree": "M.Sc.",
     "qis_names": [
      "Data Analytics (Cognitive Systems)"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5132",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2024",
       "code": "data-analytics-cognitive-systems|m.sc.|2024",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2023/24"
       ],
       "study_plan": null,
       "key": "hildesheim|data-analytics-cognitive-systems|m.sc.|2024",
       "format": "hildesheim-it-modulhandbuch",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5145"
      }
     ]
    },
    {
     "id": "english-applied-linguistics-b-a",
     "program": "English Applied Linguistics",
     "degree": "B.A.",
     "qis_names": [
      "English Applied Linguistics"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "english-applied-linguistics|b.a.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|english-applied-linguistics|b.a.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5259"
      }
     ],
     "lsf": {
      "nummer": 258,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=258&idcol=k_abstgv.abstgvnr&idval=258&purge=n&getglobal=n",
      "text": "Polyvalenter Zwei-Fächer-Bachelor (Engl. Appl. Ling.)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Englisch (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Englisch (Engl. Appl. Ling.)",
      "Polyvalenter Zwei-Fächer-Bachelor (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Englisch (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Englisch (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Englisch (Wahlpflichtbereich) (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Englisch (Ergänzungsfach) (Umweltsicherung)",
      "Hauptfach im 2-Fächer-Bachelor: Englisch (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Englisch (Wirtschaft Plus)"
     ]
    },
    {
     "id": "sport-gesundheit-und-leistung-b-a",
     "program": "Sport, Gesundheit und Leistung",
     "degree": "B.A.",
     "qis_names": [
      "Sport, Gesundheit und Leistung"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "sport-gesundheit-und-leistung|b.a.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2023/24"
       ],
       "study_plan": null,
       "key": "hildesheim|sport-gesundheit-und-leistung|b.a.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5131"
      }
     ],
     "lsf": {
      "nummer": 534,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=534&idcol=k_abstgv.abstgvnr&idval=534&purge=n&getglobal=n",
      "text": "Polyvalenter Zwei-Fächer-Bachelor Sport, Gesundheit und Leistung"
     },
     "lsf_names": [
      "Polyvalenter Zwei-Fächer-Bachelor Sport, Gesundheit und Leistung"
     ]
    },
    {
     "id": "umweltsicherung-b-sc",
     "program": "Umweltsicherung",
     "degree": "B.Sc.",
     "qis_names": [
      "Umweltsicherung"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5319",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "umweltsicherung|b.sc.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|umweltsicherung|b.sc.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5261"
      }
     ],
     "lsf": {
      "nummer": 285,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=285&idcol=k_abstgv.abstgvnr&idval=285&purge=n&getglobal=n",
      "text": "Polyvalenter Zwei-Fächer-Bachelor (Umweltsicherung)"
     },
     "lsf_names": [
      "Polyvalenter Zwei-Fächer-Bachelor (Umweltsicherung)",
      "Hauptfach im 2-Fächer-Bachelor: Vertiefungsbereich Umweltsicherung (Umweltsicherung)"
     ]
    },
    {
     "id": "wirtschaft-plus-b-sc",
     "program": "Wirtschaft Plus",
     "degree": "B.Sc.",
     "qis_names": [
      "Wirtschaft Plus"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5319",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "wirtschaft-plus|b.sc.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2019"
       ],
       "study_plan": null,
       "key": "hildesheim|wirtschaft-plus|b.sc.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4671"
      }
     ],
     "lsf": {
      "nummer": 866,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=866&idcol=k_abstgv.abstgvnr&idval=866&purge=n&getglobal=n",
      "text": "Wirtschaft Vertiefung (Wirtschaft Plus)"
     },
     "lsf_names": [
      "Wirtschaft Vertiefung (Wirtschaft Plus)"
     ]
    },
    {
     "id": "biologie-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Biologie im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Biologie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "biologie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|biologie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5340"
      }
     ],
     "lsf": {
      "nummer": 741,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=741&idcol=k_abstgv.abstgvnr&idval=741&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Biologie (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Biologie (HS)",
      "Hauptfach im M.Ed.: Biologie (RS)"
     ]
    },
    {
     "id": "biologie-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Biologie im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Biologie"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2025",
       "code": "biologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|biologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5269"
      }
     ],
     "lsf": {
      "nummer": 4,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=4&idcol=k_abstgv.abstgvnr&idval=4&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Biologie (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Biologie (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie (Umweltsicherung)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Biologie (Drittfach) (Umweltsicherung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Biologie (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie mit Vertiefung (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Biologie (Ergänzungsfach) (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie (Wirtschaft Plus)"
     ]
    },
    {
     "id": "chemie-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Chemie im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Chemie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "chemie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|chemie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5341"
      }
     ],
     "lsf": {
      "nummer": 742,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=742&idcol=k_abstgv.abstgvnr&idval=742&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Chemie (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Chemie (HS)",
      "Hauptfach im M.Ed.: Chemie (RS)"
     ]
    },
    {
     "id": "chemie-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Chemie im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Chemie"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2025",
       "code": "chemie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|chemie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5271"
      }
     ],
     "lsf": {
      "nummer": 5,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=5&idcol=k_abstgv.abstgvnr&idval=5&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Chemie (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Chemie (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Chemie (Drittfach) (Umweltsicherung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Chemie (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie (Wirtschaft Plus)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie (Umweltsicherung)"
     ]
    },
    {
     "id": "deutsch-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Deutsch im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Deutsch"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "deutsch-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|deutsch-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5339"
      }
     ],
     "lsf": {
      "nummer": 732,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=732&idcol=k_abstgv.abstgvnr&idval=732&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Deutsch (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Deutsch (GS)"
     ]
    },
    {
     "id": "deutsch-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Deutsch im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Deutsch"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "deutsch-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|deutsch-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5339"
      }
     ],
     "lsf": {
      "nummer": 745,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=745&idcol=k_abstgv.abstgvnr&idval=745&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Deutsch (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Deutsch (HS)",
      "Hauptfach im M.Ed.: Deutsch (RS)"
     ]
    },
    {
     "id": "deutsch-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Deutsch im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Deutsch"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2022",
       "code": "deutsch-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2022"
       ],
       "study_plan": null,
       "key": "hildesheim|deutsch-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5186"
      }
     ],
     "lsf": {
      "nummer": 8,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=8&idcol=k_abstgv.abstgvnr&idval=8&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Deutsch (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Deutsch (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Deutsch (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Deutsch (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Deutsch (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Deutsch (Wirtschaft Plus)"
     ]
    },
    {
     "id": "englisch-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Englisch im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Englisch"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2025",
       "code": "englisch-im-master-lehramt-an-grundschulen|m.ed.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|englisch-im-master-lehramt-an-grundschulen|m.ed.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5218"
      }
     ],
     "lsf": {
      "nummer": 730,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=730&idcol=k_abstgv.abstgvnr&idval=730&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Englisch (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Englisch (GS)"
     ]
    },
    {
     "id": "englisch-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Englisch im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Englisch"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2025",
       "code": "englisch-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|englisch-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5218"
      }
     ],
     "lsf": {
      "nummer": 739,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=739&idcol=k_abstgv.abstgvnr&idval=739&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Englisch (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Englisch (HS)",
      "Hauptfach im M.Ed.: Englisch (RS)"
     ]
    },
    {
     "id": "englisch-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Englisch im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Englisch"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 3 – Sprach- und Informationswissenschaften",
     "pos": [
      {
       "po": "2025",
       "code": "englisch-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hildesheim|englisch-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5259"
      }
     ]
    },
    {
     "id": "evangelische-theologie-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Evangelische Theologie im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Evangelische Theologie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "evangelische-theologie-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|evangelische-theologie-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5325"
      }
     ],
     "lsf": {
      "nummer": 731,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=731&idcol=k_abstgv.abstgvnr&idval=731&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Evangelische Religion (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Evangelische Religion (GS)"
     ]
    },
    {
     "id": "evangelische-theologie-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Evangelische Theologie im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Evangelische Theologie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "evangelische-theologie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|evangelische-theologie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5325"
      }
     ],
     "lsf": {
      "nummer": 744,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=744&idcol=k_abstgv.abstgvnr&idval=744&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Evangelische Religion (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Evangelische Religion (HS)",
      "Hauptfach im M.Ed.: Evangelische Religion (RS)"
     ]
    },
    {
     "id": "evangelische-theologie-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Evangelische Theologie im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Evangelische Theologie"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "evangelische-theologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|evangelische-theologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4875"
      }
     ],
     "lsf": {
      "nummer": 7,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=7&idcol=k_abstgv.abstgvnr&idval=7&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Evangelische Theologie (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Evangelische Theologie (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Evangelische Theologie (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Evangelische Theologie (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Evangelische Theologie (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Evangelische Theologie (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Evangelische Theologie (Wirtschaft Plus)"
     ]
    },
    {
     "id": "geographie-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Geographie im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Geographie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "geographie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2017",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2016/17"
       ],
       "study_plan": null,
       "key": "hildesheim|geographie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2017",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4538"
      },
      {
       "po": "2026",
       "code": "geographie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|geographie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5342"
      }
     ]
    },
    {
     "id": "geographie-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Geographie im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Geographie"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2025",
       "code": "geographie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|geographie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5270"
      }
     ],
     "lsf": {
      "nummer": 6,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=6&idcol=k_abstgv.abstgvnr&idval=6&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Geographie (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Geographie (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie (Umweltsicherung)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Geographie (Drittfach) (Umweltsicherung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Geographie (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie mit Vertiefung (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie (Wirtschaft Plus)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Geographie (Ergänzungsfach) (Engl. Appl. Ling.)"
     ]
    },
    {
     "id": "geschichte-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Geschichte im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Geschichte"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "geschichte-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|geschichte-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5326"
      }
     ],
     "lsf": {
      "nummer": 746,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=746&idcol=k_abstgv.abstgvnr&idval=746&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Geschichte (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Geschichte (HS)",
      "Hauptfach im M.Ed.: Geschichte (RS)"
     ]
    },
    {
     "id": "geschichte-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Geschichte im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Geschichte"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "geschichte-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|geschichte-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4900"
      }
     ],
     "lsf": {
      "nummer": 9,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=9&idcol=k_abstgv.abstgvnr&idval=9&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Geschichte (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Geschichte (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Geschichte (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Geschichte (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Geschichte (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Geschichte (Ergänzungsfach) (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Geschichte (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Geschichte (Wirtschaft Plus)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Geschichte (Ergänzungsfach) (Umweltsicherung)"
     ]
    },
    {
     "id": "katholische-theologie-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Katholische Theologie im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Katholische Theologie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "katholische-theologie-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|katholische-theologie-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5327"
      }
     ],
     "lsf": {
      "nummer": 733,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=733&idcol=k_abstgv.abstgvnr&idval=733&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Katholische Religion (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Katholische Religion (GS)"
     ]
    },
    {
     "id": "katholische-theologie-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Katholische Theologie im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Katholische Theologie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "katholische-theologie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|katholische-theologie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5327"
      }
     ],
     "lsf": {
      "nummer": 747,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=747&idcol=k_abstgv.abstgvnr&idval=747&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Katholische Religion (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Katholische Religion (HS)",
      "Hauptfach im M.Ed.: Katholische Religion (RS)"
     ]
    },
    {
     "id": "katholische-theologie-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Katholische Theologie im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Katholische Theologie"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2022",
       "code": "katholische-theologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2022"
       ],
       "study_plan": null,
       "key": "hildesheim|katholische-theologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4958"
      }
     ],
     "lsf": {
      "nummer": 10,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=10&idcol=k_abstgv.abstgvnr&idval=10&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Katholische Theologie (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Katholische Theologie (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Katholische Theologie (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Katholische Theologie (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Katholische Theologie (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Katholische Theologie (Sport, Gesundheit und Leistung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Katholische Theologie (Ergänzungsfach) (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Katholische Theologie (Wirtschaft Plus)"
     ]
    },
    {
     "id": "kunst-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Kunst im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Kunst"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2026",
       "code": "kunst-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|kunst-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5332"
      }
     ],
     "lsf": {
      "nummer": 734,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=734&idcol=k_abstgv.abstgvnr&idval=734&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Kunst (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Kunst (GS)"
     ]
    },
    {
     "id": "kunst-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Kunst im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Kunst"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2026",
       "code": "kunst-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|kunst-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5332"
      }
     ],
     "lsf": {
      "nummer": 748,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=748&idcol=k_abstgv.abstgvnr&idval=748&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Kunst (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Kunst (HS)",
      "Hauptfach im M.Ed.: Kunst (RS)"
     ]
    },
    {
     "id": "kunst-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Kunst im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Kunst"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2022",
       "code": "kunst-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2022/23"
       ],
       "study_plan": null,
       "key": "hildesheim|kunst-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5007"
      }
     ],
     "lsf": {
      "nummer": 11,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=11&idcol=k_abstgv.abstgvnr&idval=11&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Kunst (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Kunst (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Kunst (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Kunst (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Kunst (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Kunst (Sport, Gesundheit und Leistung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Kunst (Ergänzungsfach) (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Kunst (Wirtschaft Plus)"
     ]
    },
    {
     "id": "mathematik-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Mathematik im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Mathematik"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "mathematik-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|mathematik-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5344"
      }
     ],
     "lsf": {
      "nummer": 736,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=736&idcol=k_abstgv.abstgvnr&idval=736&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Mathematik (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Mathematik (GS)"
     ]
    },
    {
     "id": "mathematik-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Mathematik im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Mathematik"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "mathematik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|mathematik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5344"
      }
     ],
     "lsf": {
      "nummer": 750,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=750&idcol=k_abstgv.abstgvnr&idval=750&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Mathematik (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Mathematik (HS)",
      "Hauptfach im M.Ed.: Mathematik (RS)"
     ]
    },
    {
     "id": "mathematik-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Mathematik im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Mathematik"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2014",
       "code": "mathematik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2014",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2014"
       ],
       "study_plan": null,
       "key": "hildesheim|mathematik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2014",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4208"
      },
      {
       "po": "2025",
       "code": "mathematik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hildesheim|mathematik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5268"
      }
     ]
    },
    {
     "id": "musik-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Musik im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Musik"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2026",
       "code": "musik-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|musik-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5333"
      }
     ],
     "lsf": {
      "nummer": 737,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=737&idcol=k_abstgv.abstgvnr&idval=737&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Musik (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Musik (GS)"
     ]
    },
    {
     "id": "musik-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Musik im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Musik"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2026",
       "code": "musik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|musik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5333"
      }
     ],
     "lsf": {
      "nummer": 751,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=751&idcol=k_abstgv.abstgvnr&idval=751&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Musik (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Musik (HS)",
      "Hauptfach im M.Ed.: Musik (RS)"
     ]
    },
    {
     "id": "musik-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Musik im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Musik"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2014",
       "code": "musik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2014",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2014"
       ],
       "study_plan": null,
       "key": "hildesheim|musik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2014",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4257"
      }
     ],
     "lsf": {
      "nummer": 14,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=14&idcol=k_abstgv.abstgvnr&idval=14&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Musik (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Musik (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Musik (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Musik (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Musik (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Musik (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Musik (Wirtschaft Plus)"
     ]
    },
    {
     "id": "paedagogik-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Pädagogik im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Pädagogik"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "paedagogik-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|paedagogik-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5330"
      }
     ]
    },
    {
     "id": "paedagogik-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Pädagogik im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Pädagogik"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "paedagogik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|paedagogik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5330"
      }
     ]
    },
    {
     "id": "paedagogik-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Pädagogik im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Pädagogik"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "paedagogik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|paedagogik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4858"
      }
     ],
     "lsf": {
      "nummer": 464,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=464&idcol=k_abstgv.abstgvnr&idval=464&purge=n&getglobal=n",
      "text": "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Pädagogik (Ergänzungsfach) (Umweltsicherung)"
     },
     "lsf_names": [
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Pädagogik (Ergänzungsfach) (Umweltsicherung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Pädagogik (Ergänzungsfach) (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Pädagogik (Ergänzungsfach) (Engl. Appl. Ling.)"
     ]
    },
    {
     "id": "philosophie-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Philosophie im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Philosophie"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
     "pos": [
      {
       "po": "2026",
       "code": "philosophie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|philosophie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5338"
      }
     ],
     "lsf": {
      "nummer": 15,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=15&idcol=k_abstgv.abstgvnr&idval=15&purge=n&getglobal=n",
      "text": "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Philosophie (Wahlpflichtfach) (Lehramt)"
     },
     "lsf_names": [
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Philosophie (Wahlpflichtfach) (Lehramt)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Philosophie (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Philosophie (Ergänzungsfach) (Engl. Appl. Ling.)"
     ]
    },
    {
     "id": "physik-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Physik im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Physik"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2017",
       "code": "physik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2017",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2016/17"
       ],
       "study_plan": null,
       "key": "hildesheim|physik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2017",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4539"
      },
      {
       "po": "2026",
       "code": "physik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|physik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5345"
      }
     ]
    },
    {
     "id": "physik-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Physik im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Physik"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2022",
       "code": "physik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "WS 2022/23"
       ],
       "study_plan": null,
       "key": "hildesheim|physik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5092"
      }
     ],
     "lsf": {
      "nummer": 16,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=16&idcol=k_abstgv.abstgvnr&idval=16&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Physik (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Physik (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Physik (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Physik (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Physik (Ergänzungsfach) (Umweltsicherung)",
      "Hauptfach im 2-Fächer-Bachelor: Physik (Sport, Gesundheit und Leistung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Physik (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Physik (Wirtschaft Plus)"
     ]
    },
    {
     "id": "politikwissenschaft-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Politikwissenschaft im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Politikwissenschaft"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "politikwissenschaft-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|politikwissenschaft-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5328"
      }
     ],
     "lsf": {
      "nummer": 753,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=753&idcol=k_abstgv.abstgvnr&idval=753&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Politikwissenschaft (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Politikwissenschaft (HS)",
      "Hauptfach im M.Ed.: Politikwissenschaft (RS)"
     ]
    },
    {
     "id": "politikwissenschaft-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Politikwissenschaft im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Politikwissenschaft"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "politikwissenschaft-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|politikwissenschaft-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5335"
      }
     ],
     "lsf": {
      "nummer": 17,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=17&idcol=k_abstgv.abstgvnr&idval=17&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Politikwissenschaft (Wahlpflichtfach) (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Politikwissenschaft (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Politikwissenschaft (Ergänzungsfach) (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft (Sport, Gesundheit und Leistung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Politikwissenschaft (Ergänzungsfach) (Umweltsicherung)",
      "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft (Wirtschaft Plus)"
     ]
    },
    {
     "id": "psychologie-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Psychologie im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Psychologie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "psychologie-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|psychologie-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5329"
      }
     ]
    },
    {
     "id": "psychologie-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Psychologie im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Psychologie"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "psychologie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|psychologie-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5329"
      }
     ]
    },
    {
     "id": "psychologie-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Psychologie im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Psychologie"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "psychologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|psychologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4895"
      }
     ],
     "lsf": {
      "nummer": 560,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=560&idcol=k_abstgv.abstgvnr&idval=560&purge=n&getglobal=n",
      "text": "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Psychologie (Ergänzungsfach) (Umweltsicherung)"
     },
     "lsf_names": [
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Psychologie (Ergänzungsfach) (Umweltsicherung)"
     ]
    },
    {
     "id": "sachunterricht-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Sachunterricht im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Sachunterricht"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "sachunterricht-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|sachunterricht-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5334"
      }
     ],
     "lsf": {
      "nummer": 738,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=738&idcol=k_abstgv.abstgvnr&idval=738&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Sachunterricht (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Sachunterricht (GS)"
     ]
    },
    {
     "id": "sachunterricht-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Sachunterricht im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Sachunterricht"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2021",
       "code": "sachunterricht-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|sachunterricht-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4941"
      }
     ],
     "lsf": {
      "nummer": 20,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=20&idcol=k_abstgv.abstgvnr&idval=20&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Wirtschaft und Sachunterricht (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Wirtschaft und Sachunterricht (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie und Sachunterricht (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Physik und Sachunterricht (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft und Sachunterricht (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie und Sachunterricht (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie und Sachunterricht (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Geschichte und Sachunterricht (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Technik und Sachunterricht (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Wirtschaft und Sachunterricht (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie und Sachunterricht (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Physik und Sachunterricht (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft und Sachunterricht (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie und Sachunterricht (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie und Sachunterricht (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Geschichte und Sachunterricht (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Technik und Sachunterricht (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie und Sachunterricht (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie und Sachunterricht (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Biologie und Sachunterricht (Wirtschaft Plus)",
      "Hauptfach im 2-Fächer-Bachelor: Physik und Sachunterricht (Wirtschaft Plus)",
      "Hauptfach im 2-Fächer-Bachelor: Politikwissenschaft und Sachunterricht (Wirtschaft Plus)",
      "Hauptfach im 2-Fächer-Bachelor: Chemie und Sachunterricht (Wirtschaft Plus)",
      "Hauptfach im 2-Fächer-Bachelor: Geographie und Sachunterricht (Wirtschaft Plus)",
      "Hauptfach im 2-Fächer-Bachelor: Geschichte und Sachunterricht (Wirtschaft Plus)",
      "Hauptfach im 2-Fächer-Bachelor: Technik und Sachunterricht (Wirtschaft Plus)"
     ]
    },
    {
     "id": "soziologie-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Soziologie im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Soziologie"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "soziologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|soziologie-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5336"
      }
     ],
     "lsf": {
      "nummer": 192,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=192&idcol=k_abstgv.abstgvnr&idval=192&purge=n&getglobal=n",
      "text": "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Soziologie (Wahlpflichtfach) (Lehramt)"
     },
     "lsf_names": [
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Soziologie (Wahlpflichtfach) (Lehramt)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Soziologie (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Soziologie (Ergänzungsfach) (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Soziologie (Ergänzungsfach) (Umweltsicherung)"
     ]
    },
    {
     "id": "sport-im-master-lehramt-an-grundschulen-m-ed",
     "program": "Sport im Master Lehramt an Grundschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Sport"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5321",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "sport-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|sport-im-master-lehramt-an-grundschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5331"
      }
     ],
     "lsf": {
      "nummer": 735,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=735&idcol=k_abstgv.abstgvnr&idval=735&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Sport (GS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Sport (GS)"
     ]
    },
    {
     "id": "sport-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Sport im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Sport"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2026",
       "code": "sport-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|sport-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5331"
      }
     ],
     "lsf": {
      "nummer": 749,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=749&idcol=k_abstgv.abstgvnr&idval=749&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Sport (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Sport (HS)",
      "Hauptfach im M.Ed.: Sport (RS)"
     ]
    },
    {
     "id": "sport-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Sport im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Sport"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
     "pos": [
      {
       "po": "2014",
       "code": "sport-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2014",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2014"
       ],
       "study_plan": null,
       "key": "hildesheim|sport-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2014",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4271"
      },
      {
       "po": "2022",
       "code": "sport-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2022"
       ],
       "study_plan": null,
       "key": "hildesheim|sport-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5204"
      }
     ]
    },
    {
     "id": "technik-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Technik im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Technik"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "technik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|technik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5346"
      }
     ],
     "lsf": {
      "nummer": 754,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=754&idcol=k_abstgv.abstgvnr&idval=754&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Technik (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Technik (HS)",
      "Hauptfach im M.Ed.: Technik (RS)"
     ]
    },
    {
     "id": "technik-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Technik im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Technik"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2021",
       "code": "technik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hildesheim|technik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2021",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4906"
      }
     ],
     "lsf": {
      "nummer": 19,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=19&idcol=k_abstgv.abstgvnr&idval=19&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Technik (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Technik (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Technik (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Technik (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Technik (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Technik (Ergänzungsfach) (Umweltsicherung)",
      "Hauptfach im 2-Fächer-Bachelor: Technik (Sport, Gesundheit und Leistung)",
      "Hauptfach im 2-Fächer-Bachelor: Technik (Wirtschaft Plus)"
     ]
    },
    {
     "id": "wirtschaft-im-master-lehramt-an-haupt-und-realschulen-m-ed",
     "program": "Wirtschaft im Master Lehramt an Haupt- und Realschulen",
     "degree": "M.Ed.",
     "qis_names": [
      "Wirtschaft"
     ],
     "regular_semesters": 4,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5323",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2026",
       "code": "wirtschaft-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hildesheim|wirtschaft-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5347"
      }
     ],
     "lsf": {
      "nummer": 740,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=740&idcol=k_abstgv.abstgvnr&idval=740&purge=n&getglobal=n",
      "text": "Hauptfach im M.Ed.: Wirtschaft (HS)"
     },
     "lsf_names": [
      "Hauptfach im M.Ed.: Wirtschaft (HS)",
      "Hauptfach im M.Ed.: Wirtschaft (RS)"
     ]
    },
    {
     "id": "wirtschaft-im-polyvalenten-zwei-faecher-bachelor-b-a-b-sc",
     "program": "Wirtschaft im Polyvalenten Zwei-Fächer-Bachelor",
     "degree": "B.A./B.Sc.",
     "qis_names": [
      "Wirtschaft"
     ],
     "regular_semesters": 6,
     "total_lp": null,
     "po_document_url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5318",
     "faculty": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2014",
       "code": "wirtschaft-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2014",
       "source": "hildesheim-grundstock",
       "catalog_terms": [
        "SS 2014"
       ],
       "study_plan": null,
       "key": "hildesheim|wirtschaft-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2014",
       "format": "hildesheim-modulbeschreibung",
       "url": "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=4254"
      }
     ],
     "lsf": {
      "nummer": 3,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=3&idcol=k_abstgv.abstgvnr&idval=3&purge=n&getglobal=n",
      "text": "Hauptfach im 2-Fächer-Bachelor: Wirtschaft (Lehramt)"
     },
     "lsf_names": [
      "Hauptfach im 2-Fächer-Bachelor: Wirtschaft (Lehramt)",
      "Hauptfach im 2-Fächer-Bachelor: Wirtschaft (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Wirtschaft (Engl. Appl. Ling.)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Wirtschaftswissenschaft (Ergänzungsfach) (Umweltsicherung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Wirtschaft (Wahlpflichtfach/Ergänzungsfach) (individuell)",
      "Hauptfach im 2-Fächer-Bachelor: Wirtschaft (Sport, Gesundheit und Leistung)",
      "Wahlpflicht-/Ergänzungs-/Vertiefungsfach 2-Fächer-Bachelor: Wirtschaft (Ergänzungsfach) (Engl. Appl. Ling.)",
      "Hauptfach im 2-Fächer-Bachelor: Wirtschaft (Wirtschaft Plus)"
     ]
    },
    {
     "id": "nebenfach-bachelor-internationales-informationsmanagement-mit-dem-schwerpunkt-angewandte-sprachwissenschaften",
     "program": "Bachelor Internationales Informationsmanagement mit dem Schwerpunkt Angewandte Sprachwissenschaften",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 251,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=251&idcol=k_abstgv.abstgvnr&idval=251&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Bachelor Internationales Informationsmanagement mit dem Schwerpunkt Angewandte Sprachwissenschaften"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Bachelor Internationales Informationsmanagement mit dem Schwerpunkt Angewandte Sprachwissenschaften"
     ]
    },
    {
     "id": "nebenfach-bachelor-internationales-informationsmanagement-mit-dem-schwerpunkt-angewandte-informationswissenschaften",
     "program": "Bachelor Internationales Informationsmanagement mit dem Schwerpunkt Angewandte Informationswissenschaften",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 252,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=252&idcol=k_abstgv.abstgvnr&idval=252&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Bachelor Internationales Informationsmanagement mit dem Schwerpunkt Angewandte Informationswissenschaften"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Bachelor Internationales Informationsmanagement mit dem Schwerpunkt Angewandte Informationswissenschaften"
     ]
    },
    {
     "id": "nebenfach-bildende-kunst",
     "program": "Bildende Kunst",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 537,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=537&idcol=k_abstgv.abstgvnr&idval=537&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Bildende Kunst (PKM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Bildende Kunst (PKM)",
      "Nebenfach (Bachelor): Bildende Kunst (SK)",
      "Nebenfach (Master): Bildende Kunst (PKM)",
      "Nebenfach (Bachelor): Bildende Kunst (KKP)",
      "Nebenfach (Bachelor): Bildende Kunst (LSK)",
      "Nebenfach (Master): Bildende Kunst (KGT)",
      "Nebenfach (Master): Bildende Kunst (KKT)"
     ]
    },
    {
     "id": "nebenfach-musik",
     "program": "Musik",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 541,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=541&idcol=k_abstgv.abstgvnr&idval=541&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Musik (PKM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Musik (PKM)",
      "Nebenfach (Bachelor): Musik (SK)",
      "Nebenfach (Master): Musik (PKM)",
      "Nebenfach (Bachelor): Musik (KKP)",
      "Nebenfach (Bachelor): Musik (LSK)",
      "Nebenfach (Master): Musik (KGT)",
      "Nebenfach (Master): Musik (KKT)"
     ]
    },
    {
     "id": "nebenfach-philosophie",
     "program": "Philosophie",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 544,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=544&idcol=k_abstgv.abstgvnr&idval=544&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Philosophie (SK)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Philosophie (SK)",
      "Nebenfach (Master): Philosophie (MI+)",
      "Nebenfach (Bachelor): Philosophie (LSK)"
     ]
    },
    {
     "id": "nebenfach-medien",
     "program": "Medien",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 547,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=547&idcol=k_abstgv.abstgvnr&idval=547&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Medien (PKM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Medien (PKM)",
      "Nebenfach (Bachelor): Medien (SK)",
      "Nebenfach (Bachelor): Medien (KKP)",
      "Nebenfach (Bachelor): Medien (LSK)"
     ]
    },
    {
     "id": "nebenfach-theater",
     "program": "Theater",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 551,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=551&idcol=k_abstgv.abstgvnr&idval=551&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Theater (PKM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Theater (PKM)",
      "Nebenfach (Bachelor): Theater (SK)",
      "Nebenfach (Master): Theater (PKM)",
      "Nebenfach (Bachelor): Theater (KKP)",
      "Nebenfach (Bachelor): Theater (LSK)",
      "Nebenfach (Master): Theater (KGT)",
      "Nebenfach (Master): Theater (KKT)"
     ]
    },
    {
     "id": "nebenfach-literatur",
     "program": "Literatur",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 554,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=554&idcol=k_abstgv.abstgvnr&idval=554&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Literatur (PKM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Literatur (PKM)",
      "Nebenfach (Bachelor): Literatur (SK)",
      "Nebenfach (Master): Literatur (PKM)",
      "Nebenfach (Bachelor): Literatur (KKP)",
      "Nebenfach (Master): Literatur (KKT)"
     ]
    },
    {
     "id": "nebenfach-kulturpolitik",
     "program": "Kulturpolitik",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 556,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=556&idcol=k_abstgv.abstgvnr&idval=556&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Kulturpolitik (SK)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Kulturpolitik (SK)",
      "Nebenfach (Bachelor): Kulturpolitik (LSK)"
     ]
    },
    {
     "id": "nebenfach-englisch-begleitfach",
     "program": "Englisch (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 578,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=578&idcol=k_abstgv.abstgvnr&idval=578&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Englisch (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Englisch (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-biologie-begleitfach",
     "program": "Biologie (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 579,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=579&idcol=k_abstgv.abstgvnr&idval=579&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Biologie (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Biologie (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-chemie-begleitfach",
     "program": "Chemie (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 580,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=580&idcol=k_abstgv.abstgvnr&idval=580&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Chemie (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Chemie (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-geographie-begleitfach",
     "program": "Geographie (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 581,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=581&idcol=k_abstgv.abstgvnr&idval=581&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Geographie (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Geographie (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-evangelische-theologie-begleitfach",
     "program": "Evangelische Theologie (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 582,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=582&idcol=k_abstgv.abstgvnr&idval=582&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Evangelische Theologie (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Evangelische Theologie (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-geschichte-begleitfach",
     "program": "Geschichte (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 583,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=583&idcol=k_abstgv.abstgvnr&idval=583&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Geschichte (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Geschichte (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-katholische-theologie-begleitfach",
     "program": "Katholische Theologie (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 584,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=584&idcol=k_abstgv.abstgvnr&idval=584&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Katholische Theologie (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Katholische Theologie (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-kunst-begleitfach",
     "program": "Kunst (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 585,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=585&idcol=k_abstgv.abstgvnr&idval=585&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Kunst (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Kunst (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-sport-begleitfach",
     "program": "Sport (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 586,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=586&idcol=k_abstgv.abstgvnr&idval=586&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Sport (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Sport (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-musik-begleitfach",
     "program": "Musik (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 587,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=587&idcol=k_abstgv.abstgvnr&idval=587&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Musik (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Musik (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-philosophie-begleitfach",
     "program": "Philosophie (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 588,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=588&idcol=k_abstgv.abstgvnr&idval=588&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Philosophie (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Philosophie (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-politikwissenschaft-begleitfach",
     "program": "Politikwissenschaft (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 589,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=589&idcol=k_abstgv.abstgvnr&idval=589&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Politikwissenschaft (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Politikwissenschaft (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-sachunterricht-begleitfach",
     "program": "Sachunterricht (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 590,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=590&idcol=k_abstgv.abstgvnr&idval=590&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Sachunterricht (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Sachunterricht (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-technik-begleitfach",
     "program": "Technik (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 592,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=592&idcol=k_abstgv.abstgvnr&idval=592&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Technik (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Technik (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-betriebswirtschaftslehre-begleitfach",
     "program": "Betriebswirtschaftslehre (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 610,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=610&idcol=k_abstgv.abstgvnr&idval=610&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Betriebswirtschaftslehre (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Betriebswirtschaftslehre (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-biologie-nebenfach",
     "program": "Biologie (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 633,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=633&idcol=k_abstgv.abstgvnr&idval=633&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Biologie (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Biologie (Nebenfach) (I+)"
     ]
    },
    {
     "id": "nebenfach-betriebswirtschaftslehre",
     "program": "Betriebswirtschaftslehre",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 637,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=637&idcol=k_abstgv.abstgvnr&idval=637&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Betriebswirtschaftslehre (MI+)"
     },
     "lsf_names": [
      "Nebenfach (Master): Betriebswirtschaftslehre (MI+)"
     ]
    },
    {
     "id": "nebenfach-sozialwissenschaften",
     "program": "Sozialwissenschaften",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 639,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=639&idcol=k_abstgv.abstgvnr&idval=639&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Sozialwissenschaften (MI+)"
     },
     "lsf_names": [
      "Nebenfach (Master): Sozialwissenschaften (MI+)"
     ]
    },
    {
     "id": "nebenfach-informationstechnologie",
     "program": "Informationstechnologie",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 640,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=640&idcol=k_abstgv.abstgvnr&idval=640&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Informationstechnologie (MI+)"
     },
     "lsf_names": [
      "Nebenfach (Master): Informationstechnologie (MI+)"
     ]
    },
    {
     "id": "nebenfach-interkulturelle-kommunikation-nebenfach",
     "program": "Interkulturelle Kommunikation (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 782,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=782&idcol=k_abstgv.abstgvnr&idval=782&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Interkulturelle Kommunikation (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Interkulturelle Kommunikation (Nebenfach) (I+)"
     ]
    },
    {
     "id": "nebenfach-betriebswirtschaftslehre-nebenfach",
     "program": "Betriebswirtschaftslehre (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 783,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=783&idcol=k_abstgv.abstgvnr&idval=783&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Betriebswirtschaftslehre (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Betriebswirtschaftslehre (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Betriebswirtschaftslehre (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Betriebswirtschaftslehre (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-geschichte-nebenfach",
     "program": "Geschichte (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 787,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=787&idcol=k_abstgv.abstgvnr&idval=787&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Geschichte (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Geschichte (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Geschichte (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Geschichte (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-musik-nebenfach",
     "program": "Musik (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 788,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=788&idcol=k_abstgv.abstgvnr&idval=788&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Musik (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Musik (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Musik (Nebenfach) (IKS)"
     ]
    },
    {
     "id": "nebenfach-philosophie-nebenfach",
     "program": "Philosophie (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 789,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=789&idcol=k_abstgv.abstgvnr&idval=789&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Philosophie (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Philosophie (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Philosophie (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Philosophie (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-politikwissenschaft-nebenfach",
     "program": "Politikwissenschaft (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 791,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=791&idcol=k_abstgv.abstgvnr&idval=791&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Politikwissenschaft (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Politikwissenschaft (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Politikwissenschaft (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Politikwissenschaft (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-medienwissenschaft-nebenfach",
     "program": "Medienwissenschaft (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 792,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=792&idcol=k_abstgv.abstgvnr&idval=792&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Medienwissenschaft (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Medienwissenschaft (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Medienwissenschaft (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Medienwissenschaft (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-informationswissenschaft-nebenfach",
     "program": "Informationswissenschaft (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 795,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=795&idcol=k_abstgv.abstgvnr&idval=795&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Informationswissenschaft (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Informationswissenschaft (Nebenfach) (I+)"
     ]
    },
    {
     "id": "nebenfach-informationstechnologie-nebenfach",
     "program": "Informationstechnologie (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 796,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=796&idcol=k_abstgv.abstgvnr&idval=796&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Informationstechnologie (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Informationstechnologie (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Informationstechnologie (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Informationstechnologie (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-psychologie-nebenfach",
     "program": "Psychologie (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 797,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=797&idcol=k_abstgv.abstgvnr&idval=797&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Psychologie (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Psychologie (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Psychologie (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Psychologie (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-literatur-und-aesthetische-kommunikation-nebenfach",
     "program": "Literatur und ästhetische Kommunikation (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 799,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=799&idcol=k_abstgv.abstgvnr&idval=799&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Literatur und ästhetische Kommunikation (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Literatur und ästhetische Kommunikation (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Literatur und ästhetische Kommunikation (Nebenfach) (IKS)"
     ]
    },
    {
     "id": "nebenfach-medien-und-populaere-kultur",
     "program": "Medien und Populäre Kultur",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 813,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=813&idcol=k_abstgv.abstgvnr&idval=813&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Medien und Populäre Kultur (PKM)"
     },
     "lsf_names": [
      "Nebenfach (Master): Medien und Populäre Kultur (PKM)"
     ]
    },
    {
     "id": "nebenfach-uebersetzungswissenschaft-nebenfach",
     "program": "Übersetzungswissenschaft (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 829,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=829&idcol=k_abstgv.abstgvnr&idval=829&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Übersetzungswissenschaft (Nebenfach) (I+)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Übersetzungswissenschaft (Nebenfach) (I+)",
      "Nebenfach (Bachelor): Übersetzungswissenschaft (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Übersetzungswissenschaft (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-psychologie",
     "program": "Psychologie",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 833,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=833&idcol=k_abstgv.abstgvnr&idval=833&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Psychologie (MI+)"
     },
     "lsf_names": [
      "Nebenfach (Master): Psychologie (MI+)"
     ]
    },
    {
     "id": "nebenfach-bachelor-keine-studienvariante",
     "program": "Bachelor keine Studienvariante",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 853,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=853&idcol=k_abstgv.abstgvnr&idval=853&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Bachelor keine Studienvariante"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Bachelor keine Studienvariante"
     ]
    },
    {
     "id": "nebenfach-master-keine-studienvariante",
     "program": "Master keine Studienvariante",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 854,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=854&idcol=k_abstgv.abstgvnr&idval=854&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Master keine Studienvariante"
     },
     "lsf_names": [
      "Nebenfach (Master): Master keine Studienvariante"
     ]
    },
    {
     "id": "nebenfach-schwerpunkt-klinische-psychologie-msc-psychologie",
     "program": "Schwerpunkt Klinische Psychologie (MSc Psychologie)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 855,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=855&idcol=k_abstgv.abstgvnr&idval=855&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Schwerpunkt Klinische Psychologie (MSc Psychologie) (PSY)"
     },
     "lsf_names": [
      "Nebenfach (Master): Schwerpunkt Klinische Psychologie (MSc Psychologie) (PSY)"
     ]
    },
    {
     "id": "nebenfach-schwerpunkt-paedagogische-psychologie-msc-psychologie",
     "program": "Schwerpunkt Pädagogische Psychologie (MSc Psychologie)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 856,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=856&idcol=k_abstgv.abstgvnr&idval=856&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Schwerpunkt Pädagogische Psychologie (MSc Psychologie) (PSY)"
     },
     "lsf_names": [
      "Nebenfach (Master): Schwerpunkt Pädagogische Psychologie (MSc Psychologie) (PSY)"
     ]
    },
    {
     "id": "nebenfach-schwerpunkt-rechtspsychologie-msc-psychologie",
     "program": "Schwerpunkt Rechtspsychologie (MSc Psychologie)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 857,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=857&idcol=k_abstgv.abstgvnr&idval=857&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Schwerpunkt Rechtspsychologie (MSc Psychologie) (PSY)"
     },
     "lsf_names": [
      "Nebenfach (Master): Schwerpunkt Rechtspsychologie (MSc Psychologie) (PSY)"
     ]
    },
    {
     "id": "nebenfach-politikwissenschaft",
     "program": "Politikwissenschaft",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 903,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=903&idcol=k_abstgv.abstgvnr&idval=903&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Politikwissenschaft (DIS)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Politikwissenschaft (DIS)"
     ]
    },
    {
     "id": "nebenfach-soziologie",
     "program": "Soziologie",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 907,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=907&idcol=k_abstgv.abstgvnr&idval=907&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Soziologie (DIS)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Soziologie (DIS)"
     ]
    },
    {
     "id": "nebenfach-soziologie-nebenfach",
     "program": "Soziologie (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 908,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=908&idcol=k_abstgv.abstgvnr&idval=908&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Soziologie (Nebenfach) (IKS)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Soziologie (Nebenfach) (IKS)",
      "Nebenfach (Bachelor): Soziologie (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-musikwissenschaft-nebenfach",
     "program": "Musikwissenschaft (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 920,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=920&idcol=k_abstgv.abstgvnr&idval=920&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Musikwissenschaft (Nebenfach) (IIM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Musikwissenschaft (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-literatur-nebenfach",
     "program": "Literatur (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 926,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=926&idcol=k_abstgv.abstgvnr&idval=926&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Literatur (Nebenfach) (IIM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Literatur (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-physik-begleitfach",
     "program": "Physik (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 937,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=937&idcol=k_abstgv.abstgvnr&idval=937&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Physik (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Physik (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-film-und-bewegtbild",
     "program": "Film und Bewegtbild",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 964,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=964&idcol=k_abstgv.abstgvnr&idval=964&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Film und Bewegtbild (KKP)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Film und Bewegtbild (KKP)",
      "Nebenfach (Bachelor): Film und Bewegtbild (LSK)",
      "Nebenfach (Bachelor): Film und Bewegtbild (SK)",
      "Nebenfach (Bachelor): Film und Bewegtbild (PKM)"
     ]
    },
    {
     "id": "nebenfach-interkulturelle-kommunikation-begleitfach",
     "program": "Interkulturelle Kommunikation (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 967,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=967&idcol=k_abstgv.abstgvnr&idval=967&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Interkulturelle Kommunikation (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Interkulturelle Kommunikation (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-film-und-populaere-kultur",
     "program": "Film und Populäre Kultur",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 979,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=979&idcol=k_abstgv.abstgvnr&idval=979&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Film und Populäre Kultur (KGT)"
     },
     "lsf_names": [
      "Nebenfach (Master): Film und Populäre Kultur (KGT)",
      "Nebenfach (Master): Film und Populäre Kultur (KKT)"
     ]
    },
    {
     "id": "nebenfach-physik-nebenfach",
     "program": "Physik (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 988,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=988&idcol=k_abstgv.abstgvnr&idval=988&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Physik (Nebenfach) (IIM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Physik (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-technik-nebenfach",
     "program": "Technik (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 989,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=989&idcol=k_abstgv.abstgvnr&idval=989&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Technik (Nebenfach) (IIM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Technik (Nebenfach) (IIM)"
     ]
    },
    {
     "id": "nebenfach-englisch-bilinguales-lehren-und-lernen-begleitfach",
     "program": "Englisch/Bilinguales Lehren und Lernen (Begleitfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 990,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=990&idcol=k_abstgv.abstgvnr&idval=990&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Englisch/Bilinguales Lehren und Lernen (Begleitfach) (BES)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Englisch/Bilinguales Lehren und Lernen (Begleitfach) (BES)"
     ]
    },
    {
     "id": "nebenfach-uebersetzungswissenschaft",
     "program": "Übersetzungswissenschaft",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 996,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=996&idcol=k_abstgv.abstgvnr&idval=996&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Übersetzungswissenschaft (MI+)"
     },
     "lsf_names": [
      "Nebenfach (Master): Übersetzungswissenschaft (MI+)"
     ]
    },
    {
     "id": "nebenfach-informationswissenschaft",
     "program": "Informationswissenschaft",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 997,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=997&idcol=k_abstgv.abstgvnr&idval=997&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Informationswissenschaft (MI+)"
     },
     "lsf_names": [
      "Nebenfach (Master): Informationswissenschaft (MI+)"
     ]
    },
    {
     "id": "nebenfach-politikwissenschaft-psychologie-soziologie-kompakt",
     "program": "Politikwissenschaft - Psychologie - Soziologie - kompakt",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 1004,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=1004&idcol=k_abstgv.abstgvnr&idval=1004&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Politikwissenschaft - Psychologie - Soziologie - kompakt (MI+)"
     },
     "lsf_names": [
      "Nebenfach (Master): Politikwissenschaft - Psychologie - Soziologie - kompakt (MI+)"
     ]
    },
    {
     "id": "nebenfach-sprachwissenschaft-und-interkulturelle-kommunikation",
     "program": "Sprachwissenschaft und Interkulturelle Kommunikation",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 1005,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=1005&idcol=k_abstgv.abstgvnr&idval=1005&purge=n&getglobal=n",
      "text": "Nebenfach (Master): Sprachwissenschaft und Interkulturelle Kommunikation (MI+)"
     },
     "lsf_names": [
      "Nebenfach (Master): Sprachwissenschaft und Interkulturelle Kommunikation (MI+)"
     ]
    },
    {
     "id": "nebenfach-film-und-bewegtbild-nebenfach",
     "program": "Film und Bewegtbild (Nebenfach)",
     "degree": "Nebenfach",
     "kind": "nebenfach",
     "qis_names": [],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": null,
     "pos": [],
     "lsf": {
      "nummer": 1006,
      "url": "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&act=stg&pool=stg&P.subc=plan&k_abstgv.abstgvnr=1006&idcol=k_abstgv.abstgvnr&idval=1006&purge=n&getglobal=n",
      "text": "Nebenfach (Bachelor): Film und Bewegtbild (Nebenfach) (IIM)"
     },
     "lsf_names": [
      "Nebenfach (Bachelor): Film und Bewegtbild (Nebenfach) (IIM)"
     ]
    }
   ]
  },
  {
   "id": "hsh",
   "name": "Hochschule Hannover",
   "sources": [
    {
     "id": "hsh-grundstock",
     "format": "grundstock",
     "note": "Kataloge nur aus dem StudiNow-Grundstock (App-Ressource StudyCatalogSeed), auf dem Geraet wird nichts geladen (tools/build-hsh-seed.py)",
     "probe_current_term": false
    }
   ],
   "programs": [
    {
     "id": "angewandte-informatik-b-sc",
     "program": "Angewandte Informatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Angewandte Informatik",
      "Angewandte Informatik ( .)",
      "Angewandte Informatik (BIN)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/Informatik/Ordnungen/04_FIV_ATPO_2025_mit_Anhang_VB.pdf",
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2019",
       "code": "angewandte-informatik|b.sc.|bin|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|angewandte-informatik|b.sc.|bin|2019",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/Informatik/Modulhandbuecher/2024-04-29-modules-BIN-19WS-DE.pdf",
       "label": "Modulverzeichnis (Stand 29.04.2024 für Prüfungsordnung 2019-WS)"
      }
     ]
    },
    {
     "id": "angewandte-informatik-m-sc",
     "program": "Angewandte Informatik",
     "degree": "M.Sc.",
     "qis_names": [
      "Angewandte Informatik",
      "Angewandte Informatik ( .)",
      "Angewandte Informatik (MIN)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/Informatik/Ordnungen/04_FIV_ATPO_2025_mit_Anhang_VB.pdf",
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2020",
       "code": "angewandte-informatik|m.sc.|min|2020",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|angewandte-informatik|m.sc.|min|2020",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/Informatik/Modulhandbuecher/2024-04-29-modules-MIN-20WS-DE.pdf",
       "label": "Modulverzeichnis (Stand 29.04.2024 für Prüfungsordnung 2020-WS)"
      }
     ]
    },
    {
     "id": "angewandte-mathematik-und-data-science-b-sc",
     "program": "Angewandte Mathematik und Data Science",
     "degree": "B.Sc.",
     "qis_names": [
      "Angewandte Mathematik und Data Science",
      "Angewandte Mathematik und Data Science ( .)",
      "Angewandte Mathematik und Data Science (MAT)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/10_Pruefungsordnungen/10_Bachelorstdg/MAT/Studienablauf_MAT_ab_WiSe2026.pdf",
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": []
    },
    {
     "id": "bank-und-versicherungswesen-b-a",
     "program": "Bank- und Versicherungswesen",
     "degree": "B.A.",
     "qis_names": [
      "Bank- und Versicherungswesen",
      "Bank- und Versicherungswesen ( .)",
      "Bank- und Versicherungswesen (BBI)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": null,
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": []
    },
    {
     "id": "betriebswirtschaftslehre-b-sc",
     "program": "Betriebswirtschaftslehre",
     "degree": "B.Sc.",
     "qis_names": [
      "Betriebswirtschaftslehre",
      "Betriebswirtschaftslehre ( .)",
      "Betriebswirtschaftslehre (BBA)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": null,
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2018",
       "code": "betriebswirtschaftslehre|b.sc.|bba|2018",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hsh|betriebswirtschaftslehre|b.sc.|bba|2018",
       "format": "hsh-code-kopf",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/BWL/Ordnungen/Modulhandbuch_neue_PO_Module_BBA_Stand_21.08.2026.pdf",
       "label": "Modulhandbuch (PO 2018)"
      }
     ]
    },
    {
     "id": "bildungswissenschaften-fuer-pflege-und-gesundheitsberufe-m-a",
     "program": "Bildungswissenschaften für Pflege- und Gesundheitsberufe",
     "degree": "M.A.",
     "qis_names": [
      "Bildungswissenschaften für Pflege- und Gesundheitsberufe",
      "Bildungswissenschaften für Pflege- und Gesundheitsberufe ( .)",
      "Bildungswissenschaften für Pflege- und Gesundheitsberufe (MBG)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "unbekannt",
       "code": "bildungswissenschaften-fuer-pflege-und-gesundheitsberufe|m.a.|mbg",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hsh|bildungswissenschaften-fuer-pflege-und-gesundheitsberufe|m.a.|mbg",
       "format": "hsh-modultitel",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Master/MGB__MBG__MMG/Mudulhandbuecher/07.4-MBG_Modulhandbuch_Stand_01.09.2026.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "biotechnologie-und-umwelttechnik-b-eng",
     "program": "Biotechnologie und Umwelttechnik",
     "degree": "B.Eng.",
     "qis_names": [
      "Biotechnologie und Umwelttechnik",
      "Biotechnologie und Umwelttechnik ( .)",
      "Biotechnologie und Umwelttechnik (BIU)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Studiengaenge/12_F_II_BV_BIU_BTPO_BA.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "unbekannt",
       "code": "biotechnologie-und-umwelttechnik|b.eng.|biu",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|biotechnologie-und-umwelttechnik|b.eng.|biu",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Studiengaenge/Modulhandbuch_Biotechnologie_und_Umwelttechnik.pdf",
       "label": "Modulhandbuch BIU"
      }
     ]
    },
    {
     "id": "design-und-medien-m-a",
     "program": "Design und Medien",
     "degree": "M.A.",
     "qis_names": [
      "Design und Medien",
      "Design und Medien ( .)",
      "Design und Medien (MDM)"
     ],
     "regular_semesters": 2,
     "total_lp": 60,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "design-und-medien|m.a.|mdm|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|design-und-medien|m.a.|mdm|2022",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/Modulhandbuch_MDM_PO_2022_23.pdf",
       "label": "Modulhandbuch Master-Studiengang Design und Medien"
      }
     ]
    },
    {
     "id": "digitale-transformation-m-sc",
     "program": "Digitale Transformation",
     "degree": "M.Sc.",
     "qis_names": [
      "Digitale Transformation",
      "Digitale Transformation ( .)",
      "Digitale Transformation (MDT)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/01-Aenderung_in_Paragraph_1_BTPO-250710.pdf",
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2018",
       "code": "digitale-transformation|m.sc.|mdt|2018",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|digitale-transformation|m.sc.|mdt|2018",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/05-MDT-Modulhandbuch-PO2018.pdf",
       "label": "Modulhandbuch PO 2018"
      },
      {
       "po": "2021",
       "code": "digitale-transformation|m.sc.|mdt|2021",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|digitale-transformation|m.sc.|mdt|2021",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/05-MDT-Studien-Modulhandbuch-PO2021-240317.pdf",
       "label": "Studien- und Modulhandbuch"
      }
     ]
    },
    {
     "id": "dual-studieren-in-der-elektro-und-informationstechnik-b-eng",
     "program": "Dual Studieren in der Elektro- und Informationstechnik",
     "degree": "B.Eng.",
     "qis_names": [
      "Dual Studieren in der Elektro- und Informationstechnik",
      "Dual Studieren in der Elektro- und Informationstechnik ( .)"
     ],
     "regular_semesters": 1,
     "total_lp": 30,
     "po_document_url": null,
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": []
    },
    {
     "id": "elektrische-energiesysteme-und-elektromobilitaet-m-eng",
     "program": "Elektrische Energiesysteme und Elektromobilität",
     "degree": "M.Eng.",
     "qis_names": [
      "Elektrische Energiesysteme und Elektromobilität",
      "Elektrische Energiesysteme und Elektromobilität ( .)",
      "Elektrische Energiesysteme und Elektromobilität (EEE)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/10_Pruefungsordnungen/20_Masterstdg/EEE/BPO_EEEverk29.09.2023.pdf",
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": []
    },
    {
     "id": "erweiterte-pflegepraxis-advanced-nursing-practice-anp-community-health-nursing-chn-m-sc",
     "program": "Erweiterte Pflegepraxis – Advanced Nursing Practice [ANP]/ Community Health Nursing [CHN]",
     "degree": "M.Sc.",
     "qis_names": [
      "Erweiterte Pflegepraxis – Advanced Nursing Practice [ANP]/ Community Health Nursing [CHN]",
      "Erweiterte Pflegepraxis – Advanced Nursing Practice [ANP]/ Community Health Nursing [CHN] ( .)",
      "Erweiterte Pflegepraxis – Advanced Nursing Practice [ANP]/ Community Health Nursing [CHN] (MEP)"
     ],
     "regular_semesters": 5,
     "total_lp": 150,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "unbekannt",
       "code": "erweiterte-pflegepraxis-advanced-nursing-practice-anp-community-health-nursing-chn|m.sc.|mep",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "hsh|erweiterte-pflegepraxis-advanced-nursing-practice-anp-community-health-nursing-chn|m.sc.|mep",
       "format": "hsh-modultitel",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Master/MEP/Modulhandbuecher/20261030_Modulhandbuch__Master_ANP_CHN.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "fernsehjournalismus-und-dokumentarfilm-m-a",
     "program": "Fernsehjournalismus und Dokumentarfilm",
     "degree": "M.A.",
     "qis_names": [
      "Fernsehjournalismus und Dokumentarfilm",
      "Fernsehjournalismus und Dokumentarfilm ( .)",
      "Fernsehjournalismus und Dokumentarfilm (MTV)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/01_hsh_nr_04_2023_2_PO_MTV.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "fernsehjournalismus-und-dokumentarfilm|m.a.|mtv|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|fernsehjournalismus-und-dokumentarfilm|m.a.|mtv|2022",
       "format": "hsh-modultitel",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_MTV_ab_WiSe_22_23.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "forschung-und-professionalisierung-sozialer-arbeit-m-a",
     "program": "Forschung und Professionalisierung Sozialer Arbeit",
     "degree": "M.A.",
     "qis_names": [
      "Forschung und Professionalisierung Sozialer Arbeit",
      "Forschung und Professionalisierung Sozialer Arbeit ( .)",
      "Forschung und Professionalisierung Sozialer Arbeit (MSW)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": []
    },
    {
     "id": "future-food-systems-b-eng",
     "program": "Future Food Systems",
     "degree": "B.Eng.",
     "qis_names": [
      "Future Food Systems",
      "Future Food Systems ( .)",
      "Future Food Systems (LVT)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Studiengaenge/13_F_II_BV_LVT_BTPO_BA.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "unbekannt",
       "code": "future-food-systems|b.eng.|lvt",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|future-food-systems|b.eng.|lvt",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Studiengaenge/Modulhandbuch_Future_Food_Systems.pdf",
       "label": "Modulhandbuch LVT"
      }
     ]
    },
    {
     "id": "future-food-systems-m-eng",
     "program": "Future Food Systems",
     "degree": "M.Eng.",
     "qis_names": [
      "Future Food Systems",
      "Future Food Systems ( .)",
      "Future Food Systems (MLV)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Service/Ordnungen/01_F2_BV_BTPO_MA_MLV.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2025",
       "code": "future-food-systems|m.eng.|mlv|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|future-food-systems|m.eng.|mlv|2025",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Studiengaenge/Modulhandbuch_Future_Food_Systems.pdf",
       "label": "Modulhanbuch: Future Food Systems - Lebensmitteltechnologie und Verpackungstechnologie (LVT) (PO 2025)"
      }
     ]
    },
    {
     "id": "green-engineering-nachhaltige-energie-und-verfahrenstechnik-fuer-die-biooekonomie-m-eng",
     "program": "Green Engineering - Nachhaltige Energie- und Verfahrenstechnik für die Bioökonomie",
     "degree": "M.Eng.",
     "qis_names": [
      "Green Engineering - Nachhaltige Energie- und Verfahrenstechnik für die Bioökonomie",
      "Green Engineering - Nachhaltige Energie- und Verfahrenstechnik für die Bioökonomie ( .)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": null,
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": []
    },
    {
     "id": "green-engineering-energietechnik-und-verfahrenstechnik-b-eng",
     "program": "Green Engineering – Energietechnik und Verfahrenstechnik",
     "degree": "B.Eng.",
     "qis_names": [
      "Green Engineering – Energietechnik und Verfahrenstechnik",
      "Green Engineering – Energietechnik und Verfahrenstechnik ( .)",
      "Green Engineering – Energietechnik und Verfahrenstechnik (GEV)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/GEV/F2_BA_GEV_BTPO_2025-07-15.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "unbekannt",
       "code": "green-engineering-energietechnik-und-verfahrenstechnik|b.eng.|gev",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|green-engineering-energietechnik-und-verfahrenstechnik|b.eng.|gev",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Studium/Studiengaenge/GEV/Modulbeschreibung_Maschinenbau_nicht_dual_2025-09-19.pdf",
       "label": "Entwurf Modulbeschreibung"
      }
     ]
    },
    {
     "id": "heilpaedagogik-inklusive-bildung-und-begleitung-berufsbegleitend-b-a",
     "program": "Heilpädagogik - Inklusive Bildung und Begleitung - berufsbegleitend",
     "degree": "B.A.",
     "qis_names": [
      "Heilpädagogik - Inklusive Bildung und Begleitung - berufsbegleitend",
      "Heilpädagogik - Inklusive Bildung und Begleitung - berufsbegleitend ( .)",
      "Heilpädagogik - Inklusive Bildung und Begleitung - berufsbegleitend (HBI)"
     ],
     "regular_semesters": 5,
     "total_lp": 150,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "unbekannt",
       "code": "heilpaedagogik-inklusive-bildung-und-begleitung-berufsbegleitend|b.a.|hbi",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2023"
       ],
       "study_plan": null,
       "key": "hsh|heilpaedagogik-inklusive-bildung-und-begleitung-berufsbegleitend|b.a.|hbi",
       "format": "hsh-modul-code",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Modulhandbuch_HBI_Stand_23.08.2023.pdf",
       "label": "Studienbeginn 2021-2023"
      }
     ]
    },
    {
     "id": "heilpaedagogik-inklusive-bildung-und-begleitung-b-a",
     "program": "Heilpädagogik - Inklusive Bildung und Begleitung",
     "degree": "B.A.",
     "qis_names": [
      "Heilpädagogik - Inklusive Bildung und Begleitung",
      "Heilpädagogik - Inklusive Bildung und Begleitung ( .)",
      "Heilpädagogik - Inklusive Bildung und Begleitung (BAH)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Heilpaedagogik__BAH_/2023_BAH_UEbersicht_Abb.PO20211.pdf",
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": []
    },
    {
     "id": "informationsmanagement-b-a",
     "program": "Informationsmanagement",
     "degree": "B.A.",
     "qis_names": [
      "Informationsmanagement",
      "Informationsmanagement ( .)",
      "Informationsmanagement (BIM)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/PO_BA_BIM_2026.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2024",
       "code": "informationsmanagement|b.a.|bim|2024",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hsh|informationsmanagement|b.a.|bim|2024",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_BIM_ab_WiSe_24_25.pdf",
       "label": "ab WiSe 2024/25"
      },
      {
       "po": "2026",
       "code": "informationsmanagement|b.a.|bim|2026",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hsh|informationsmanagement|b.a.|bim|2026",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_BIM_ab_WiSe_26_27.pdf",
       "label": "Modulhandbuch ab WiSe 26/27"
      }
     ]
    },
    {
     "id": "informationsmanagement-berufsbegleitend-b-a",
     "program": "Informationsmanagement berufsbegleitend",
     "degree": "B.A.",
     "qis_names": [
      "Informationsmanagement berufsbegleitend",
      "Informationsmanagement berufsbegleitend ( .)",
      "Informationsmanagement berufsbegleitend (BIB)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/PO_BIB_20242.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2024",
       "code": "informationsmanagement-berufsbegleitend|b.a.|bib|2024",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|informationsmanagement-berufsbegleitend|b.a.|bib|2024",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_BIB_ab_WiSe_24_25.pdf",
       "label": "ab WiSe 2024/25"
      },
      {
       "po": "2026",
       "code": "informationsmanagement-berufsbegleitend|b.a.|bib|2026",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hsh|informationsmanagement-berufsbegleitend|b.a.|bib|2026",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_BIB_ab_WiSe_26_27.pdf",
       "label": "ab WiSe 26/27"
      }
     ]
    },
    {
     "id": "ingenieurinformatik-maschinenbau-b-eng",
     "program": "Ingenieurinformatik Maschinenbau",
     "degree": "B.Eng.",
     "qis_names": [
      "Ingenieurinformatik Maschinenbau",
      "Ingenieurinformatik Maschinenbau ( .)",
      "Ingenieurinformatik Maschinenbau (IIM)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/IIM/F2_BA_IIM_BTPO_2025-07-15.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2019",
       "code": "ingenieurinformatik-maschinenbau|b.eng.|iim|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|ingenieurinformatik-maschinenbau|b.eng.|iim|2019",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/IIM-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Ingenieurinformatik Maschinenbau IIM (PO ab WS2019)"
      }
     ]
    },
    {
     "id": "sensor-und-automatisierungstechnik-m-eng",
     "program": "Sensor- und Automatisierungstechnik",
     "degree": "M.Eng.",
     "qis_names": [
      "Sensor- und Automatisierungstechnik",
      "Sensor- und Automatisierungstechnik ( .)",
      "Sensor- und Automatisierungstechnik (ESA)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/10_Pruefungsordnungen/20_Masterstdg/ESA/Zielematrix_ESA-2025.pdf",
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": [
      {
       "po": "2025",
       "code": "sensor-und-automatisierungstechnik|m.eng.|esa|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|sensor-und-automatisierungstechnik|m.eng.|esa|2025",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/ESA-Modulhandbuch_PO_WS_2025-26.pdf",
       "label": "Modulhandbuch ESA, PO 2025/26"
      }
     ]
    },
    {
     "id": "mechatronik-b-eng",
     "program": "Mechatronik",
     "degree": "B.Eng.",
     "qis_names": [
      "Mechatronik",
      "Mechatronik ( .)",
      "Mechatronik (MEC)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/10_Pruefungsordnungen/10_Bachelorstdg/MEC/FI_BTPO_BA_MEC_15.05.2026.pdf",
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": [
      {
       "po": "2023",
       "code": "mechatronik|b.eng.|mec|2023",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2023/24"
       ],
       "study_plan": null,
       "key": "hsh|mechatronik|b.eng.|mec|2023",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/Modulhandbuch_MEC_WS2023_V3.pdf",
       "label": "Online-Modulhandbuch"
      },
      {
       "po": "2026",
       "code": "mechatronik|b.eng.|mec|2026",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "hsh|mechatronik|b.eng.|mec|2026",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/Modulhandbuch_MEC_WS2026.pdf",
       "label": "Online-Modulhanbuch"
      }
     ]
    },
    {
     "id": "technisches-informationsdesign-und-technische-redaktion-b-sc",
     "program": "Technisches Informationsdesign und Technische Redaktion",
     "degree": "B.Sc.",
     "qis_names": [
      "Technisches Informationsdesign und Technische Redaktion",
      "Technisches Informationsdesign und Technische Redaktion ( .)",
      "Technisches Informationsdesign und Technische Redaktion (ITR)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/10_Pruefungsordnungen/10_Bachelorstdg/ITR/verk_2025_05_F_I__ITR_BTPO.pdf",
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": [
      {
       "po": "2025",
       "code": "technisches-informationsdesign-und-technische-redaktion|b.sc.|itr|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|technisches-informationsdesign-und-technische-redaktion|b.sc.|itr|2025",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/Modulhandbuch_1202_75_ITR_WS2025_final.pdf",
       "label": "Modulkatalog"
      }
     ]
    },
    {
     "id": "nachhaltige-elektrische-energieversorgung-b-eng",
     "program": "Nachhaltige Elektrische Energieversorgung",
     "degree": "B.Eng.",
     "qis_names": [
      "Nachhaltige Elektrische Energieversorgung",
      "Nachhaltige Elektrische Energieversorgung ( .)",
      "Nachhaltige Elektrische Energieversorgung (NEV)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/10_Pruefungsordnungen/10_Bachelorstdg/Vorpraktikumsordnung_F1_verkuendet_2025.pdf",
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": [
      {
       "po": "2025",
       "code": "nachhaltige-elektrische-energieversorgung|b.eng.|nev|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|nachhaltige-elektrische-energieversorgung|b.eng.|nev|2025",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/Modulhandbuch_NEV_WS2025_Stand_15.04.2025_01.pdf",
       "label": "Modulhandbuch NEV"
      }
     ]
    },
    {
     "id": "wirtschaftsingenieur-elektrotechnik-b-eng",
     "program": "Wirtschaftsingenieur Elektrotechnik",
     "degree": "B.Eng.",
     "qis_names": [
      "Wirtschaftsingenieur Elektrotechnik",
      "Wirtschaftsingenieur Elektrotechnik ( .)",
      "Wirtschaftsingenieur Elektrotechnik (EWI)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/10_Pruefungsordnungen/10_Bachelorstdg/EWI/Qualifikationsziele_EWI_fuer_Webseite.pdf",
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": [
      {
       "po": "2018",
       "code": "wirtschaftsingenieur-elektrotechnik|b.eng.|ewi|2018",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2018/19"
       ],
       "study_plan": null,
       "key": "hsh|wirtschaftsingenieur-elektrotechnik|b.eng.|ewi|2018",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/2018_2_Modulhandbuch_EWI.pdf",
       "label": "Modulhandbuch EWI"
      },
      {
       "po": "2025",
       "code": "wirtschaftsingenieur-elektrotechnik|b.eng.|ewi|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|wirtschaftsingenieur-elektrotechnik|b.eng.|ewi|2025",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/Modulhandbuch_EWI_WS2025_Stand_15.04.2025_01.pdf",
       "label": "Modulhandbuch EWI (PO WS 2025/26)"
      }
     ]
    },
    {
     "id": "wirtschaftsingenieurwesen-maschinenbau-b-eng",
     "program": "Wirtschaftsingenieurwesen Maschinenbau",
     "degree": "B.Eng.",
     "qis_names": [
      "Wirtschaftsingenieurwesen Maschinenbau",
      "Wirtschaftsingenieurwesen Maschinenbau ( .)",
      "Wirtschaftsingenieurwesen Maschinenbau (WIM)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/WIM/F2_BA_WIM_BTPO_2025-07-15.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2010",
       "code": "wirtschaftsingenieurwesen-maschinenbau|b.eng.|wim|2010",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2010/11"
       ],
       "study_plan": null,
       "key": "hsh|wirtschaftsingenieurwesen-maschinenbau|b.eng.|wim|2010",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WIM-WS2010-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Wirtschaftsingenieur Maschinenbau WIM (PO ab WS2010)"
      },
      {
       "po": "2016",
       "code": "wirtschaftsingenieurwesen-maschinenbau|b.eng.|wim|2016",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2016/17"
       ],
       "study_plan": null,
       "key": "hsh|wirtschaftsingenieurwesen-maschinenbau|b.eng.|wim|2016",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WIM-WS2016-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Wirtschaftsingenieur Maschinenbau WIM (PO ab WS2016)"
      },
      {
       "po": "2019",
       "code": "wirtschaftsingenieurwesen-maschinenbau|b.eng.|wim|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|wirtschaftsingenieurwesen-maschinenbau|b.eng.|wim|2019",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WIM-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Wirtschaftsingenieur Maschinenbau WIM (PO ab WS2019)"
      }
     ]
    },
    {
     "id": "maschinenbau-entwicklung-m-eng",
     "program": "Maschinenbau – Entwicklung",
     "degree": "M.Eng.",
     "qis_names": [
      "Maschinenbau – Entwicklung",
      "Maschinenbau – Entwicklung ( .)",
      "Maschinenbau – Entwicklung (MED)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": null,
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2010",
       "code": "maschinenbau-entwicklung|m.eng.|med|2010",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2010/11"
       ],
       "study_plan": null,
       "key": "hsh|maschinenbau-entwicklung|m.eng.|med|2010",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MED-WS2010-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Maschinenbau-Entwicklung MED (PO ab WS2010)"
      }
     ]
    },
    {
     "id": "milch-und-verpackungswirtschaft-m-eng",
     "program": "Milch- und Verpackungswirtschaft",
     "degree": "M.Eng.",
     "qis_names": [
      "Milch- und Verpackungswirtschaft",
      "Milch- und Verpackungswirtschaft ( .)",
      "Milch- und Verpackungswirtschaft (MMV)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": null,
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2011",
       "code": "milch-und-verpackungswirtschaft|m.eng.|mmv|2011",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|milch-und-verpackungswirtschaft|m.eng.|mmv|2011",
       "format": "hsh-modul-code",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/Modulhandbuch_MMV_19.07.11.pdf",
       "label": "Modulhandbuch: Milch- und Verpackungswirtschaft MMV (PO ab WS2011)"
      }
     ]
    },
    {
     "id": "lebensmittelverpackungstechnologie-b-eng",
     "program": "Lebensmittelverpackungstechnologie",
     "degree": "B.Eng.",
     "qis_names": [
      "Lebensmittelverpackungstechnologie",
      "Lebensmittelverpackungstechnologie ( .)",
      "Lebensmittelverpackungstechnologie (LMV)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": null,
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2011",
       "code": "lebensmittelverpackungstechnologie|b.eng.|lmv|2011",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|lebensmittelverpackungstechnologie|b.eng.|lmv|2011",
       "format": "hsh-modul-code",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/LMV_20102.pdf",
       "label": "Modulhandbuch: Lebensmittelverpackungstechnologie LMV (PO ab WS2011)"
      }
     ]
    },
    {
     "id": "milchwirtschaftliche-lebensmitteltechnologie-b-eng",
     "program": "Milchwirtschaftliche Lebensmitteltechnologie",
     "degree": "B.Eng.",
     "qis_names": [
      "Milchwirtschaftliche Lebensmitteltechnologie",
      "Milchwirtschaftliche Lebensmitteltechnologie ( .)",
      "Milchwirtschaftliche Lebensmitteltechnologie (BML)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": null,
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2011",
       "code": "milchwirtschaftliche-lebensmitteltechnologie|b.eng.|bml|2011",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|milchwirtschaftliche-lebensmitteltechnologie|b.eng.|bml|2011",
       "format": "hsh-modul-code",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/BML_20102.pdf",
       "label": "Modulhandbuch: Milchwirtschaftliche Lebensmitteltechnologie BML (PO ab WS2011)"
      }
     ]
    },
    {
     "id": "technologie-nachwachsender-rohstoffe-b-eng",
     "program": "Technologie Nachwachsender Rohstoffe",
     "degree": "B.Eng.",
     "qis_names": [
      "Technologie Nachwachsender Rohstoffe",
      "Technologie Nachwachsender Rohstoffe ( .)",
      "Technologie Nachwachsender Rohstoffe (TNR)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": null,
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2011",
       "code": "technologie-nachwachsender-rohstoffe|b.eng.|tnr|2011",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|technologie-nachwachsender-rohstoffe|b.eng.|tnr|2011",
       "format": "hsh-modul-code",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/TNR_20102.pdf",
       "label": "Modulhandbuch: Technologie Nachwachsender Rohstoffe TNR (PO ab WS2011)"
      }
     ]
    },
    {
     "id": "wirtschaftsingenieur-in-technischer-vertrieb-dual-b-eng",
     "program": "Wirtschaftsingenieur/in (Technischer Vertrieb) dual",
     "degree": "B.Eng.",
     "qis_names": [
      "Wirtschaftsingenieur/in (Technischer Vertrieb) dual",
      "Wirtschaftsingenieur/in (Technischer Vertrieb) dual ( .)",
      "Wirtschaftsingenieur/in (Technischer Vertrieb) dual (WTD)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/WTD/WTD_PO_mit_Anlagen_2019.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2012",
       "code": "wirtschaftsingenieur-in-technischer-vertrieb-dual|b.eng.|wtd|2012",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2012/13"
       ],
       "study_plan": null,
       "key": "hsh|wirtschaftsingenieur-in-technischer-vertrieb-dual|b.eng.|wtd|2012",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WTD-WS2012-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Wirtschaftsingenieur/in (Technischer Vertrieb) WTD (dual, PO ab WiSe 2012)"
      },
      {
       "po": "2019",
       "code": "wirtschaftsingenieur-in-technischer-vertrieb-dual|b.eng.|wtd|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|wirtschaftsingenieur-in-technischer-vertrieb-dual|b.eng.|wtd|2019",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WTD-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch - WTD"
      }
     ]
    },
    {
     "id": "intelligente-produktion-m-eng",
     "program": "Intelligente Produktion",
     "degree": "M.Eng.",
     "qis_names": [
      "Intelligente Produktion",
      "Intelligente Produktion ( .)",
      "Intelligente Produktion (InPro)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Sonstiges/BTPO_Module_InPro.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": []
    },
    {
     "id": "produktionstechnik-dual-b-eng",
     "program": "Produktionstechnik dual",
     "degree": "B.Eng.",
     "qis_names": [
      "Produktionstechnik dual",
      "Produktionstechnik dual ( .)",
      "Produktionstechnik dual (PTD)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/PTD/F2_dual_BA_PTD_BTPO-2025-07-25.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2012",
       "code": "produktionstechnik-dual|b.eng.|ptd|2012",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2012/13"
       ],
       "study_plan": null,
       "key": "hsh|produktionstechnik-dual|b.eng.|ptd|2012",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/PTD-WS2012-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Produktionstechnik PTD (dual, PO ab WS2012)"
      },
      {
       "po": "2019",
       "code": "produktionstechnik-dual|b.eng.|ptd|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|produktionstechnik-dual|b.eng.|ptd|2019",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/PTD-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Produktionstechnik PTD (dual, PO ab WS2019)"
      },
      {
       "po": "2025",
       "code": "produktionstechnik-dual|b.eng.|ptd|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|produktionstechnik-dual|b.eng.|ptd|2025",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/2025_Modulhandbuch_PTD.pdf",
       "label": "Modulhandbuch: Produktionstechnik PTD (dual, PO ab WiSe 2025)"
      }
     ]
    },
    {
     "id": "wirtschaftsingenieurwesen-maschinenbau-dual-b-eng",
     "program": "Wirtschaftsingenieurwesen Maschinenbau dual",
     "degree": "B.Eng.",
     "qis_names": [
      "Wirtschaftsingenieurwesen Maschinenbau dual",
      "Wirtschaftsingenieurwesen Maschinenbau dual ( .)",
      "Wirtschaftsingenieurwesen Maschinenbau dual (WID)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/WID/F2_dual_BA_WID_BTPO_2025-07-25.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2025",
       "code": "wirtschaftsingenieurwesen-maschinenbau-dual|b.eng.|wid|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|wirtschaftsingenieurwesen-maschinenbau-dual|b.eng.|wid|2025",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/2025_Modulhandbuch_WID.pdf",
       "label": "Modulhandbuch: Wirtschaftsingenieurwesen WID (dual, PO ab WiSe 2025)"
      }
     ]
    },
    {
     "id": "ingenieurinformatik-maschinenbau-dual-b-eng",
     "program": "Ingenieurinformatik Maschinenbau dual",
     "degree": "B.Eng.",
     "qis_names": [
      "Ingenieurinformatik Maschinenbau dual",
      "Ingenieurinformatik Maschinenbau dual ( .)",
      "Ingenieurinformatik Maschinenbau dual (IID)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/IID/F2_dual_BA_IID_BTPO_2025-07-25.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2022",
       "code": "ingenieurinformatik-maschinenbau-dual|b.eng.|iid|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2022/23"
       ],
       "study_plan": null,
       "key": "hsh|ingenieurinformatik-maschinenbau-dual|b.eng.|iid|2022",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/IID-WS2022-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Ingenieurinformatik Maschinenbau IID (dual, PO ab WiSe 2022)"
      },
      {
       "po": "2025",
       "code": "ingenieurinformatik-maschinenbau-dual|b.eng.|iid|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|ingenieurinformatik-maschinenbau-dual|b.eng.|iid|2025",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/2025_Modulhandbuch_IID.pdf",
       "label": "Modulhandbuch: Ingenieurinformatik Maschinenbau IID (dual, PO ab WiSe 2025)"
      }
     ]
    },
    {
     "id": "technische-produktentwicklung-m-eng",
     "program": "Technische Produktentwicklung",
     "degree": "M.Eng.",
     "qis_names": [
      "Technische Produktentwicklung",
      "Technische Produktentwicklung ( .)",
      "Technische Produktentwicklung (TPE)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Service/Ordnungen/12_F2_MA_TPE_VB_EBU.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": []
    },
    {
     "id": "maschinenbau-produktionssysteme-dual-m-eng",
     "program": "Maschinenbau - Produktionssysteme dual",
     "degree": "M.Eng.",
     "qis_names": [
      "Maschinenbau - Produktionssysteme dual",
      "Maschinenbau - Produktionssysteme dual ( .)",
      "Maschinenbau - Produktionssysteme dual (MPD)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Service/Ordnungen/11_F2_dual_MA_MPD_PO_VB_EBU.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": []
    },
    {
     "id": "mechatronik-dual-b-eng",
     "program": "Mechatronik dual",
     "degree": "B.Eng.",
     "qis_names": [
      "Mechatronik dual",
      "Mechatronik dual ( .)",
      "Mechatronik dual (MTD)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/MTD/F2_dual_BA_MTD_BTPO_2025-07-25.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2012",
       "code": "mechatronik-dual|b.eng.|mtd|2012",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2012/13"
       ],
       "study_plan": null,
       "key": "hsh|mechatronik-dual|b.eng.|mtd|2012",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MTD-WS2012-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Mechatronik MTD (dual, PO ab WiSe 2012)"
      },
      {
       "po": "2017",
       "code": "mechatronik-dual|b.eng.|mtd|2017",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2017/18"
       ],
       "study_plan": null,
       "key": "hsh|mechatronik-dual|b.eng.|mtd|2017",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MTD-WS2017-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Mechatronik MTD (dual, PO ab WiSe 2017)"
      },
      {
       "po": "2019",
       "code": "mechatronik-dual|b.eng.|mtd|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|mechatronik-dual|b.eng.|mtd|2019",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MTD-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Mechatronik MTD (dual, PO ab WiSe 2019)"
      },
      {
       "po": "2025",
       "code": "mechatronik-dual|b.eng.|mtd|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|mechatronik-dual|b.eng.|mtd|2025",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/2025_Modulhandbuch_MTD.pdf",
       "label": "Modulhandbuch: Mechatronik MTD (dual, PO ab WiSe 2025)"
      }
     ]
    },
    {
     "id": "konstruktionstechnik-dual-b-eng",
     "program": "Konstruktionstechnik dual",
     "degree": "B.Eng.",
     "qis_names": [
      "Konstruktionstechnik dual",
      "Konstruktionstechnik dual ( .)",
      "Konstruktionstechnik dual (KTD)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/KTD/F2_dual_BA_KTD_BTPO_2025-07-25.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2012",
       "code": "konstruktionstechnik-dual|b.eng.|ktd|2012",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2012/13"
       ],
       "study_plan": null,
       "key": "hsh|konstruktionstechnik-dual|b.eng.|ktd|2012",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/KTD-WS2012-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Konstruktionstechnik KTD (dual, PO ab WiSe 2012)"
      },
      {
       "po": "2019",
       "code": "konstruktionstechnik-dual|b.eng.|ktd|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|konstruktionstechnik-dual|b.eng.|ktd|2019",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/KTD-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Konstruktionstechnik KTD (dual, PO ab WiSe 2019)"
      },
      {
       "po": "2025",
       "code": "konstruktionstechnik-dual|b.eng.|ktd|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|konstruktionstechnik-dual|b.eng.|ktd|2025",
       "format": "hsh-wpf-tabelle",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/2025_Modulhandbuch_KTD.pdf",
       "label": "Modulhandbuch: Konstruktionstechnik KTD (dual, PO ab WiSe 2025)"
      }
     ]
    },
    {
     "id": "prozess-engineering-und-produktionsmanagement-m-eng",
     "program": "Prozess-Engineering und Produktionsmanagement",
     "degree": "M.Eng.",
     "qis_names": [
      "Prozess-Engineering und Produktionsmanagement",
      "Prozess-Engineering und Produktionsmanagement ( .)",
      "Prozess-Engineering und Produktionsmanagement (PEP)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_BV/Service/Ordnungen/10_F2_MA_PEP_VB_EBU.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2019",
       "code": "prozess-engineering-und-produktionsmanagement|m.eng.|pep|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|prozess-engineering-und-produktionsmanagement|m.eng.|pep|2019",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/PEP-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Prozess-Engineering und Produktionsmanagement PEP (PO ab WS2019)"
      }
     ]
    },
    {
     "id": "visual-journalism-and-documentary-photography-b-a",
     "program": "Visual Journalism and Documentary Photography",
     "degree": "B.A.",
     "qis_names": [
      "Visual Journalism and Documentary Photography",
      "Visual Journalism and Documentary Photography ( .)",
      "Visual Journalism and Documentary Photography (BFO)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": []
    },
    {
     "id": "mode-konzept-design-kommunikation-b-a",
     "program": "MODE: konzept. design. kommunikation.",
     "degree": "B.A.",
     "qis_names": [
      "MODE: konzept. design. kommunikation.",
      "MODE: konzept. design. kommunikation. ( .)",
      "MODE: konzept. design. kommunikation. (BMO)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "mode-konzept-design-kommunikation|b.a.|bmo|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|mode-konzept-design-kommunikation|b.a.|bmo|2022",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/Modulhandbuch_BMO_PO_2022.pdf",
       "label": "Modulhandbuch Bachelor-Studiengang Modedesign"
      }
     ]
    },
    {
     "id": "visuelle-kommunikation-b-a",
     "program": "Visuelle Kommunikation",
     "degree": "B.A.",
     "qis_names": [
      "Visuelle Kommunikation",
      "Visuelle Kommunikation ( .)",
      "Visuelle Kommunikation (BVK)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "visuelle-kommunikation|b.a.|bvk|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|visuelle-kommunikation|b.a.|bvk|2022",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/Modulhandbuch_BVK_PO_2022_23.pdf",
       "label": "Modulhandbuch Bachelor-Studiengang Visuelle Kommunikation"
      }
     ]
    },
    {
     "id": "mediendesign-b-a",
     "program": "Mediendesign",
     "degree": "B.A.",
     "qis_names": [
      "Mediendesign",
      "Mediendesign ( .)",
      "Mediendesign (BME)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "mediendesign|b.a.|bme|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|mediendesign|b.a.|bme|2022",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/Modulhandbuch_BME_PO_2022_23.pdf",
       "label": "Modulhandbuch Bachelor-Studiengang Mediendesign"
      }
     ]
    },
    {
     "id": "medizinisches-informationsmanagement-m-sc",
     "program": "Medizinisches Informationsmanagement",
     "degree": "M.Sc.",
     "qis_names": [
      "Medizinisches Informationsmanagement",
      "Medizinisches Informationsmanagement ( .)",
      "Medizinisches Informationsmanagement (MMI)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/PO_MMI_01_F_III_20261.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2020",
       "code": "medizinisches-informationsmanagement|m.sc.|mmi|2020",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|medizinisches-informationsmanagement|m.sc.|mmi|2020",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_MMI_2019.pdf",
       "label": "Medizinisches Informationsmanagement ab SoSe 2020"
      }
     ]
    },
    {
     "id": "journalistik-b-a",
     "program": "Journalistik",
     "degree": "B.A.",
     "qis_names": [
      "Journalistik",
      "Journalistik ( .)",
      "Journalistik (BJO)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/PO_BJO_20222.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "journalistik|b.a.|bjo|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2021/22"
       ],
       "study_plan": null,
       "key": "hsh|journalistik|b.a.|bjo|2022",
       "format": "hsh-modultitel",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_BJO_ab_WiSe_22_23.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "innenarchitektur-b-a",
     "program": "Innenarchitektur",
     "degree": "B.A.",
     "qis_names": [
      "Innenarchitektur",
      "Innenarchitektur ( .)",
      "Innenarchitektur (BIA)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "innenarchitektur|b.a.|bia|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|innenarchitektur|b.a.|bia|2022",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/Modulhandbuch_BIA_PO_2022_23.pdf",
       "label": "Modulhandbuch Bachelor-Studiengang Innenarchitektur"
      }
     ]
    },
    {
     "id": "integrated-media-communication-imc-dual-b-a",
     "program": "Integrated Media & Communication (IMC) Dual",
     "degree": "B.A.",
     "qis_names": [
      "Integrated Media & Communication (IMC) Dual",
      "Integrated Media & Communication (IMC) Dual ( .)",
      "Integrated Media & Communication (IMC) Dual (DUAL)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/05_PO_IMC_2021.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2019",
       "code": "integrated-media-communication-imc-dual|b.a.|dual|2019",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|integrated-media-communication-imc-dual|b.a.|dual|2019",
       "format": "hsh-modultitel",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_IMC_ab_WiSe_19_20.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "medizinisches-informationsmanagement-b-sc",
     "program": "Medizinisches Informationsmanagement",
     "degree": "B.Sc.",
     "qis_names": [
      "Medizinisches Informationsmanagement",
      "Medizinisches Informationsmanagement ( .)",
      "Medizinisches Informationsmanagement (BMI)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/PO_BMI_20242.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2024",
       "code": "medizinisches-informationsmanagement|b.sc.|bmi|2024",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2024/25"
       ],
       "study_plan": null,
       "key": "hsh|medizinisches-informationsmanagement|b.sc.|bmi|2024",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_BMI_20241101.pdf",
       "label": "Modulhandbuch ab WiSe 24/25"
      }
     ]
    },
    {
     "id": "produktdesign-b-a",
     "program": "Produktdesign",
     "degree": "B.A.",
     "qis_names": [
      "Produktdesign",
      "Produktdesign ( .)",
      "Produktdesign (BPD)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "produktdesign|b.a.|bpd|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|produktdesign|b.a.|bpd|2022",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/Modulhandbuch_BPD_PO_2022.pdf",
       "label": "Modulhandbuch Bachelor-Studiengang Produktdesign"
      }
     ]
    },
    {
     "id": "public-relations-b-a",
     "program": "Public Relations",
     "degree": "B.A.",
     "qis_names": [
      "Public Relations",
      "Public Relations ( .)",
      "Public Relations (BPR)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/PO_BPR_20222.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "public-relations|b.a.|bpr|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|public-relations|b.a.|bpr|2022",
       "format": "hsh-modultitel",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_BPR_ab_WiSe_22_23.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "szenografie-kostuem-experimentelle-gestaltung-b-a",
     "program": "Szenografie – Kostüm – Experimentelle Gestaltung",
     "degree": "B.A.",
     "qis_names": [
      "Szenografie – Kostüm – Experimentelle Gestaltung",
      "Szenografie – Kostüm – Experimentelle Gestaltung ( .)",
      "Szenografie – Kostüm – Experimentelle Gestaltung (SKE)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "szenografie-kostuem-experimentelle-gestaltung|b.a.|ske|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|szenografie-kostuem-experimentelle-gestaltung|b.a.|ske|2022",
       "format": "hsh-code-kopf",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/Modulhandbuch_BSKE_PO_2022.pdf",
       "label": "Modulhandbuch Bachelor-Studiengang Szenografie-Kostüm-Experimentelle Gestaltung"
      }
     ]
    },
    {
     "id": "veranstaltungsmanagement-b-a",
     "program": "Veranstaltungsmanagement",
     "degree": "B.A.",
     "qis_names": [
      "Veranstaltungsmanagement",
      "Veranstaltungsmanagement ( .)",
      "Veranstaltungsmanagement (BVM)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/PO_BA_BVM_2026.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2015",
       "code": "veranstaltungsmanagement|b.a.|bvm|2015",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2015/16"
       ],
       "study_plan": null,
       "key": "hsh|veranstaltungsmanagement|b.a.|bvm|2015",
       "format": "hsh-modultitel",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/BVM_Modulhandbuch_ab_2015.pdf",
       "label": "Modulhandbuch - ab Studienbeginn 2015"
      },
      {
       "po": "2018",
       "code": "veranstaltungsmanagement|b.a.|bvm|2018",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2018/19"
       ],
       "study_plan": null,
       "key": "hsh|veranstaltungsmanagement|b.a.|bvm|2018",
       "format": "hsh-modultitel",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher2/BVM_Modulhandbuch_ab_2018.pdf",
       "label": "Modulhandbuch - ab Studienbeginn 2018"
      },
      {
       "po": "2022",
       "code": "veranstaltungsmanagement|b.a.|bvm|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2022/23"
       ],
       "study_plan": null,
       "key": "hsh|veranstaltungsmanagement|b.a.|bvm|2022",
       "format": "hsh-modultitel",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_BVM_ab_WiSe_22_23_Stand_20250716.pdf",
       "label": "Modulhandbuch - ab Studienbeginn 2022"
      }
     ]
    },
    {
     "id": "kommunikationsmanagement-m-a",
     "program": "Kommunikationsmanagement",
     "degree": "M.A.",
     "qis_names": [
      "Kommunikationsmanagement",
      "Kommunikationsmanagement ( .)",
      "Kommunikationsmanagement (MKO)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Ordnungen_IK/PO_MKO_20222.pdf",
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2022",
       "code": "kommunikationsmanagement|m.a.|mko|2022",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2021/22"
       ],
       "study_plan": null,
       "key": "hsh|kommunikationsmanagement|m.a.|mko|2022",
       "format": "hsh-modultitel",
       "url": "https://f3.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_III/Modulhandbuecher/Modulhandbuch_MKO_ab_WiSe_22_23.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "mediendesigninformatik-b-sc",
     "program": "Mediendesigninformatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Mediendesigninformatik",
      "Mediendesigninformatik ( .)",
      "Mediendesigninformatik (MDI)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": null,
     "faculty": "Fakultät III – Medien, Information und Design",
     "pos": [
      {
       "po": "2023",
       "code": "mediendesigninformatik|b.sc.|mdi|2023",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|mediendesigninformatik|b.sc.|mdi|2023",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/Informatik/Modulhandbuecher/2024-04-29-modules-MDI-23WS-DE.pdf",
       "label": "Modulverzeichnis (Stand 29.04.2024 für Prüfungsordnung 2023-WS)"
      }
     ]
    },
    {
     "id": "verwaltungsinformatik-b-sc",
     "program": "Verwaltungsinformatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Verwaltungsinformatik",
      "Verwaltungsinformatik ( .)",
      "Verwaltungsinformatik (VIF)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/01-VIF-PO2026-26-06-16.pdf",
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2020",
       "code": "verwaltungsinformatik|b.sc.|vif|2020",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|verwaltungsinformatik|b.sc.|vif|2020",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/05-VIF-Studien-Modulhandbuch-PO2020-240301.pdf",
       "label": "Studien- und Modulhandbuch PO 2020"
      },
      {
       "po": "2025",
       "code": "verwaltungsinformatik|b.sc.|vif|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|verwaltungsinformatik|b.sc.|vif|2025",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/05-VIF-Modulhandbuch-VIF-Polizei-25-10-27.pdf",
       "label": "Modulhandbuch - PO 2025 Polizei"
      },
      {
       "po": "2026",
       "code": "verwaltungsinformatik|b.sc.|vif|2026",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|verwaltungsinformatik|b.sc.|vif|2026",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/26-09-23-VIF-Modulhandbuch.pdf",
       "label": "Modulhandbuch PO 2026"
      }
     ]
    },
    {
     "id": "wirtschaftsinformatik-b-sc",
     "program": "Wirtschaftsinformatik",
     "degree": "B.Sc.",
     "qis_names": [
      "Wirtschaftsinformatik",
      "Wirtschaftsinformatik ( .)",
      "Wirtschaftsinformatik (BIS)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/01-BIS-PO2026-30.07.2026_Verkuendungsblatt.pdf",
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2016",
       "code": "wirtschaftsinformatik|b.sc.|bis|2016",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|wirtschaftsinformatik|b.sc.|bis|2016",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/05-BIS-Studien-Modulhandbuch-PO2016.pdf",
       "label": "Studien- und Modulhandbuch PO 2016"
      },
      {
       "po": "2018",
       "code": "wirtschaftsinformatik|b.sc.|bis|2018",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|wirtschaftsinformatik|b.sc.|bis|2018",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/05-BIS-Studien-Modulhandbuch-BIS-PO_2018-25-10-07.pdf",
       "label": "Studien-Modulhandbuch PO 2018"
      },
      {
       "po": "2026",
       "code": "wirtschaftsinformatik|b.sc.|bis|2026",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|wirtschaftsinformatik|b.sc.|bis|2026",
       "format": "hsh-modul-code",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/WI/Ordnungen/26-11-02_Modulhandbuch.pdf",
       "label": "Modulhandbuch BIS PO 2026"
      }
     ]
    },
    {
     "id": "international-business-studies-b-sc",
     "program": "International Business Studies",
     "degree": "B.Sc.",
     "qis_names": [
      "International Business Studies",
      "International Business Studies ( .)",
      "International Business Studies (IBS)"
     ],
     "regular_semesters": 8,
     "total_lp": 240,
     "po_document_url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/BWL/IBS/IBS_Curriculum_RGU_PO_2018.pdf",
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2018",
       "code": "international-business-studies|b.sc.|ibs|2018",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hsh|international-business-studies|b.sc.|ibs|2018",
       "format": "hsh-code-kopf",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/BWL/Ordnungen/Modulhandbuch_IBS_PO_2018__2024__Stand_01_09_2025.pdf",
       "label": "Modulhandbuch (PO 2018)"
      }
     ]
    },
    {
     "id": "unternehmensentwicklung-m-sc",
     "program": "Unternehmensentwicklung",
     "degree": "M.Sc.",
     "qis_names": [
      "Unternehmensentwicklung",
      "Unternehmensentwicklung ( .)",
      "Unternehmensentwicklung (MBD)"
     ],
     "regular_semesters": 3,
     "total_lp": 90,
     "po_document_url": null,
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": [
      {
       "po": "2018",
       "code": "unternehmensentwicklung|m.sc.|mbd|2018",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2023"
       ],
       "study_plan": null,
       "key": "hsh|unternehmensentwicklung|m.sc.|mbd|2018",
       "format": "hsh-code-kopf",
       "url": "https://f4.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_IV/StudServ/OFI/BWL/Ordnungen/Modulhandbuch_MBD_final.pdf",
       "label": "Modulhandbuch MBD (PO 2018)"
      }
     ]
    },
    {
     "id": "mittelstaendische-unternehmensfuehrung-in-entrepreneurship-mba",
     "program": "Mittelständische Unternehmensführung in Entrepreneurship",
     "degree": "MBA",
     "qis_names": [
      "Mittelständische Unternehmensführung in Entrepreneurship",
      "Mittelständische Unternehmensführung in Entrepreneurship (MBA)",
      "MasterBachelorA Mittelständische Unternehmensführung in Entrepreneurship",
      "Mittelständische Unternehmensführung in Entrepreneurship (MMU)"
     ],
     "regular_semesters": 5,
     "total_lp": 150,
     "po_document_url": null,
     "faculty": "Fakultät IV – Wirtschaft und Informatik",
     "pos": []
    },
    {
     "id": "pflege-b-a",
     "program": "Pflege",
     "degree": "B.A.",
     "qis_names": [
      "Pflege",
      "Pflege ( .)",
      "Pflege (BDP)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "unbekannt",
       "code": "pflege|b.a.|bdp",
       "source": "hsh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "hsh|pflege|b.a.|bdp",
       "format": "hsh-modultitel",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Master/MEP/Modulhandbuecher/07.3-BDP-Modulhandbuch_BA_Pflege_Stand-2025_10_06_01.pdf",
       "label": "Modulhandbuch BA Pflege"
      }
     ]
    },
    {
     "id": "soziale-arbeit-grundstaendig-b-a",
     "program": "Soziale Arbeit - grundständig",
     "degree": "B.A.",
     "qis_names": [
      "Soziale Arbeit - grundständig",
      "Soziale Arbeit - grundständig ( .)",
      "Soziale Arbeit - grundständig (BSW)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Soziale_Arbeit_grundstaendig/Vorlesungsverzeichnis/VV-SoSe-2026/VV-BSW-PO-2026-SoSe-2026-klein.pdf",
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "2020",
       "code": "soziale-arbeit-grundstaendig|b.a.|bsw|2020",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2021"
       ],
       "study_plan": null,
       "key": "hsh|soziale-arbeit-grundstaendig|b.a.|bsw|2020",
       "format": "hsh-modul-nummer",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Soziale_Arbeit_grundstaendig/Modulhandbuch_BSW/012-MH-BSW-PO-2020-26.02.2021-Online.pdf",
       "label": "Modulhandbuch WiSe 2020 & SoSe 2021"
      },
      {
       "po": "2021",
       "code": "soziale-arbeit-grundstaendig|b.a.|bsw|2021",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|soziale-arbeit-grundstaendig|b.a.|bsw|2021",
       "format": "hsh-modul-nummer",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Soziale_Arbeit_grundstaendig/Modulhandbuch_BSW/021-MH-BSW-PO-2021-WiSe_2025-26-Stand-16.03.2025-web.pdf",
       "label": "Modulhandbuch WiSe 2025/26"
      },
      {
       "po": "2026",
       "code": "soziale-arbeit-grundstaendig|b.a.|bsw|2026",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hsh|soziale-arbeit-grundstaendig|b.a.|bsw|2026",
       "format": "hsh-modul-nummer",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Soziale_Arbeit_grundstaendig/Modulhandbuch_BSW/022-MH-BSW-PO-2026-Stand-16.03.2026-web.pdf",
       "label": "Modulhandbuch SoSe 2026"
      }
     ]
    },
    {
     "id": "religionspaedagogik-und-soziale-arbeit-b-a",
     "program": "Religionspädagogik und Soziale Arbeit",
     "degree": "B.A.",
     "qis_names": [
      "Religionspädagogik und Soziale Arbeit",
      "Religionspädagogik und Soziale Arbeit ( .)",
      "Religionspädagogik und Soziale Arbeit (BRS)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Relpaed/Vorlesungsverzeichnis/VV_SoSe-2026/VV-BRS-PO-2021-SoSe-2026-klein.pdf",
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "2018",
       "code": "religionspaedagogik-und-soziale-arbeit|b.a.|brs|2018",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|religionspaedagogik-und-soziale-arbeit|b.a.|brs|2018",
       "format": "hsh-modul-nummer",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Relpaed/Modulhandbuch/008-Modulhandbuch-BRS-PO-2018-2019-09-02-Online.pdf",
       "label": "Modulhandbuch"
      },
      {
       "po": "2020",
       "code": "religionspaedagogik-und-soziale-arbeit|b.a.|brs|2020",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2020/21"
       ],
       "study_plan": null,
       "key": "hsh|religionspaedagogik-und-soziale-arbeit|b.a.|brs|2020",
       "format": "hsh-modul-nummer",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Relpaed/Modulhandbuch/010_MH-BRS-PO-2020-WiSe-2020-21-Stand-11.08.2020-Online.pdf",
       "label": "Modulhandbuch"
      },
      {
       "po": "2021",
       "code": "religionspaedagogik-und-soziale-arbeit|b.a.|brs|2021",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|religionspaedagogik-und-soziale-arbeit|b.a.|brs|2021",
       "format": "hsh-modul-nummer",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Relpaed/Modulhandbuch/016-MH-BRS-PO-2021-WiSe-25-26-Stand-14.07.2025-web.pdf",
       "label": "Modulhandbuch"
      },
      {
       "po": "2026",
       "code": "religionspaedagogik-und-soziale-arbeit|b.a.|brs|2026",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2026/27"
       ],
       "study_plan": null,
       "key": "hsh|religionspaedagogik-und-soziale-arbeit|b.a.|brs|2026",
       "format": "hsh-modul-nummer",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Relpaed/Modulhandbuch/017-MH-BRS-PO-2026-WiSe-26-27-Stand-12.08.2026-web.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "therapeutische-arbeit-mit-kindern-und-jugendlichen-m-a",
     "program": "Therapeutische Arbeit mit Kindern und Jugendlichen",
     "degree": "M.A.",
     "qis_names": [
      "Therapeutische Arbeit mit Kindern und Jugendlichen",
      "Therapeutische Arbeit mit Kindern und Jugendlichen ( .)",
      "Therapeutische Arbeit mit Kindern und Jugendlichen (MTA)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": []
    },
    {
     "id": "management-fuer-pflege-und-gesundheitsberufe-m-a",
     "program": "Management für Pflege- und Gesundheitsberufe",
     "degree": "M.A.",
     "qis_names": [
      "Management für Pflege- und Gesundheitsberufe",
      "Management für Pflege- und Gesundheitsberufe ( .)",
      "Management für Pflege- und Gesundheitsberufe (MMG)"
     ],
     "regular_semesters": 6,
     "total_lp": 180,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "unbekannt",
       "code": "management-fuer-pflege-und-gesundheitsberufe|m.a.|mmg",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hsh|management-fuer-pflege-und-gesundheitsberufe|m.a.|mmg",
       "format": "hsh-modultitel",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Master/MGB__MBG__MMG/Mudulhandbuecher/07.5-MMG_Modulhandbuch_Stand_01.09.2026.pdf",
       "label": "Modulhandbuch"
      }
     ]
    },
    {
     "id": "lbs-sprint-berufliche-fachrichtung-pflege-master",
     "program": "LBS-Sprint - berufliche Fachrichtung Pflege",
     "degree": "Master",
     "qis_names": [
      "LBS-Sprint - berufliche Fachrichtung Pflege",
      "LBS-Sprint - berufliche Fachrichtung Pflege ( )",
      "Masteraster LBS-Sprint - berufliche Fachrichtung Pflege",
      "LBS-Sprint - berufliche Fachrichtung Pflege (MLP)"
     ],
     "regular_semesters": 4,
     "total_lp": 120,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "unbekannt",
       "code": "lbs-sprint-berufliche-fachrichtung-pflege|master|mlp",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2024"
       ],
       "study_plan": null,
       "key": "hsh|lbs-sprint-berufliche-fachrichtung-pflege|master|mlp",
       "format": "hsh-modultitel",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Master/MGB__MBG__MMG/Mudulhandbuecher/Modulbeschreibung_LBS_Sprint_FR_Pflege_09.09.2024_DS_DG.pdf",
       "label": "Modulbeschreibung"
      }
     ]
    },
    {
     "id": "soziale-arbeit-berufsbegleitend-b-a",
     "program": "Soziale Arbeit - berufsbegleitend",
     "degree": "B.A.",
     "qis_names": [
      "Soziale Arbeit - berufsbegleitend",
      "Soziale Arbeit - berufsbegleitend ( .)",
      "Soziale Arbeit - berufsbegleitend (SBW)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": null,
     "faculty": "Fakultät V – Diakonie, Gesundheit und Soziales",
     "pos": [
      {
       "po": "2017",
       "code": "soziale-arbeit-berufsbegleitend|b.a.|sbw|2017",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2017"
       ],
       "study_plan": null,
       "key": "hsh|soziale-arbeit-berufsbegleitend|b.a.|sbw|2017",
       "format": "hsh-code-kopf",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Soziale_Arbeit_berufsbgeleitend/Modulhandbuch_SBW/Modulhandbuch-SBW-seit_SoSe_2017.pdf",
       "label": "Modulhandbuch (gültig für Studierende mit Studienbeginn SoSe 2017 bis SoSe 2020)"
      },
      {
       "po": "2024",
       "code": "soziale-arbeit-berufsbegleitend|b.a.|sbw|2024",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2024"
       ],
       "study_plan": null,
       "key": "hsh|soziale-arbeit-berufsbegleitend|b.a.|sbw|2024",
       "format": "hsh-code-kopf",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Soziale_Arbeit_berufsbgeleitend/Modulhandbuch_SBW/Modulhandbuch-SBW-SoSe-2024-Stand-22.01.2024-web.pdf",
       "label": "Modulhandbuch (gültig für Studierende mit Studienbeginn SoSe 2021 bis SoSe 2023)"
      },
      {
       "po": "2025",
       "code": "soziale-arbeit-berufsbegleitend|b.a.|sbw|2025",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2025"
       ],
       "study_plan": null,
       "key": "hsh|soziale-arbeit-berufsbegleitend|b.a.|sbw|2025",
       "format": "hsh-code-kopf",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Soziale_Arbeit_berufsbgeleitend/Modulhandbuch_SBW/Modulhandbuch-SBW-SoSe-2025-Stand-05.02.2025.pdf",
       "label": "Modulhandbuch (gültig für Studierende mit Studienbeginn seit SoSe 2025)"
      },
      {
       "po": "2026",
       "code": "soziale-arbeit-berufsbegleitend|b.a.|sbw|2026",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "SS 2026"
       ],
       "study_plan": null,
       "key": "hsh|soziale-arbeit-berufsbegleitend|b.a.|sbw|2026",
       "format": "hsh-modul-code",
       "url": "https://f5.hs-hannover.de/fileadmin/HsH/Fakultaet_V/Bilder_Datein/Studium/Bachelor/Soziale_Arbeit_berufsbgeleitend/Modulhandbuch_SBW/Modulhandbuch_ab_SoSe26_Webversion_neu.pdf",
       "label": "Modulhandbuch (gültig für Studierende mit Studienbeginn seit SoSe 2026)"
      }
     ]
    },
    {
     "id": "elektrotechnik-und-informationstechnik-b-eng",
     "program": "Elektrotechnik und Informationstechnik",
     "degree": "B.Eng.",
     "qis_names": [
      "Elektrotechnik und Informationstechnik",
      "Elektrotechnik und Informationstechnik ( .)",
      "Elektrotechnik und Informationstechnik (EIT)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/10_Pruefungsordnungen/10_Bachelorstdg/EIT/BPO-EIT_2011-12-12.pdf",
     "faculty": "Fakultät I – Elektro- und Informationstechnik",
     "pos": [
      {
       "po": "2025",
       "code": "elektrotechnik-und-informationstechnik|b.eng.|eit|2025-adt",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|elektrotechnik-und-informationstechnik|b.eng.|eit|2025-adt",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/67_ADT_WS2025_Stand_15.04.2025_01.pdf",
       "label": "Vertiefung ADT"
      },
      {
       "po": "2025",
       "code": "elektrotechnik-und-informationstechnik|b.eng.|eit|2025-eae",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|elektrotechnik-und-informationstechnik|b.eng.|eit|2025-eae",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/68_EAE_WS2025_Stand_15.04.2025_01.pdf",
       "label": "Vertiefung EAE"
      },
      {
       "po": "2025",
       "code": "elektrotechnik-und-informationstechnik|b.eng.|eit|2025-sel",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|elektrotechnik-und-informationstechnik|b.eng.|eit|2025-sel",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/70_SEL_WS2025_Stand_15.04.2025_01.pdf",
       "label": "Vertiefung SEL"
      },
      {
       "po": "2025",
       "code": "elektrotechnik-und-informationstechnik|b.eng.|eit|2025-ski",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2025/26"
       ],
       "study_plan": null,
       "key": "hsh|elektrotechnik-und-informationstechnik|b.eng.|eit|2025-ski",
       "format": "hsh-modul-code",
       "url": "https://f1.hs-hannover.de/fileadmin/HsH/Fakultaet_I/20_Dokumente/10_Ordnungen/40_Modulkatalog/69_SKI_WS2025_Stand_15.04.2025_01.pdf",
       "label": "Vertiefung SKI"
      }
     ]
    },
    {
     "id": "verfahrenstechnik-energietechnik-und-umwelttechnik-b-eng",
     "program": "Verfahrenstechnik, Energietechnik und Umwelttechnik",
     "degree": "B.Eng.",
     "qis_names": [
      "Verfahrenstechnik, Energietechnik und Umwelttechnik",
      "Verfahrenstechnik, Energietechnik und Umwelttechnik ( .)",
      "Verfahrenstechnik, Energietechnik und Umwelttechnik (VEU)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/VEU/PO-VEU-2019-Verkuendungsblatt_Nr._04.2019_vom_31.08.2019.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2010",
       "code": "verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2010-et",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2010/11"
       ],
       "study_plan": null,
       "key": "hsh|verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2010-et",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/VEU-ET-WS2010-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Energietechnik VEU-ET (PO ab WS2010)"
      },
      {
       "po": "2010",
       "code": "verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2010-vu",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2010/11"
       ],
       "study_plan": null,
       "key": "hsh|verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2010-vu",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/VEU-VU-WS2010-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Verfahrens- und Umwelttechnik VEU-VU (PO ab WS2010)"
      },
      {
       "po": "2016",
       "code": "verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2016-et",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2016/17"
       ],
       "study_plan": null,
       "key": "hsh|verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2016-et",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/VEU-ET-WS2016-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Energietechnik VEU-ET (PO ab WS2016)"
      },
      {
       "po": "2016",
       "code": "verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2016-vu",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2016/17"
       ],
       "study_plan": null,
       "key": "hsh|verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2016-vu",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/VEU-VU-WS2016-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Verfahrens- und Umwelttechnik VEU-VU (PO ab WS2016)"
      },
      {
       "po": "2019",
       "code": "verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2019-et",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2019-et",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/VEU-ET-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch - VEU - ET"
      },
      {
       "po": "2019",
       "code": "verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2019-vu",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|verfahrenstechnik-energietechnik-und-umwelttechnik|b.eng.|veu|2019-vu",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/VEU-VU-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch - VEU - VU"
      }
     ]
    },
    {
     "id": "wertschoepfungsmanagement-im-maschinenbau-dual-m-eng",
     "program": "Wertschöpfungsmanagement im Maschinenbau dual",
     "degree": "M.Eng.",
     "qis_names": [
      "Wertschöpfungsmanagement im Maschinenbau dual",
      "Wertschöpfungsmanagement im Maschinenbau dual ( .)",
      "Wertschöpfungsmanagement im Maschinenbau dual (WMM)"
     ],
     "regular_semesters": null,
     "total_lp": null,
     "po_document_url": "https://f2.hs-hannover.de/fileadmin/HsH/Fakultaet_II/Abt_M/Dokumente/Ordnungen/WMM/WMM_PO_mit_Anlage_2019.pdf",
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2012",
       "code": "wertschoepfungsmanagement-im-maschinenbau-dual|m.eng.|wmm|2012-bo",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2012/13"
       ],
       "study_plan": null,
       "key": "hsh|wertschoepfungsmanagement-im-maschinenbau-dual|m.eng.|wmm|2012-bo",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WMM-BO-WS2012-Modulhandbuch.pdf",
       "label": "Modulhandbuch: WMM - Betriebsorganisation WMM-BO (dual, PO ab WS2012)"
      },
      {
       "po": "2012",
       "code": "wertschoepfungsmanagement-im-maschinenbau-dual|m.eng.|wmm|2012-pe",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2012/13"
       ],
       "study_plan": null,
       "key": "hsh|wertschoepfungsmanagement-im-maschinenbau-dual|m.eng.|wmm|2012-pe",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WMM-PE-WS2012-Modulhandbuch.pdf",
       "label": "Modulhandbuch: WMM - Produktentwicklung WMM-PE (dual, PO abWS2012)"
      },
      {
       "po": "2019",
       "code": "wertschoepfungsmanagement-im-maschinenbau-dual|m.eng.|wmm|2019-bo",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|wertschoepfungsmanagement-im-maschinenbau-dual|m.eng.|wmm|2019-bo",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WMM-BO-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch - WMM BO"
      },
      {
       "po": "2019",
       "code": "wertschoepfungsmanagement-im-maschinenbau-dual|m.eng.|wmm|2019-pe",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|wertschoepfungsmanagement-im-maschinenbau-dual|m.eng.|wmm|2019-pe",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/WMM-PE-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch - WMM PE"
      }
     ]
    },
    {
     "id": "maschinenbau-b-eng",
     "program": "Maschinenbau",
     "degree": "B.Eng.",
     "qis_names": [
      "Maschinenbau",
      "Maschinenbau ( .)",
      "Maschinenbau (MAB)"
     ],
     "regular_semesters": 7,
     "total_lp": 210,
     "po_document_url": null,
     "faculty": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
     "pos": [
      {
       "po": "2010",
       "code": "maschinenbau|b.eng.|mab|2010-am",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2010/11"
       ],
       "study_plan": null,
       "key": "hsh|maschinenbau|b.eng.|mab|2010-am",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MAB-AM-WS2010-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Allgemeiner Maschinenbau MAB-AM (PO ab WS2010)"
      },
      {
       "po": "2010",
       "code": "maschinenbau|b.eng.|mab|2010-ps",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2010/11"
       ],
       "study_plan": null,
       "key": "hsh|maschinenbau|b.eng.|mab|2010-ps",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MAB-PS-WS2010-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Produktionssysteme MAB-PS (PO ab WS2010)"
      },
      {
       "po": "2016",
       "code": "maschinenbau|b.eng.|mab|2016-am",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2016/17"
       ],
       "study_plan": null,
       "key": "hsh|maschinenbau|b.eng.|mab|2016-am",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MAB-AM-WS2016-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Allgemeiner Maschinenbau MAB-AM (PO ab WS2016)"
      },
      {
       "po": "2016",
       "code": "maschinenbau|b.eng.|mab|2016-ps",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2016/17"
       ],
       "study_plan": null,
       "key": "hsh|maschinenbau|b.eng.|mab|2016-ps",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MAB-PS-WS2016-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Produktionssysteme MAB-PS (PO ab WS2016)"
      },
      {
       "po": "2019",
       "code": "maschinenbau|b.eng.|mab|2019-am",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|maschinenbau|b.eng.|mab|2019-am",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MAB-AM-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Allgemeiner Maschinenbau MAB-AM (PO ab WS2019)"
      },
      {
       "po": "2019",
       "code": "maschinenbau|b.eng.|mab|2019-ps",
       "source": "hsh-grundstock",
       "catalog_terms": [
        "WS 2019/20"
       ],
       "study_plan": null,
       "key": "hsh|maschinenbau|b.eng.|mab|2019-ps",
       "format": "hsh-modultitel",
       "url": "https://f2.hs-hannover.de/fileadmin/HsH/Forms/Fakultaet_II/Modulhandbuecher/MAB-PS-WS2019-Modulhandbuch.pdf",
       "label": "Modulhandbuch: Produktionssysteme MAB-PS (PO ab WS2019)"
      }
     ]
    }
   ]
  }
 ],
 "po_rules": {
  "qis_label": "QIS-Spalte abschluss, z. B. 'Technische Informatik (PO-Version 2017)': Klammerzusatz '(PO-Version ...)' abtrennen, Name normalisieren (klein, Umlaute ausgeschrieben, nur Buchstaben und Ziffern), mit program und qis_names vergleichen.",
  "degree": "'Bachelor', 'B.Sc.', 'B. Sc.', 'Bachelor of Science' -> B.Sc.; 'Master', 'M.Sc.', 'Master of Science' -> M.Sc. Ohne Angabe gilt der erste passende Eintrag (Bachelor zuerst).",
  "po": "Gibt es die PO-Version aus QIS im Register, gilt sie. Sonst wird die neueste PO desselben Studiengangs vorgeschlagen (needs_confirmation=true); die Person bestaetigt oder aendert sie (settings.study_plan.po).",
  "term": "Neuestes Katalogsemester zuerst; ist das laufende Semester neuer als das neueste bekannte, wird es einmal angefragt (404 wird 30 Tage gemerkt)."
 }
}
"""#
}
