# Datei-Eingang (app/intake_server.py) als eigenes, kleines Bild: kein Chromium, keine Konten, keine KI.
# Bauen aus dem Repo-Ordner:  docker build -f deploy/eingang/Dockerfile -t studinow-eingang .
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 TZ=Europe/Berlin
WORKDIR /srv/eingang
COPY deploy/eingang/requirements.txt ./
RUN pip install -r requirements.txt
COPY app/intake_server.py ./intake_server.py
RUN useradd --uid 1000 --user-group --create-home --shell /usr/sbin/nologin eingang \
    && mkdir -p /data && chown -R eingang:eingang /data /srv/eingang
USER eingang
ENV INTAKE_DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 8780
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import sys, urllib.request; r = urllib.request.urlopen('http://127.0.0.1:8780/intake/v1/health', timeout=4); sys.exit(0 if r.status == 200 else 1)"
# --no-access-log: keine IP-Adressen im Protokoll
CMD ["uvicorn", "intake_server:app", "--host", "0.0.0.0", "--port", "8780", "--no-access-log", "--proxy-headers"]
