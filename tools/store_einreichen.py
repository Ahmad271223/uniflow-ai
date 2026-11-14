"""Version im App Store anlegen und fuellen (14.11.2026). Aufruf im Projektordner:
    .venv/bin/python tools/store_einreichen.py texte   1.0.4          # Version anlegen, Texte und Pruefhinweise aus APP-STORE.md
    .venv/bin/python tools/store_einreichen.py bilder  1.0.4          # Bildschirmfotos iPad 13" und iPhone 6,9" ersetzen
    .venv/bin/python tools/store_einreichen.py build   1.0.4 40       # Build waehlen
    .venv/bin/python tools/store_einreichen.py senden  1.0.4          # zur Pruefung einreichen (nur mit Okay des Inhabers)
Texte kommen aus den Bloecken `description-proai`, `whats-new-proai`, `keywords`, `promo`, `review-notes-proai` in
docs/release/APP-STORE.md (von tests/test_release_texts.py geprueft). Freigabe nach der Pruefung von Hand (MANUAL)."""
import hashlib, pathlib, re, sys, time, urllib.error, urllib.request
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from asc import call

APP = "6830632088"
ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILDS = pathlib.Path.home() / "Studora-Builds"
SHOTS = {
    "APP_IPAD_PRO_3GEN_129": (BUILDS / "appstore-screenshots-final-2026-11-13", [
        "01-uebersicht-light.png", "02-ki-frage-dark.png", "03-ki-karteikarten-light.png", "04-community-diskussion-dark.png",
        "05-uni-mail-light.png", "06-stundenplan-termin-light.png", "07-skript-uebung-stift-dark.png", "08-wochentest-ki-dark.png",
        "09-raumfinder-light.png", "10-mensa-light.png"]),
    "APP_IPHONE_67": (BUILDS / "appstore-screenshots-iphone-2026-11-14", [
        "01-start-light-portrait.png", "02-lernkalender-light-portrait.png", "03-modul-light-portrait.png",
        "04-uni-mail-ki-light-portrait.png", "05-ki-hilfe-light-portrait.png", "06-studienverlauf-light-portrait.png",
        "07-mensa-light-portrait.png"]),
}


def ok(st, d, what):
    if st >= 300:
        raise SystemExit(f"{what}: {st} {d}")
    return d


def field(name):
    text = (ROOT / "docs/release/APP-STORE.md").read_text(encoding="utf-8")
    return re.search(r"```text " + re.escape(name) + r"\n(.*?)\n```", text, re.S).group(1)


