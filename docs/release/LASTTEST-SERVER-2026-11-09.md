# Lasttest auf dem Server 20261109-045139

Container uniflow-lasttest-20261109-045139 aus uniflow-app:latest, --network none, 6144 MB, 6 CPUs, 12 API-Prozesse. Phasen: restore ki anmeldung dauer

## Produktion vorher
```
zeit=2026-11-09T04:51:40+01:00
repo_commit=unbekannt
image_lasttest=sha256:f98ed2a6e8b6fb604191440a48d0c31ed087dc7083940547609a31ea389d8d43 2026-11-09T01:45:02.694062387Z
container=/uniflow-app running healthy 0
  image=sha256:f98ed2a6e8b6fb604191440a48d0c31ed087dc7083940547609a31ea389d8d43 2026-11-09T01:45:04.000177567Z mem=8589934592
  env LERNAPP_JOB_WORKERS=4
  env LERNAPP_LIMIT_REGISTER_IP=2000/60
  env LERNAPP_AI_BUDGET_EUR=600
  env UVICORN_WORKERS=12
  env LERNAPP_LIMIT_RESET_IP=300/60
  env LERNAPP_JOBS=off
  env LERNAPP_UPLOAD_QUOTA_MB=512
  env LERNAPP_LIMIT_REGISTER_ALL=3000/60
  env LERNAPP_LIMIT_API_PER_MIN=300
  env WEB_CONCURRENCY=12
  env LERNAPP_MODE=hosted
  env LERNAPP_LOGIN_FAILS_IP=500
  env LERNAPP_DISK_MIN_FREE_MB=5120
  env LERNAPP_AI_TRIAL_BUDGET_EUR=200
container=/uniflow-jobs running healthy 0
  image=sha256:f98ed2a6e8b6fb604191440a48d0c31ed087dc7083940547609a31ea389d8d43 2026-11-09T01:45:05.041118824Z mem=1610612736
  env LERNAPP_MODE=hosted
  env LERNAPP_JOB_WORKERS=4
  env LERNAPP_AI_TRIAL_BUDGET_EUR=200
  env LERNAPP_LIMIT_REGISTER_ALL=3000/60
  env LERNAPP_LIMIT_API_PER_MIN=300
  env LERNAPP_LOGIN_FAILS_IP=500
  env LERNAPP_AI_BUDGET_EUR=600
  env LERNAPP_UPLOAD_QUOTA_MB=512
  env LERNAPP_LIMIT_REGISTER_IP=2000/60
  env UVICORN_WORKERS=12
  env LERNAPP_DISK_MIN_FREE_MB=5120
  env LERNAPP_LIMIT_RESET_IP=300/60
  env WEB_CONCURRENCY=4
container=/uniflow-caddy running - 0
  image=sha256:ce773ec7a742ce15ee6bf2bb5f65882b9e2a4487b10733e6f1484f86e6b5d8bc 2026-11-08T14:41:11.726993976Z mem=0
cpus=8 mem_total_mb=15603 mem_avail_mb=14027
```

## Phase restore
```
{
  "archive_bytes": 224866,
  "files": 7,
  "created": "2026-11-09T02:32:55+00:00",
  "accounts_db": true,
  "extract_s": 0.0,
  "integrity": {
    "ok": 6,
    "bad": 0,
    "bad_where": []
  },
  "counts": {
    "users_active": 1,
    "users_deleted": 2,
    "entitlements": 3,
    "user_dbs": 0
  },
  "service": {
    "started": true,
    "start_s": 1.9,
    "samples": 1,
    "status": {
      "/api/account/me": {
        "200": 1
      },
      "/api/entitlements": {
        "200": 1
      },
      "/api/sync/changes": {
        "200": 1
      }
    },
    "ok": true
  },
  "restore_s": 2.7,
  "ok": true
}
ERGEBNIS: Wiederherstellung vollstaendig, Dienst laeuft auf den Daten
```

## Phase ki
```
Code: /srv/uniflow  Daten: /lt/tmp/lasttest-ki-sn4uq0g0
400 Konten angelegt in 3.9 s
Vergleich ohne Last: p50 56 ms, p95 323 ms
| Messgroesse                                 | Wert |
| ------------------------------------------- | ---- |
| Stand                                       | server |
| Prozesse                                    | 12 |
| KI-Fragen gleichzeitig                      | 4000 |
| Schein-Antwortzeit                          | 10 s + 0..10 s |
| KI beantwortet                              | 4000 / 4000 |
| KI-Fehler                                   | keine |
| KI-Dauer p50 / p95 / max                    | 27.6 s / 39.1 s / 41.9 s |
| KI-Durchsatz                                | 82 Fragen/s (alle 4000 in 49.0 s) |
| Normale Anfragen ohne Last p50 / p95        | 56 ms / 323 ms |
| Normale Anfragen UNTER Last p50 / p95 / max | 123 ms / 2143 ms / 6618 ms (300 Anfragen, 0 Fehler) |
|   davon entitlements p50 / p95              | 108 ms / 2143 ms |
|   davon login p50 / p95                     | 182 ms / 2270 ms |
|   davon sync p50 / p95                      | 104 ms / 1234 ms |
| Speicher je Prozess (MB) ohne Last          | 86, 86, 85, 85, 85, 201, 104, 85, 85, 85, 85, 85 |
| Speicher je Prozess (MB) Spitze             | 243, 210, 236, 276, 135, 271, 164, 241, 154, 155, 178, 293 |
```

