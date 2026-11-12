"""Hosting-Paket (deploy/, docs/release/BETRIEB.md): Dateien vorhanden und untereinander stimmig – ohne Docker.

- .env.example nennt jede LERNAPP_-Variable, die app/config.py (und der Rest von app/) aus der Umgebung liest
- Dockerfile, docker-compose.yml und Caddyfile nennen dieselbe Port-Nummer wie app/config.py (PORT, Standard 8765)
- .dockerignore schliesst Daten, .venv und Datenbanken aus; deploy/.env ist durch .gitignore gedeckt
- backup.sh/backup_snapshot.py mit LF-Zeilenenden (laufen auf dem Server unter bash), Aufbewahrung 14 Tage
"""
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "deploy"
FILES = ("Dockerfile", "docker-compose.yml", "Caddyfile", ".env.example", "backup.sh", "backup_snapshot.py",
         "uniflow-backup.service", "uniflow-backup.timer", "dienst-check.sh", "uniflow-dienst-check.service", "uniflow-dienst-check.timer")
ENV_RE = re.compile(r"""os\.(?:environ\.get|getenv|environ)\s*[\(\[]\s*["'](LERNAPP_[A-Z0-9_]+)["']""")
# weiter gefasst fuer ganz app/: jeder Variablenname als eigenes String-Literal (auch _env("LERNAPP_MAIL") in app/mail.py
# oder die "env"-Eintraege in app/social_login.py); Erwaehnungen in Docstrings zaehlen nicht
ANY_LITERAL_RE = re.compile(r"""["'](LERNAPP_[A-Z0-9_]+)["']""")
# Mailversand (app/mail.py) baut ein anderer Agent; die Namen sind in .env.example schon vorgesehen
PLANNED = {"LERNAPP_MAIL", "LERNAPP_SMTP_HOST", "LERNAPP_SMTP_PORT", "LERNAPP_SMTP_USER", "LERNAPP_SMTP_PASSWORD",
           "LERNAPP_MAIL_FROM", "LERNAPP_PUBLIC_URL"}


def read(name: str) -> str:
    return (DEPLOY / name).read_text(encoding="utf-8")


def env_example_keys() -> set[str]:
    return {m.group(1) for m in re.finditer(r"^([A-Z][A-Z0-9_]*)=", read(".env.example"), re.M)}


def env_vars_in(path: Path) -> set[str]:
    return set(ENV_RE.findall(path.read_text(encoding="utf-8")))


def test_deploy_files_exist():
    for f in FILES:
        assert (DEPLOY / f).is_file(), f
    assert (ROOT / ".dockerignore").is_file()
    assert (ROOT / "docs" / "release" / "BETRIEB.md").is_file()


def test_env_example_names_every_lernapp_variable_from_config():
    found = env_vars_in(ROOT / "app" / "config.py")
    assert {"LERNAPP_MODE", "LERNAPP_DATA_DIR", "LERNAPP_LOG_DIR", "LERNAPP_FILES"} <= found
    missing = found - env_example_keys()
    assert not missing, f"in deploy/.env.example fehlen: {sorted(missing)}"


def test_env_example_names_every_lernapp_variable_from_app():
    """Auch die Betriebsvariablen ausserhalb von config.py (HTTPS, ALLOWED_HOSTS, JOBS, SECRET_KEY, RETENTION, ...)."""
    found = set()
    for p in (ROOT / "app").glob("*.py"):
        found |= set(ANY_LITERAL_RE.findall(p.read_text(encoding="utf-8")))
    keys = env_example_keys()
    missing = found - keys
    assert not missing, f"in deploy/.env.example fehlen: {sorted(missing)}"
    assert PLANNED <= keys
    assert "LERNAPP_SECRET_KEY=" in read(".env.example")        # Vorlage ohne echten Schluessel