def version(vs, create=False):
    d = ok(*call("GET", f"/v1/apps/{APP}/appStoreVersions?filter[versionString]={vs}&filter[platform]=IOS"), "Version suchen")
    if d["data"]:
        return d["data"][0]["id"]
    if not create:
        raise SystemExit(f"Version {vs} gibt es noch nicht")
    d = ok(*call("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions", "attributes": {
        "platform": "IOS", "versionString": vs, "releaseType": "MANUAL"}, "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}}),
        "Version anlegen")
    print("Version angelegt", vs)
    return d["data"]["id"]


def localization(vid):
    d = ok(*call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"), "Lokalisierung")
    return next(l for l in d["data"] if l["attributes"]["locale"] == "de-DE")["id"]


def texte(vs):
    vid = version(vs, create=True)
    lid = localization(vid)
    attrs = {"description": field("description-proai"), "keywords": field("keywords"), "whatsNew": field("whats-new-proai"),
             "promotionalText": field("promo")}
    ok(*call("PATCH", f"/v1/appStoreVersionLocalizations/{lid}", {"data": {"type": "appStoreVersionLocalizations", "id": lid, "attributes": attrs}}),
       "Texte")
    print("Texte", {k: len(v) for k, v in attrs.items()})
    st, d = call("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")
    notes = field("review-notes-proai")
    if st == 200 and d.get("data"):
        rid = d["data"]["id"]
        ok(*call("PATCH", f"/v1/appStoreReviewDetails/{rid}", {"data": {"type": "appStoreReviewDetails", "id": rid, "attributes": {"notes": notes}}}),
           "Pruefhinweise")
    else:
        ok(*call("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": {"notes": notes, "demoAccountRequired": False},
           "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}), "Pruefhinweise anlegen")
    print("Pruefhinweise", len(notes))


def upload(set_id, path):
    data = path.read_bytes()
    d = ok(*call("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": path.name, "fileSize": len(data)},
           "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}}), f"Bild {path.name}")
    sid = d["data"]["id"]
    for op in d["data"]["attributes"]["uploadOperations"]:
        req = urllib.request.Request(op["url"], method=op["method"], data=data[op["offset"]:op["offset"] + op["length"]],
                                     headers={h["name"]: h["value"] for h in op["requestHeaders"]})
        for attempt in range(5):                  # Netzfehler beim Hochladen der Bilddaten wiederholen
            try:
                with urllib.request.urlopen(req, timeout=180) as r:
                    assert r.status < 300, r.status
                break
            except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as e:
                if attempt == 4 or isinstance(e, urllib.error.HTTPError):
                    raise
                print("  Netzfehler, neuer Versuch:", type(e).__name__)
                time.sleep(15 * (attempt + 1))
    ok(*call("PATCH", f"/v1/appScreenshots/{sid}", {"data": {"type": "appScreenshots", "id": sid, "attributes": {
        "uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}}), f"Bild {path.name} abschliessen")
    print("  hochgeladen", path.name)


def bilder(vs):
    lid = localization(version(vs))
    sets = ok(*call("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets?limit=50"), "Bildsaetze")["data"]
    by_type = {s["attributes"]["screenshotDisplayType"]: s["id"] for s in sets}
    print("vorhandene Saetze", sorted(by_type))
    for kind, (folder, names) in SHOTS.items():
        for n in names:
            assert (folder / n).is_file(), folder / n
        sid = by_type.get(kind)
        if sid is None:
            sid = ok(*call("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": kind},
                     "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}}}), f"Satz {kind}")["data"]["id"]
        else:
            for old in ok(*call("GET", f"/v1/appScreenshotSets/{sid}/appScreenshots?limit=50"), "alte Bilder")["data"]:
                ok(*call("DELETE", f"/v1/appScreenshots/{old['id']}"), "altes Bild loeschen")
        print(kind, len(names), "Bilder")
        for n in names:
            upload(sid, folder / n)
    time.sleep(20)
    for kind in SHOTS:
        sid = {s["attributes"]["screenshotDisplayType"]: s["id"] for s in ok(*call("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets?limit=50"), "Saetze")["data"]}[kind]
        shots = ok(*call("GET", f"/v1/appScreenshotSets/{sid}/appScreenshots?limit=50"), "Bilder pruefen")["data"]
        print(kind, [(s["attributes"]["fileName"], (s["attributes"].get("assetDeliveryState") or {}).get("state")) for s in shots])


def build(vs, number):
    vid = version(vs)
    d = ok(*call("GET", f"/v1/builds?filter[app]={APP}&filter[version]={number}&limit=5"), "Build suchen")
    b = d["data"][0]
    assert b["attributes"]["processingState"] == "VALID", b["attributes"]["processingState"]
    ok(*call("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": b["id"]}}), "Build waehlen")
    print("Build", number, "gewaehlt")


def senden(vs):
    vid = version(vs)
    d = ok(*call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
           "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}}), "Einreichung anlegen")
    rid = d["data"]["id"]
    ok(*call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rid}},
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}), "Version zur Einreichung")
    d = ok(*call("PATCH", f"/v1/reviewSubmissions/{rid}", {"data": {"type": "reviewSubmissions", "id": rid, "attributes": {"submitted": True}}}), "Einreichen")
    print("eingereicht:", d["data"]["attributes"].get("state"))
    st, v = call("GET", f"/v1/appStoreVersions/{vid}")
    print("Version", v["data"]["attributes"]["versionString"], v["data"]["attributes"]["appStoreState"])


if __name__ == "__main__":
    cmd, vs = sys.argv[1], sys.argv[2]
    {"texte": lambda: texte(vs), "bilder": lambda: bilder(vs), "build": lambda: build(vs, sys.argv[3]), "senden": lambda: senden(vs)}[cmd]()