## Phase anmeldung
```
Dienst: /srv/uniflow auf http://127.0.0.1:52905, 12 Prozesse, Datenordner /lt/tmp/lasttest-anmeldung-zlitia07
Umgebung: LERNAPP_LIMIT_REGISTER_IP=2000/60, LERNAPP_LIMIT_REGISTER_ALL=3000/60, LERNAPP_LOGIN_FAILS_IP=500, LERNAPP_LIMIT_API_PER_MIN=300, LERNAPP_UPLOAD_QUOTA_MB=512
  1 Registrieren (1000, eine IP)     n=1000  ok=1000  Fehler=0     p50=  470 ms  p95= 1123 ms  max=  3263 ms  117.5/s  Status {'201': 1000}
  2 Anmelden (4000, 3 % falsch)      n=4000  ok=4000  Fehler=0     p50=  455 ms  p95=  741 ms  max=  2001 ms  137.9/s  Status {'200': 3892, '401': 108}
  3 Abgleich push (4000)             n=4000  ok=4000  Fehler=0     p50=   99 ms  p95=  645 ms  max=  1220 ms  367.5/s  Status {'200': 4000}
  4 Gemischt (3000)                  n=3000  ok=3000  Fehler=0     p50=  109 ms  p95=  699 ms  max=  2880 ms  291.2/s  Status {'200': 2970, '401': 30}

| Phase (server) | n | ok | Fehler | p50 ms | p95 ms | max ms | Anfr./s | Status |
|---|---|---|---|---|---|---|---|---|
| 1 Registrieren (1000, eine IP) | 1000 | 1000 | 0 | 470 | 1123 | 3263 | 117.5 | 201: 1000 |
| 2 Anmelden (4000, 3 % falsch) | 4000 | 4000 | 0 | 455 | 741 | 2001 | 137.9 | 200: 3892, 401: 108 |
| 3 Abgleich push (4000) | 4000 | 4000 | 0 | 99 | 645 | 1220 | 367.5 | 200: 4000 |
| 4 Gemischt (3000) | 3000 | 3000 | 0 | 109 | 699 | 2880 | 291.2 | 200: 2970, 401: 30 |

Konten: 1000; Datenordner 319.6 MB; RSS je Prozess am Ende: [17.0, 322.4, 322.8, 289.3, 288.8, 322.5, 483.5, 273.0, 289.8, 272.8, 288.4, 305.6, 419.5] MB (Start [17.0, 85.2, 68.3, 69.0, 68.0, 85.4, 86.1, 67.9, 68.5, 68.3, 68.2, 67.8, 85.2]); 12 Prozesse, 64 parallele Clients, Python 3.12.16, 8 CPUs
JSON: /lt/out/anmeldung.json
```