def test_env_example_has_no_real_values():
    text = read(".env.example")
    for key in ("LERNAPP_SECRET_KEY", "LERNAPP_SMTP_PASSWORD", "LERNAPP_SMTP_USER", "LERNAPP_STRIPE_SECRET_KEY",
                "LERNAPP_STRIPE_WEBHOOK_SECRET", "LERNAPP_OPENAI_API_KEY"):
        assert re.search(rf"^{key}=\s*$", text, re.M), key
    assert not re.search(r"sk_live_[A-Za-z0-9]{8}|whsec_[A-Za-z0-9]{8}|sk-[A-Za-z0-9]{20}", text), "echter Schluessel in der Vorlage"
    assert "example.de" in text and "LERNAPP_MODE=hosted" in text and "LERNAPP_FILES=stream" in text
    assert "LERNAPP_HTTPS=1" in text


def test_ports_agree_between_config_dockerfile_compose_and_caddy():
    from app import config
    port = str(config.PORT)
    df = read("Dockerfile")
    assert re.search(rf"^EXPOSE {port}$", df, re.M), "EXPOSE im Dockerfile"
    assert f'"--port", "{port}"' in df, "CMD uvicorn --port"
    assert f"127.0.0.1:{port}/login" in df, "HEALTHCHECK auf /login"
    assert f'- "{port}"' in read("docker-compose.yml"), "expose in docker-compose.yml"
    assert f"reverse_proxy app:{port}" in read("Caddyfile"), "Caddy -> app"
    for other in re.findall(r"\b(\d{4,5})\b", read("Dockerfile")):
        assert other in (port, "1000", "4096"), f"fremde Port-Nummer im Dockerfile: {other}"      # 1000 = UID, 4096 = --backlog


def test_dockerfile_runs_unprivileged_with_chromium_and_hosted_defaults():
    df = read("Dockerfile")
    assert re.search(r"^FROM python:3\.1[2-4]-slim", df, re.M)
    assert "playwright install --with-deps chromium" in df
    assert re.search(r"^USER uniflow$", df, re.M)
    assert "LERNAPP_DATA_DIR=/data" in df and "LERNAPP_LOG_DIR=/logs" in df and "LERNAPP_MODE=hosted" in df
    assert "--proxy-headers" in df and "--no-access-log" in df and "HEALTHCHECK" in df


