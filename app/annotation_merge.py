"""Drei-Wege-Zusammenfuehrung von Notizdokumenten in Python, 1:1 wie app/static/merge.js (Referenz; Swift
AnnotationMerge.swift, Kotlin AnnotationDocument.kt). Gebraucht vom Geraete-Abgleich der Windows-App
(app/sync_client.py, 28.10.2026), der im Hintergrund ohne Browser zusammenfuehrt. Gemeinsame Faelle:
packages/shared-contracts/fixtures/merge/cases.json; tests/test_annotation_merge.py vergleicht jedes Ergebnis mit
merge.js.

Regeln: nur auf einer Seite geaendert -> diese Aenderung; neu auf einer Seite -> uebernommen (Striche beider Geraete
bleiben); auf einer Seite geloescht, auf der anderen unveraendert -> geloescht; geloescht gegen geaendert -> bleibt
(Konflikt); beide verschieden geaendert -> lokaler Stand (Konflikt). "Fehlt" (JS undefined) und null gelten als gleich.
"""
from __future__ import annotations

import json

MISSING = object()


def _norm(v):
    if isinstance(v, bool) or v is None or v is MISSING:
        return None if v is MISSING else v
    if isinstance(v, float) and v.is_integer() and abs(v) < 2**53:
        return int(v)                                   # JS kennt kein 1.0 neben 1
    if isinstance(v, list):
        return [_norm(x) for x in v]
    if isinstance(v, dict):
        return {k: _norm(x) for k, x in v.items() if x is not MISSING}
    return v