## Phase dauer
```
  Minute  30: n=24214  Fehler=0     ohne KI p50=   11 p95=   52 p99=   186 ms (Dienst p95 52 ms, Verzug Lastgeber p95 1 ms) KI p95=19594 ms WAL=0.0 MB RSS=[17.0, 487.3, 472.6, 490.1, 525.8, 430.1, 362.8, 373.3, 505.3, 481.4, 475.4, 349.5, 367.5] Status={'200': 24214}
  Sturm: {'n': 11169, 'wall_s': 60.6, 'errors': 0, 'status': {'200': 11169}, 'p50_ms': 15, 'p95_ms': 37, 'p99_ms': 56}
  bestaetigte Schreibvorgaenge: 296390, davon fehlend: 0
| Minute (server) | n | Fehler | ohne KI p50 / p95 / p99 ms | Dienst p95 ms | Verzug Lastgeber p95 ms | KI p95 ms | WAL MB | RSS je Prozess MB |
|---|---|---|---|---|---|---|---|---|
| 1 | 23682 | 166 | 15 / 3631 / 5489 | 1301 | 2975 | 21828 | 0.0 | 17, 751, 591, 595, 471, 514, 471, 472, 523, 428, 295, 264, 249 |
| 2 | 23994 | 0 | 11 / 49 / 146 | 49 | 1 | 19684 | 0.3 | 17, 592, 487, 514, 471, 472, 525, 429, 360, 363, 418, 243, 220 |
| 3 | 24013 | 0 | 11 / 54 / 222 | 53 | 1 | 19684 | 0.0 | 17, 592, 487, 514, 487, 488, 525, 429, 360, 364, 451, 452, 430 |
| 4 | 23997 | 0 | 11 / 48 / 145 | 48 | 0 | 19634 | 0.7 | 17, 592, 487, 514, 487, 488, 525, 429, 360, 364, 453, 470, 449 |
| 5 | 23991 | 0 | 11 / 48 / 180 | 48 | 0 | 19621 | 0.0 | 17, 592, 487, 514, 487, 488, 525, 429, 361, 366, 453, 472, 470 |
| 6 | 24024 | 0 | 11 / 50 / 189 | 50 | 1 | 19546 | 0.0 | 17, 592, 487, 530, 455, 488, 525, 429, 361, 366, 454, 474, 472 |
| 7 | 23978 | 0 | 11 / 59 / 241 | 59 | 1 | 19518 | 0.0 | 17, 592, 487, 530, 471, 488, 525, 429, 361, 367, 456, 492, 490 |
| 8 | 24012 | 0 | 11 / 49 / 153 | 49 | 0 | 19524 | 0.3 | 17, 592, 487, 530, 471, 488, 525, 429, 361, 367, 457, 496, 492 |
| 9 | 24029 | 0 | 11 / 54 / 213 | 53 | 1 | 19644 | 0.2 | 17, 592, 487, 530, 471, 488, 525, 429, 361, 367, 458, 499, 495 |
| 10 | 23971 | 0 | 11 / 55 / 237 | 54 | 1 | 19622 | 0.0 | 17, 592, 487, 530, 471, 488, 525, 429, 361, 369, 498, 500, 500 |
| 11 | 24004 | 2 | 11 / 53 / 194 | 52 | 1 | 19497 | 0.0 | 17, 487, 530, 471, 488, 525, 429, 361, 369, 497, 534, 501, 385 |
| 12 | 23979 | 0 | 11 / 61 / 201 | 61 | 1 | 19586 | 0.6 | 17, 487, 530, 471, 488, 525, 429, 361, 369, 498, 536, 552, 453 |
| 13 | 23995 | 0 | 11 / 57 / 242 | 56 | 1 | 19548 | 3.1 | 17, 487, 530, 471, 488, 525, 429, 361, 369, 498, 537, 552, 474 |
| 14 | 24044 | 0 | 11 / 60 / 248 | 59 | 1 | 19538 | 0.0 | 17, 487, 530, 471, 488, 525, 430, 361, 369, 500, 539, 552, 490 |
| 15 | 23988 | 0 | 11 / 63 / 242 | 63 | 1 | 19701 | 1.5 | 17, 487, 530, 471, 488, 525, 430, 361, 369, 500, 541, 555, 492 |
| 16 | 24030 | 0 | 11 / 57 / 199 | 57 | 1 | 19677 | 0.0 | 17, 487, 530, 472, 488, 525, 430, 361, 371, 500, 541, 555, 496 |
| 17 | 23947 | 0 | 11 / 52 / 192 | 52 | 1 | 19539 | 0.0 | 17, 487, 530, 472, 488, 525, 430, 361, 371, 500, 544, 557, 498 |
| 18 | 23988 | 0 | 11 / 54 / 241 | 53 | 1 | 19609 | 0.0 | 17, 487, 530, 472, 488, 525, 430, 361, 373, 500, 546, 560, 502 |
| 19 | 24076 | 69 | 11 / 54 / 194 | 54 | 1 | 19513 | 0.0 | 17, 487, 530, 472, 488, 525, 430, 361, 373, 500, 548, 520, 235 |
| 20 | 23960 | 0 | 11 / 55 / 198 | 55 | 1 | 19572 | 0.6 | 17, 487, 530, 472, 488, 525, 430, 361, 373, 501, 550, 522, 403 |
| 21 | 24010 | 69 | 11 / 57 / 247 | 56 | 1 | 19589 | 0.0 | 17, 487, 530, 473, 488, 525, 430, 361, 373, 501, 522, 541, 333 |
| 22 | 23973 | 0 | 11 / 56 / 240 | 56 | 1 | 19630 | 0.0 | 17, 487, 530, 473, 488, 525, 430, 363, 373, 502, 522, 545, 485 |
| 23 | 24095 | 96 | 11 / 62 / 242 | 62 | 1 | 19382 | 0.0 | 17, 487, 530, 473, 488, 525, 430, 363, 373, 502, 524, 491, 164 |
| 24 | 23927 | 0 | 11 / 54 / 236 | 54 | 0 | 19542 | 0.0 | 17, 487, 530, 473, 488, 525, 430, 363, 373, 502, 524, 526, 419 |
| 25 | 23967 | 0 | 11 / 60 / 241 | 60 | 1 | 19527 | 0.0 | 17, 487, 530, 473, 488, 526, 430, 363, 373, 503, 525, 527, 471 |
| 26 | 24002 | 0 | 11 / 54 / 192 | 53 | 0 | 19577 | 0.0 | 17, 487, 473, 490, 526, 430, 363, 373, 505, 527, 527, 477 |
| 27 | 23998 | 0 | 11 / 53 / 188 | 53 | 1 | 19718 | 0.4 | 17, 487, 473, 490, 526, 430, 363, 373, 505, 527, 527, 478, 354 |
| 28 | 23983 | 0 | 11 / 63 / 249 | 63 | 1 | 19619 | 2.3 | 17, 487, 473, 490, 526, 430, 363, 373, 505, 527, 530, 478, 472 |
| 29 | 24129 | 99 | 11 / 65 / 241 | 65 | 1 | 19652 | 0.0 | 17, 487, 473, 490, 526, 430, 363, 373, 505, 480, 475, 52, 51 |
| 30 | 24214 | 0 | 11 / 52 / 186 | 52 | 1 | 19594 | 0.0 | 17, 487, 473, 490, 526, 430, 363, 373, 505, 481, 475, 350, 368 |

Gesamt 720000 Anfragen, 501 Fehler (0.07 %); 3723 Sitzungen auf 960 Konten, 400.0 Anfragen/s geplant, 12 Prozesse
API-Prozess hart beendet nach 600.0 s, Ersatz nach 1.0 s
Sturm: 11169 Anfragen in 60.6 s, 0 Fehler, p50/p95/p99 15/37/56 ms
Bestaetigte Schreibvorgaenge 296390, fehlend 0
```