def test_dockerfile_runs_four_api_workers_and_compose_moves_jobs_to_own_service():
    """Lasttest 30.10.2026 (Empfehlung 1) und Lastfestigkeit 08.11.2026: uvicorn --workers 4 (KI-Fragen warten asynchron,
    zwei Prozesse je Kern); weil LERNAPP_JOBS=inproc den Runner je Prozess starten wuerde, bekommt die API in
    docker-compose.yml fest LERNAPP_JOBS=off und `jobs` laeuft als eigener Dienst aus demselben Image mit denselben
    Volumes, der .env, Chromium-/dev/shm und einem Healthcheck ueber das Lebenszeichen. API-Speicher ~1,5 GB fuer 4 GB,
    Dateideskriptoren >= 65536 (jede offene KI-Frage = 2 Verbindungen), Healthcheck unveraendert."""
    import yaml
    df = read("Dockerfile")
    assert "ENV WEB_CONCURRENCY=4" in df and '"--workers"' not in df, "vier API-Prozesse ueber WEB_CONCURRENCY (einstellbar)"
    assert '"--backlog", "4096"' in df
    assert "urlopen('http://127.0.0.1:8765/login', timeout=4)" in df, "Healthcheck unveraendert"
    c = yaml.safe_load(read("docker-compose.yml"))
    app, jobs = c["services"]["app"], c["services"]["jobs"]
    assert app["environment"]["WEB_CONCURRENCY"] == "${UVICORN_WORKERS:-4}", "Prozesszahl aus deploy/.env"
    assert app["deploy"]["resources"]["limits"]["memory"] == "${API_MEMORY:-1536M}", "Speichergrenze waechst mit"
    assert app["ulimits"]["nofile"] == {"soft": 65536, "hard": 65536}
    env = read(".env.example")
    assert "UVICORN_WORKERS=4" in env and "API_MEMORY=1536M" in env, "Vorlage nennt dieselben Standardwerte"
    assert str(app["environment"]["LERNAPP_JOBS"]).lower() == "off", "API-Prozesse ohne Job-Runner"
    assert jobs["image"] == app["image"] and "build" not in jobs and jobs.get("pull_policy") == "never"
    assert jobs["command"] == ["python", "-m", "app.jobs"]
    assert sorted(jobs["volumes"]) == sorted(app["volumes"]), "gleiche Daten und Protokolle"
    assert jobs["env_file"] == app["env_file"], "dieselbe deploy/.env"
    for k in ("LERNAPP_MODE", "LERNAPP_DATA_DIR", "LERNAPP_LOG_DIR"):
        assert jobs["environment"][k] == app["environment"][k]
    assert "LERNAPP_JOBS" not in jobs["environment"], "python -m app.jobs liest LERNAPP_JOBS nicht; nichts vortaeuschen"
    assert "shm_size" in jobs and "shm_size" not in app, "Chromium laeuft nur noch im Jobs-Container"
    assert jobs["healthcheck"]["test"] == ["CMD", "python", "-m", "app.jobs", "--healthcheck"]
    assert "app" in jobs["depends_on"] and jobs["restart"] == "unless-stopped"
    assert "ports" not in jobs and "expose" not in jobs, "der Jobs-Container hoert auf nichts"
    assert c["services"]["caddy"]["depends_on"]["app"]["condition"] == "service_healthy"
    # Speicher: beide Container zusammen muessen auf den 4-GB-Server passen (Checkliste Abschnitt 1)
    def mb(v: str) -> int:
        m = re.fullmatch(r"\$\{API_MEMORY:-(\d+)M\}", v)       # einstellbar, Standard fuer den 4-GB-Server
        return int(m.group(1)) if m else int(v.rstrip("M"))
    total = mb(app["deploy"]["resources"]["limits"]["memory"]) + mb(jobs["deploy"]["resources"]["limits"]["memory"])
    assert 2048 <= total <= 3072, total
    for svc in (app, jobs):
        assert svc["stop_grace_period"] == "30s"


def test_env_example_raises_register_limit_for_campus_nat():
    """Lasttest 30.10.2026, Fund 6: 30 Registrierungen je IP und Stunde reichen hinter eduroam-NAT nicht. Die Vorlage
    setzte 300/60; seit 08.11.2026 (Launch mit bis zu 500 Testern am Tag hinter einer Campus-Adresse) 2000/60 plus die
    Summe ueber alle Adressen (register_all). app/accounts._limit liest genau diesen Wert."""
    from app import accounts
    text = read(".env.example")
    m = re.search(r"^LERNAPP_LIMIT_REGISTER_IP=(\d+)/(\d+)$", text, re.M)
    assert m, "LERNAPP_LIMIT_REGISTER_IP fehlt in .env.example"
    n, minutes = int(m.group(1)), int(m.group(2))
    assert n >= 2000 and minutes == 60 and n > accounts.LIMITS["register_ip"][0]
    assert "NAT" in text and "eduroam" in text, "Begruendung steht dabei"
    assert re.search(r"^LERNAPP_LIMIT_REGISTER_ALL=", text, re.M) and "register_all" in accounts.LIMITS
    assert accounts.LIMITS["register_all"][0] >= n, "die Summe ueber alle Adressen darf nicht unter der Grenze je Adresse liegen"
    assert re.search(r"^LERNAPP_LOGIN_FAILS_IP=(\d+)$", text, re.M) and re.search(r"^LERNAPP_LIMIT_RESET_IP=\d+/60$", text, re.M)
    import os
    old = os.environ.get("LERNAPP_LIMIT_REGISTER_IP")
    os.environ["LERNAPP_LIMIT_REGISTER_IP"] = m.group(0).split("=", 1)[1]
    try:
        assert accounts._limit("register_ip") == (n, minutes)
    finally:
        if old is None:
            del os.environ["LERNAPP_LIMIT_REGISTER_IP"]
        else:
            os.environ["LERNAPP_LIMIT_REGISTER_IP"] = old
    doc = (ROOT / "docs" / "START-DIENST-CHECKLISTE.md").read_text(encoding="utf-8")
    assert f"LERNAPP_LIMIT_REGISTER_IP={n}/{minutes}" in doc and "python -m app.jobs" in doc and "jobs.heartbeat" in doc


