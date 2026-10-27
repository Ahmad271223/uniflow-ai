# UniFlow – gehosteter Dienst (LERNAPP_MODE=hosted) als Container.
# Build aus der Repo-Wurzel:  docker build -f deploy/Dockerfile -t uniflow-app .
# Betrieb: deploy/docker-compose.yml (App intern auf 8765, Caddy davor mit TLS). Anleitung: docs/release/BETRIEB.md
#
# Python 3.12: die Windows-App wird damit gebaut (.github/workflows/windows.yml), CI und Entwicklung laufen mit 3.14.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    # Chromium fuer Playwright an einen festen Ort (nicht ins Home des Build-Nutzers), lesbar fuer den Dienstnutzer
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    TZ=Europe/Berlin

# tzdata: Zeitplan (08:00/15:00, Loeschfristen 04:00) in Ortszeit; sqlite3: Pruefen/Backups von Hand im Container
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata sqlite3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/uniflow

# Abhaengigkeiten zuerst (Docker-Cache: aendert sich der Code, bleibt diese Schicht bestehen)
COPY requirements.txt ./
RUN pip install -r requirements.txt \
    && playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.cache

# Nur, was der Dienst braucht: Code, Oberflaeche (app/static) und die Rechtstexte (/datenschutz, /impressum, ...)
COPY app ./app
COPY docs/release ./docs/release

# Unprivilegierter Dienstnutzer; /data und /logs gehoeren ihm (benannte Volumes uebernehmen die Rechte beim ersten Start)
RUN useradd --uid 1000 --user-group --create-home --home-dir /home/uniflow --shell /usr/sbin/nologin uniflow \
    && mkdir -p /data /logs \
    && chown -R uniflow:uniflow /data /logs /srv/uniflow

USER uniflow
ENV HOME=/home/uniflow \
    LERNAPP_MODE=hosted \
    LERNAPP_DATA_DIR=/data \
    LERNAPP_LOG_DIR=/logs \
    LERNAPP_LEGAL_DIR=/srv/uniflow/docs/release \
    PORT=8765

VOLUME ["/data", "/logs"]
EXPOSE 8765

# Oeffentlich ohne Sitzung: /login liefert im gehosteten Modus 200 (app/server.py). Host 127.0.0.1 besteht die Host-Pruefung.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import sys, urllib.request; r = urllib.request.urlopen('http://127.0.0.1:8765/login', timeout=4); sys.exit(0 if r.status == 200 else 1)"

# --proxy-headers/--forwarded-allow-ips: Caddy haengt X-Forwarded-For/-Proto an (Client-IP im Zugriffsprotokoll);
# das Secure-Flag des Sitzungs-Cookies kommt aus LERNAPP_HTTPS=1 (app/account_api.py), nicht aus dem Proto-Header.
# --no-access-log: das eigene Zugriffsprotokoll (app/retention.py) gilt 14 Tage, das von uvicorn kennt keine Frist.
CMD ["uvicorn", "app.server:app", "--host", "0.0.0.0", "--port", "8765", "--proxy-headers", "--forwarded-allow-ips=*", "--no-access-log"]