def stable_stringify(v) -> str:
    return json.dumps(_norm(v), sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def same(a, b) -> bool:
    a = None if a is MISSING else a
    b = None if b is MISSING else b
    if a is None and b is None:
        return True
    return a is not None and b is not None and stable_stringify(a) == stable_stringify(b)


def object_id(o) -> str:
    return o["id"] if isinstance(o, dict) and isinstance(o.get("id"), str) and o["id"] else "~" + stable_stringify(o)


def merge_objects(base, local, server) -> tuple[list, int]:
    def index(lst):
        m = {}
        for o in lst or []:
            m[object_id(o)] = o
        return m
    b, l = index(base), index(local)
    out, emitted, conflicts = [], set(), 0
    for o in server or []:
        oid = object_id(o)
        if oid in emitted:
            continue
        emitted.add(oid)
        bo, lo = b.get(oid, MISSING), l.get(oid, MISSING)
        if lo is not MISSING:
            if same(lo, bo) or same(lo, o):
                out.append(o)
            elif same(o, bo):
                out.append(lo)
            else:
                out.append(lo)
                conflicts += 1
        elif bo is MISSING:
            out.append(o)
        elif not same(o, bo):
            out.append(o)
            conflicts += 1
    for o in local or []:
        oid = object_id(o)
        if oid in emitted:
            continue
        emitted.add(oid)
        bo = b.get(oid, MISSING)
        if bo is MISSING:
            out.append(o)
        elif not same(o, bo):
            out.append(o)
            conflicts += 1
    return out, conflicts


def _get(d, k):
    return d.get(k, MISSING) if isinstance(d, dict) else MISSING


def merge_page(base, local, server) -> tuple[dict | None, int]:
    base = None if base is MISSING else base
    local = None if local is MISSING else local
    server = None if server is MISSING else server
    if same(local, base):
        return server, 0
    if same(server, base) or same(server, local):
        return local, 0
    if local is None:
        return server, 1
    if server is None:
        return local, 1
    result, conflicts = {}, 0
    keys = list(dict.fromkeys([*local.keys(), *server.keys(), *((base or {}).keys())]))
    for k in keys:
        if k in ("objects", "pkdrawing"):
            continue
        bv, lv, sv = _get(base, k), _get(local, k), _get(server, k)
        if same(lv, bv):
            v = sv
        elif same(sv, bv) or same(sv, lv):
            v = lv
        else:
            v = lv
            conflicts += 1
        if v is not MISSING:
            result[k] = v
    objs, c = merge_objects((base or {}).get("objects") or [], local.get("objects") or [], server.get("objects") or [])
    result["objects"] = objs
    conflicts += c

    def per_stroke(pk):
        return isinstance(pk, dict) and pk.get("format") == "pkdrawing-v2" and isinstance(pk.get("strokeSigs"), list)
    if local.get("pkdrawing") and same(objs, local.get("objects") or []):
        result["pkdrawing"] = local["pkdrawing"]
    elif server.get("pkdrawing") and same(objs, server.get("objects") or []):
        result["pkdrawing"] = server["pkdrawing"]
    elif per_stroke(local.get("pkdrawing")):
        result["pkdrawing"] = local["pkdrawing"]
    elif per_stroke(server.get("pkdrawing")):
        result["pkdrawing"] = server["pkdrawing"]
    return result, conflicts


def _key_of(e):
    if isinstance(e, dict):
        if isinstance(e.get("key"), str):
            return e["key"]
        if isinstance(e.get("entry"), dict) and isinstance(e["entry"].get("key"), str):
            return e["entry"]["key"]
        return None
    return e if isinstance(e, str) else None


def _order_keys(doc):
    return [k for k in (_key_of(e) for e in ((doc or {}).get("pageOrder") or [])) if k is not None]


def _page_of(doc, k):
    pages = (doc or {}).get("pages") or {}
    return pages.get(k) if pages.get(k) is not None else None


def _entry_of(doc, k):
    for e in (doc or {}).get("pageOrder") or []:
        if _key_of(e) == k:
            return e
    return None


def merge_field(bv, lv, sv):
    if same(lv, bv):
        return sv, 0
    if same(sv, bv) or same(sv, lv):
        return lv, 0
    return lv, 1


def merge_page_order(base, local, server) -> tuple[list[str], bool]:
    B, L, S = _order_keys(base), _order_keys(local), _order_keys(server)
    bset, lset, sset = set(B), set(L), set(S)

    def dropped(k):
        if k in lset and k in sset:
            return False
        if k not in bset:
            return False
        if k not in lset:
            return same(_page_of(server, k), _page_of(base, k))
        return same(_page_of(local, k), _page_of(base, k))
    Lk = [k for k in L if not dropped(k)]
    Sk = [k for k in S if not dropped(k)]
    Bk = [k for k in B if not dropped(k)]
    common = {k for k in Lk if k in Sk}
    oL, oS, oB = [k for k in Lk if k in common], [k for k in Sk if k in common], [k for k in Bk if k in common]
    conflict = False
    if oL == oS or oS == oB:
        primary, secondary = Lk, Sk
    elif oL == oB:
        primary, secondary = Sk, Lk
    else:
        primary, secondary, conflict = Lk, Sk, True
    out = list(primary)
    for i, k in enumerate(secondary):
        if k in out:
            continue
        at = 0
        for j in range(i - 1, -1, -1):
            if secondary[j] in out:
                at = out.index(secondary[j]) + 1
                break
        out.insert(at, k)
    return out, conflict


def merge_trash(local, server, keys) -> list:
    in_order, seen, out = set(keys), set(), []
    for e in [*((local or {}).get("deletedPages") or []), *((server or {}).get("deletedPages") or [])]:
        k = _key_of(e)
        if k is None or k in seen or k in in_order:
            continue
        seen.add(k)
        out.append(e)
    return out


def merge_document(base, local, server) -> tuple[dict, int, bool]:
    """Ganzes Dokument; Ergebnis (Dokument, Konflikte, Reihenfolge-Konflikt)."""
    conflicts = 0
    pages = {}
    keys = list(dict.fromkeys([*(((server or {}).get("pages") or {}).keys()), *(((local or {}).get("pages") or {}).keys()),
                               *(((base or {}).get("pages") or {}).keys())]))
    for k in keys:
        page, c = merge_page(_page_of(base, k), _page_of(local, k), _page_of(server, k))
        if page is not None:
            pages[k] = page
        conflicts += c
    order, order_conflict = merge_page_order(base, local, server)
    if order_conflict:
        conflicts += 1
    page_order = []
    for k in order:
        le, se = _entry_of(local, k), _entry_of(server, k)
        if le is not None and se is not None:
            v, c = merge_field(_entry_of(base, k), le, se)
            conflicts += c
            page_order.append(v)
        else:
            page_order.append(le if le is not None else se)
    for k in order:
        if pages.get(k) is None:                      # wie `!pages[k]` in JS: nur fehlende Seiten
            p = _page_of(local, k)
            pages[k] = p if p is not None else (_page_of(server, k) if _page_of(server, k) is not None else {"objects": []})
    out = {}
    root = list(dict.fromkeys([*((server or {}).keys()), *((local or {}).keys()), *((base or {}).keys())]))
    for k in root:
        if k in ("pages", "pageOrder", "deletedPages"):
            continue
        v, c = merge_field(_get(base, k), _get(local, k), _get(server, k))
        conflicts += c
        if v is not MISSING:
            out[k] = v
    out["pages"], out["pageOrder"], out["deletedPages"] = pages, page_order, merge_trash(local, server, order)
    return out, conflicts, order_conflict
