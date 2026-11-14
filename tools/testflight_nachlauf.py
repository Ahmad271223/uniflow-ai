"""TestFlight-Nachlauf nach dem Upload eines Builds (13.11.2026, aus der Sitzung uebernommen).
Aufruf im Projektordner:  .venv/bin/python tools/testflight_nachlauf.py tools
Wartet, bis Apple den Build (filter[version]=NN unten) als VALID meldet, schreibt den Testhinweis (NOTES, de-DE; vorhandene
Lokalisierung wird ersetzt), haengt ihn an die Gruppe "LUH-Tester" und reicht ihn zur Beta-Pruefung ein (422
ANOTHER_BUILD_IN_REVIEW = ein frueherer Build der Version wird noch geprueft -> tools/testflight_beta_einreichen.py).
VOR JEDEM LAUF: Buildnummer (filter[version]=..., bNN.txt) und NOTES anpassen. Die Datei bNN.txt (Build-ID) landet in tools/
und wird nicht committet (.gitignore)."""
import sys, time, json
sys.path.insert(0, sys.argv[1])
from asc import call
APP = "6830632088"; GROUP = "3541cafb-8a8c-4766-bb7a-bf29ef622cde"
NOTES = ("Build 40 (Version 1.0.4) – iPad und iPhone. Neu:\n"
         "• Universität Hildesheim (Learnweb, LSF) ist jetzt wählbar – bitte mit Hildesheim-Konto testen\n"
         "• Sonst wie Build 39: Rückgängig, Formen erkennen, Blatt daneben, Uni-Mail, Haken „erledigt“\n"
         "Fehler bitte per Screenshot in TestFlight melden.")
bid = None
for _ in range(90):
    st, d = call("GET", f"/v1/builds?filter[app]={APP}&filter[version]=40&limit=5")
    items = (d or {}).get("data") or []
    if items:
        b = items[0]; bid = b["id"]; state = b["attributes"]["processingState"]
        if state == "VALID": break
        if state in ("FAILED", "INVALID"): print("Build", state); sys.exit(1)
    time.sleep(30)
print(time.strftime("%H:%M"), "VALID", bid)
open(sys.argv[1] + "/b40.txt", "w").write(bid)
st, d = call("GET", f"/v1/builds/{bid}/betaBuildLocalizations")
loc = next((l for l in (d or {}).get("data", []) if l["attributes"]["locale"] == "de-DE"), None)
if loc:
    st, d = call("PATCH", f"/v1/betaBuildLocalizations/{loc['id']}", {"data": {"type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": NOTES}}})
else:
    st, d = call("POST", "/v1/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "de-DE", "whatsNew": NOTES},
                 "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
print("Testhinweis", st, "" if st < 300 else d)
for i in range(6):
    st, d = call("POST", f"/v1/betaGroups/{GROUP}/relationships/builds", {"data": [{"type": "builds", "id": bid}]})
    if st < 300: break
    time.sleep(30)
print("LUH-Tester", st, None if st < 300 else d)
st, d = call("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
print("Betapruefung", st, (d or {}).get("data", {}).get("attributes") if st < 300 else d)
st, d = call("GET", f"/v1/builds/{bid}/buildBetaDetail")
print("Stand", (d or {}).get("data", {}).get("attributes"))