def test_compose_mounts_volumes_and_keeps_app_internal():
    c = read("docker-compose.yml")
    assert "uniflow-data:/data" in c and "uniflow-logs:/logs" in c and "caddy-data:/data" in c
    assert "restart: unless-stopped" in c and "memory:" in c and "dockerfile: deploy/Dockerfile" in c
    assert "${UNIFLOW_DOMAIN" in c and "LERNAPP_HTTPS" in c and "LERNAPP_ALLOWED_HOSTS" in c
    # Caddy startet mit leerer ACME-Adresse nicht (`email` ohne Argument im Caddyfile) – Compose muss sie verlangen
    assert "${UNIFLOW_ACME_EMAIL:?" in c, "UNIFLOW_ACME_EMAIL muss Pflicht sein"
    app_block = c.split("  caddy:")[0]
    assert "ports:" not in app_block, "die App und die Jobs bekommen keinen Port am Host – nur Caddy"
    assert '"80:80"' in c and '"443:443"' in c


def test_caddyfile_uses_domain_placeholder_and_security_headers():
    cf = read("Caddyfile")
    assert "{$UNIFLOW_DOMAIN}" in cf
    assert "Strict-Transport-Security" in cf and "X-Content-Type-Options" in cf and "Referrer-Policy" in cf
    assert "Content-Security-Policy" not in cf.replace("Content-Security-Policy,", ""), "CSP setzt die App"
    m = re.search(r"max_size (\d+)MB", cf)
    assert m and int(m.group(1)) >= 300, "Upload-Grenze muss app/filestream.MAX_BYTES (300 MB) decken"


