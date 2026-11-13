"""Build zur TestFlight-Beta-Pruefung einreichen, sobald Apple den vorherigen Build derselben Version fertig geprueft hat
(alle 10 Minuten, hoechstens 24 Stunden). Aufruf:  .venv/bin/python tools/testflight_beta_einreichen.py tools b39.txt
(bNN.txt schreibt tools/testflight_nachlauf.py)."""
import sys, time
sys.path.insert(0, sys.argv[1])
from asc import call
b37 = open(sys.argv[1] + "/" + sys.argv[2]).read().strip()
for i in range(144):                      # hoechstens 24 Stunden, alle 10 Minuten
    st, d = call("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": b37}}}}})
    if st < 300:
        print(time.strftime("%d.%m. %H:%M"), "Build zur Betapruefung eingereicht", d["data"]["attributes"]); break
    code = (d or {}).get("errors", [{}])[0].get("code", "")
    if "ANOTHER_BUILD_IN_REVIEW" not in code:
        print(time.strftime("%d.%m. %H:%M"), "Fehler", st, d); break
    time.sleep(600)
else:
    print("nach 24 Stunden aufgegeben")
