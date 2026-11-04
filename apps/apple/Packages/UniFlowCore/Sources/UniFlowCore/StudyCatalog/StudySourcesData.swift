// Erzeugt von tools/gen-study-catalog-fixture.py aus packages/shared-contracts/study-sources-all.json - nicht von Hand aendern.
enum StudySourcesData {
    static let json = #"""
{
 "v": 1,
 "note": "ERZEUGT von tools/gen-study-catalog-fixture.py aus study-sources.json (gepflegt, vorn) und study-sources-luh.json (alle LUH-Studiengaenge; Quelle luh-grundstock = nur aus dem Grundstock der App) - nicht von Hand aendern. Register der Modulkatalog-Quellen (docs/STUDIENVERLAUF-2026-11-04.md). Nur oeffentliche Kataloge ohne Anmeldung. Die breite Erhebung aller LUH-Studiengaenge steht in study-sources-luh.json (tools/luh-programs.py); hier stehen nur Quellen, deren Format der Parser liest. study_plan je PO (null = keiner bekannt): Studienverlaufsplan der Fakultaet (format luh-fei-verlaufsplan, eine PDF-Seite, Semester als Zeilen); page_url = Seite des Studiengangs, auf der der aktuelle Plan verlinkt ist.",
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "fbg-modulhandbuch"
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
       "format": "fbg-modulhandbuch"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "luh-modulbeschreibung"
      },
      {
       "po": "2024",
       "code": "chemie-1|m.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie-1|m.sc.|2024",
       "format": "scanned"
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
       "format": "luh-modulbeschreibung"
      },
      {
       "po": "2024",
       "code": "chemie|b.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|chemie|b.sc.|2024",
       "format": "scanned"
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
       "format": "fbg-modulhandbuch"
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
       "format": "wiwi-modulhandbuch"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "scanned"
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
       "format": "modkat-FEI"
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
       "format": "luh-modulbeschreibung"
      },
      {
       "po": "2026",
       "code": "landschaftswissenschaften|m.sc.|2026",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|landschaftswissenschaften|m.sc.|2026",
       "format": "luh-modulbeschreibung"
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
       "format": "scanned"
      },
      {
       "po": "2024",
       "code": "life-science-1-1|m.sc.|2024",
       "source": "luh-grundstock",
       "catalog_terms": [],
       "study_plan": null,
       "key": "luh|life-science-1-1|m.sc.|2024",
       "format": "scanned"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "maphy-katalog"
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
       "format": "maphy-katalog"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "mb-modulkatalog"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "maphy-katalog"
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
       "format": "maphy-katalog"
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
       "format": "phil-kv-tabelle"
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
       "format": "phil-kv-tabelle"
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
       "format": "mb-modulkatalog"
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
       "format": "mb-modulkatalog"
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
       "format": "luh-modulbeschreibung"
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
       "format": "scanned"
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
       "format": "phil-kv-tabelle"
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
       "format": "phil-kv-tabelle"
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
       "format": "luh-modulbeschreibung"
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
       "format": "scanned"
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
       "format": "modkat-FEI"
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
       "format": "fbg-modulhandbuch"
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
       "format": "maphy-katalog"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "wiwi-modulhandbuch"
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
       "format": "wiwi-modulhandbuch"
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
       "format": "wiwi-modulhandbuch"
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
       "format": "wiwi-modulhandbuch"
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
       "format": "mb-modulkatalog"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "modkat-FEI"
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
       "format": "mb-modulkatalog"
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
       "format": "modkat-FEI"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "scanned"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "modkat-FEI"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "luh-modulbeschreibung"
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
       "format": "phil-kv-tabelle"
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
       "format": "phil-kv-tabelle"
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
       "format": "phil-kv-tabelle"
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
       "format": "phil-kv-tabelle"
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
       "format": "phil-kv-tabelle"
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
       "format": "scanned"
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
       "format": "luh-modulbeschreibung"
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