def test_dockerignore_excludes_data_and_venv():
    lines = {l.strip() for l in (ROOT / ".dockerignore").read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")}
    for must in ("data", ".venv", "node_modules", "apps", "backup", ".git", "__pycache__", "*.db", "logs"):
        assert must in lines or f"{must}/" in lines, must


def test_deploy_env_is_gitignored():
    patterns = [l.strip() for l in (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()]
    assert ".env" in patterns or "deploy/.env" in patterns or "**/.env" in patterns


@pytest.mark.parametrize("name", ["backup.sh", "backup_snapshot.py", "Caddyfile", "Dockerfile", "dienst-check.sh",
                                  "uniflow-dienst-check.service", "uniflow-dienst-check.timer"])
def test_server_side_files_have_lf_line_endings(name):
    assert b"\r\n" not in (DEPLOY / name).read_bytes(), f"{name}: CRLF – auf dem Server (bash/Caddy) unbrauchbar"


def test_backup_script_keeps_fourteen_days_and_is_documented():
    sh = read("backup.sh")
    assert sh.startswith("#!/usr/bin/env bash") and "set -euo pipefail" in sh
    assert "BACKUP_KEEP_DAYS:-14" in sh and "backup_snapshot.py" in sh and "accounts.db" in sh
    # 30.10.2026: `tar -tzf | grep -q` brach mit pipefail scheinbar zufaellig ab (SIGPIPE an tar) und meldete ein
    # vollstaendiges Archiv als unvollstaendig – die Liste wird erst ganz gelesen, dann durchsucht
    assert not re.search(r"tar -tzf[^\n]*\|\s*grep", sh), "tar | grep in einer Pipeline mit pipefail"
    assert 'LIST="$(tar -tzf "$OUT")"' in sh
    assert "OnCalendar=" in read("uniflow-backup.timer") and "backup.sh" in read("uniflow-backup.service")
    doc = (ROOT / "docs" / "release" / "BETRIEB.md").read_text(encoding="utf-8")
    for must in ("docker compose up -d --build", "python -m app.accounts", "python -m app.retention --dry-run",
                 "backup.sh", "LERNAPP_SECRET_KEY", "Wiederherstellung", "deploy/.env"):
        assert must in doc, must
    readme = (ROOT / "docs" / "release" / "README.md").read_text(encoding="utf-8")
    assert "BETRIEB.md" in readme


def test_backup_snapshot_copies_databases_consistently(tmp_path, monkeypatch, capsys):
    """Das Container-Skript, lokal gegen einen Mini-Datenordner: Datenbanken per Backup-API, Profile/WAL/secret.key nicht."""
    import io
    import runpy
    import sqlite3
    import sys
    import tarfile
    data = tmp_path / "data"
    uid = "a" * 32
    (data / "users" / uid / "assets").mkdir(parents=True)
    (data / "users" / uid / "browser-profile").mkdir()
    (data / "users" / uid / "browser-profile" / "Cookies").write_text("x")
    (data / "users" / uid / "assets" / "bild.png").write_bytes(b"png")
    # 12.11.2026: eigene Dokumente der Konten kommen mit, Hochschuldateien nicht
    (data / "users" / uid / "files" / "Eigene Dokumente").mkdir(parents=True)
    (data / "users" / uid / "files" / "Eigene Dokumente" / "u1.pdf").write_bytes(b"%PDF-1.4 eigen")
    (data / "users" / uid / "files" / "Mathe I").mkdir()
    (data / "users" / uid / "files" / "Mathe I" / "Blatt 1.pdf").write_bytes(b"%PDF-1.4 hochschule")
    (data / "users" / uid / "files" / "lose.pdf").write_bytes(b"%PDF-1.4 lose")
    (data / "secret.key").write_text("geheim")
    for db in (data / "accounts.db", data / "users" / uid / "lernapp.db"):
        c = sqlite3.connect(db)
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("CREATE TABLE t(x)")
        c.execute("INSERT INTO t VALUES (42)")
        c.commit()
        c.close()
    monkeypatch.setenv("LERNAPP_DATA_DIR", str(data))
    buf = io.BytesIO()
    monkeypatch.setattr(sys, "stdout", type("S", (), {"buffer": buf, "write": lambda s, t: None, "flush": lambda s: None})())
    with pytest.raises(SystemExit) as e:
        runpy.run_path(str(DEPLOY / "backup_snapshot.py"), run_name="__main__")
    assert e.value.code == 0
    names = set(tarfile.open(fileobj=io.BytesIO(buf.getvalue()), mode="r:gz").getnames())
    assert {"uniflow-data/accounts.db", f"uniflow-data/users/{uid}/lernapp.db", f"uniflow-data/users/{uid}/assets/bild.png",
            "uniflow-data/BACKUP-INFO.txt", f"uniflow-data/users/{uid}/files/Eigene Dokumente/u1.pdf"} <= names
    assert not any("browser-profile" in n or n.endswith(("-wal", "-shm", "secret.key")) for n in names), names
    assert not any("Mathe I" in n or n.endswith("lose.pdf") for n in names), names
    with tarfile.open(fileobj=io.BytesIO(buf.getvalue()), mode="r:gz") as tar:
        restored = tmp_path / "accounts.db"
        restored.write_bytes(tar.extractfile("uniflow-data/accounts.db").read())
    c = sqlite3.connect(restored)
    try:
        assert c.execute("SELECT x FROM t").fetchone() == (42,)
    finally:
        c.close()
