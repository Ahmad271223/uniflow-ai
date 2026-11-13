"""Kleiner App-Store-Connect-Client (ES256-JWT). Aufruf: asc.py GET /v1/apps?filter[bundleId]=de.uniflow.ai
oder asc.py PATCH|POST|DELETE <pfad> '<json>'
Schluessel: ~/Studora-Builds/private_keys/AuthKey_93BHUZGTCD.p8 (nur auf dem Mac des Inhabers, nie committen).
Aufruf im Projektordner: .venv/bin/python tools/asc.py GET /v1/apps/6830632088/appStoreVersions"""
import base64, json, os, sys, time, urllib.request, urllib.error
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

KID = "93BHUZGTCD"
ISS = "a5fea04a-eb9b-4e3e-9442-b5ab1e0462a6"
KEY = os.path.expanduser(f"~/Studora-Builds/private_keys/AuthKey_{KID}.p8")


def b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def token() -> str:
    head = b64(json.dumps({"alg": "ES256", "kid": KID, "typ": "JWT"}).encode())
    now = int(time.time())
    body = b64(json.dumps({"iss": ISS, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    key = serialization.load_pem_private_key(open(KEY, "rb").read(), password=None)
    der = key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return f"{head}.{body}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def call(method: str, path: str, data=None):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    req = urllib.request.Request(url, method=method, data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


if __name__ == "__main__":
    m, p = sys.argv[1], sys.argv[2]
    d = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    st, out = call(m, p, d)
    print(st)
    print(json.dumps(out, indent=1, ensure_ascii=False)[:20000])
