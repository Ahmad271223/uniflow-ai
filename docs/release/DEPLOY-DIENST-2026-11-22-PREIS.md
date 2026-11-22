# Dienst 22.11.2026: Preis der StudiNow-Erklärungen auf 2 Credits

Auf Wunsch des Inhabers („mach billiger kurz für 2 Credit“) in `deploy/.env` des Dienstes `LERNAPP_ERKLAERUNG_PREIS=2`
gesetzt (Kopie davor: `.env.vor-preis-2-2026-11-22`), `docker compose up -d`. Danach: Container healthy, im Container
Preis 2, 59 PDFs im Angebot. Kein Code geändert. Zurück auf 15: Zeile auf `15` setzen oder entfernen, `docker compose up -d`.
Ob „kurz“ nur für den Test gemeint ist, ist nicht geklärt.