## Host (Spitzen)
CPU belegt max 76.2 %, MemAvailable min 7815 MB, load1 max 45.73 (290 Proben)

## Produktion nachher
```
zeit=2026-11-09T05:25:52+01:00
repo_commit=unbekannt
image_lasttest=sha256:f98ed2a6e8b6fb604191440a48d0c31ed087dc7083940547609a31ea389d8d43 2026-11-09T01:45:02.694062387Z
container=/uniflow-app running healthy 0
  image=sha256:f98ed2a6e8b6fb604191440a48d0c31ed087dc7083940547609a31ea389d8d43 2026-11-09T01:45:04.000177567Z mem=8589934592
  env LERNAPP_JOB_WORKERS=4
  env LERNAPP_LIMIT_REGISTER_IP=2000/60
  env LERNAPP_AI_BUDGET_EUR=600
  env UVICORN_WORKERS=12
  env LERNAPP_LIMIT_RESET_IP=300/60
  env LERNAPP_JOBS=off
  env LERNAPP_UPLOAD_QUOTA_MB=512
  env LERNAPP_LIMIT_REGISTER_ALL=3000/60
  env LERNAPP_LIMIT_API_PER_MIN=300
  env WEB_CONCURRENCY=12
  env LERNAPP_MODE=hosted
  env LERNAPP_LOGIN_FAILS_IP=500
  env LERNAPP_DISK_MIN_FREE_MB=5120
  env LERNAPP_AI_TRIAL_BUDGET_EUR=200
container=/uniflow-jobs running healthy 0
  image=sha256:f98ed2a6e8b6fb604191440a48d0c31ed087dc7083940547609a31ea389d8d43 2026-11-09T01:45:05.041118824Z mem=1610612736
  env LERNAPP_MODE=hosted
  env LERNAPP_JOB_WORKERS=4
  env LERNAPP_AI_TRIAL_BUDGET_EUR=200
  env LERNAPP_LIMIT_REGISTER_ALL=3000/60
  env LERNAPP_LIMIT_API_PER_MIN=300
  env LERNAPP_LOGIN_FAILS_IP=500
  env LERNAPP_AI_BUDGET_EUR=600
  env LERNAPP_UPLOAD_QUOTA_MB=512
  env LERNAPP_LIMIT_REGISTER_IP=2000/60
  env UVICORN_WORKERS=12
  env LERNAPP_DISK_MIN_FREE_MB=5120
  env LERNAPP_LIMIT_RESET_IP=300/60
  env WEB_CONCURRENCY=4
container=/uniflow-caddy running - 0
  image=sha256:ce773ec7a742ce15ee6bf2bb5f65882b9e2a4487b10733e6f1484f86e6b5d8bc 2026-11-08T14:41:11.726993976Z mem=0
cpus=8 mem_total_mb=15603 mem_avail_mb=13937
```
