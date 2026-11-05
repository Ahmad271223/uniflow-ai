// Formerkennung "zeichnen und halten" im Editor (wie ShapeRecognizer.swift auf dem iPad, 05.11.2026), ohne DOM:
// Blieb der Stift am Ende eines Strichs mindestens HOLD_MS still, wird der Strich durch eine ideale Form ersetzt
// (Linie, Rechteck, Ellipse bzw. Kreis, Dreieck, Pfeil). Die Form bleibt ein gewoehnlicher Strich (gleiche Farbe,
// Breite, Stift), das Speicherformat aendert sich nicht. Eingebunden von editor.js (strokeMove / strokeEnd);
// tests/js/editor-shapes.test.mjs prueft dieselben Faelle wie das iPad.
// Punkte sind {x, y} in Seitenpunkten (PDF-Punkte bei Zoom 1), in Zeichenreihenfolge.

/** So lange muss der Stift am Ende still stehen (Millisekunden) */
export const HOLD_MS = 500;
/** Bis zu diesem Abstand (Seitenpunkte) gilt der Stift als still */
export const HOLD_RADIUS = 6;
/** Kuerzere Striche sind kein Kandidat (Punkte, Haekchen) */
export const MIN_LENGTH = 30;

/** Namen fuer die Meldung "Form erkannt: …" */
export const SHAPE_NAMES = { line: "Linie", rectangle: "Rechteck", circle: "Kreis", ellipse: "Ellipse", triangle: "Dreieck", arrow: "Pfeil" };

const hyp = (x, y) => Math.hypot(x, y);
const dist = (a, b) => hyp(b.x - a.x, b.y - a.y);

// ---------------------------------------------------------------- Halten am Ende
/** Halten verfolgen: `anchor` ist der Ort, an dem der Stift zuletzt wirklich unterwegs war. Bewegt er sich weiter als
 *  HOLD_RADIUS davon weg, beginnt das Warten dort neu. Der Browser meldet bei stillem Stift keine Punkte, darum zaehlt
 *  die Zeit zwischen der letzten Bewegung und dem Absetzen. */
export function holdStart(x, y, now) { return { x, y, t: now }; }
export function holdNote(h, x, y, now) {
  if (!h) return holdStart(x, y, now);
  if (hyp(x - h.x, y - h.y) > HOLD_RADIUS) { h.x = x; h.y = y; h.t = now; }
  return h;
}
export const heldStill = (h, now, minimum = HOLD_MS) => !!h && now - h.t >= minimum;

// ---------------------------------------------------------------- Geometrie
/** Punkte, die beim Halten am Ende entstanden sind, weglassen */
export function trimHold(pts) {
  if (!pts.length) return pts;
  const last = pts[pts.length - 1]; let end = pts.length - 1;
  while (end > 0 && dist(pts[end - 1], last) <= HOLD_RADIUS) end--;
  return pts.slice(0, end + 1);
}

/** Gleichmaessig in Abstand `step` abtasten (die Dichte der Eingabe spielt danach keine Rolle) */
export function resample(pts, step) {
  if (pts.length < 2) return pts.slice();
  const out = [pts[0]];
  for (let i = 1; i < pts.length; i++) {
    let a = out[out.length - 1]; const b = pts[i]; let d = dist(a, b);
    while (d >= step) { const t = step / d; a = { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t }; out.push(a); d = dist(a, b); }
  }
  const l = pts[pts.length - 1], o = out[out.length - 1];
  if (dist(l, o) > step / 2) out.push(l);
  return out;
}

export function pathLength(pts) { let s = 0; for (let i = 1; i < pts.length; i++) s += dist(pts[i - 1], pts[i]); return s; }

export function bounds(pts) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const p of pts) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x); y1 = Math.max(y1, p.y); }
  if (!pts.length) return { x: 0, y: 0, w: 0, h: 0, cx: 0, cy: 0 };
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2 };
}

export function distToLine(p, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y, len = hyp(dx, dy);
  if (len <= 0) return dist(p, a);
  return Math.abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len;
}

/** Winkel zwischen zwei Richtungen in Grad (0 bis 180) */
export function angleBetween(u, v) {
  const lu = hyp(u.x, u.y), lv = hyp(v.x, v.y);
  if (!(lu > 0) || !(lv > 0)) return 0;
  const c = Math.max(-1, Math.min(1, (u.x * v.x + u.y * v.y) / (lu * lv)));
  return Math.acos(c) * 180 / Math.PI;
}

/** Waagerecht oder senkrecht einrasten (bis 5 Grad daneben) */
export function snapAxis(a, b) {
  const dx = b.x - a.x, dy = b.y - a.y, angle = Math.abs(Math.atan2(dy, dx)) * 180 / Math.PI;
  if (angle <= 5 || angle >= 175) return { x: b.x, y: a.y };
  if (Math.abs(angle - 90) <= 5) return { x: a.x, y: b.y };
  return b;
}

/** Ecken: Stellen, an denen sich die Richtung ueber einen festen Hebel von zwei Abtastpunkten je Seite um mehr als
 *  45 Grad dreht (runde Formen bleiben frei von Ecken). Zusammenhaengende Kandidaten bilden eine Ecke. Bei
 *  geschlossenen Formen laeuft der Hebel ueber den Anfang hinweg. */
export function cornerIndices(pts, closed) {
  const n = pts.length; if (n < 8) return [];
  const w = 2;
  const at = i => closed ? pts[((i % n) + n) % n] : (i >= 0 && i < n ? pts[i] : null);
  const turn = new Array(n).fill(0);
  for (let i = 0; i < n; i++) {
    const p = at(i - w), c = at(i), q = at(i + w); if (!p || !c || !q) continue;
    turn[i] = angleBetween({ x: c.x - p.x, y: c.y - p.y }, { x: q.x - c.x, y: q.y - c.y });
  }
  const separation = w + 1; const groups = [];
  for (let i = 0; i < n; i++) {
    if (turn[i] < 45) continue;
    const g = groups[groups.length - 1];
    if (g && i - g[g.length - 1] <= separation) g.push(i); else groups.push([i]);
  }
  if (closed && groups.length > 1) {
    const first = groups[0], last = groups[groups.length - 1];
    if (first[0] + n - last[last.length - 1] <= separation) { groups[groups.length - 1] = last.concat(first.map(i => i + n)); groups.shift(); }
  }
  const out = [];
  for (const g of groups) {
    const best = Math.max(...g.map(i => turn[i % n]));
    const tops = g.filter(i => turn[i % n] >= best - 3);
    out.push(tops[Math.floor(tops.length / 2)] % n);
  }
  return out.sort((a, b) => a - b);
}

// ---------------------------------------------------------------- Erkennen
function lineShape(pts) {
  const a = pts[0], b = pts[pts.length - 1], chord = dist(a, b);
  if (chord < MIN_LENGTH * 0.8) return null;
  const deviation = Math.max(...pts.map(p => distToLine(p, a, b)));
  if (deviation > Math.max(4, 0.08 * chord)) return null;
  return { kind: "line", from: a, to: snapAxis(a, b) };
}

const normalizedAngle = angle => { let a = angle; while (a > Math.PI / 4) a -= Math.PI / 2; while (a < -Math.PI / 4) a += Math.PI / 2; return a; };

function rectangleShape(pts, corners) {
  const v = corners.map(i => pts[i]);
  for (let i = 0; i < 4; i++) {   // vier Ecken mit annaehernd rechten Winkeln
    const p = v[(i + 3) % 4], c = v[i], n = v[(i + 1) % 4];
    const a = angleBetween({ x: p.x - c.x, y: p.y - c.y }, { x: n.x - c.x, y: n.y - c.y });
    if (a < 60 || a > 120) return null;
  }
  let best = 0, bestLen = -1;   // Ausrichtung der laengsten Seite; nahe an den Achsen achsparallel
  for (let i = 0; i < 4; i++) { const l = dist(v[i], v[(i + 1) % 4]); if (l > bestLen) { bestLen = l; best = i; } }
  let angle = normalizedAngle(Math.atan2(v[(best + 1) % 4].y - v[best].y, v[(best + 1) % 4].x - v[best].x));
  if (Math.abs(angle) * 180 / Math.PI <= 8) angle = 0;
  const c = Math.cos(-angle), s = Math.sin(-angle);   // Box im gedrehten Rahmen ueber alle Punkte des Strichs
  const b = bounds(pts.map(p => ({ x: p.x * c - p.y * s, y: p.x * s + p.y * c })));
  const cos = Math.cos(angle), sin = Math.sin(angle);
  return { kind: "rectangle", center: { x: b.cx * cos - b.cy * sin, y: b.cx * sin + b.cy * cos }, w: b.w, h: b.h, angle };
}

function ellipseShape(pts) {
  const b = bounds(pts); let rx = b.w / 2, ry = b.h / 2;
  if (rx < 6 || ry < 6) return null;
  const err = pts.reduce((sum, p) => sum + Math.abs(((p.x - b.cx) / rx) ** 2 + ((p.y - b.cy) / ry) ** 2 - 1), 0) / pts.length;
  if (err > 0.3) return null;
  if (Math.abs(rx - ry) <= 0.12 * Math.max(rx, ry)) { const r = (rx + ry) / 2; rx = r; ry = r; }   // Kreis bei fast gleichen Achsen
  return { kind: "ellipse", center: { x: b.cx, y: b.cy }, rx, ry };
}

/** Pfeil: ein gerader Schaft, danach die Spitze als Haken oder "V" in der Naehe des Schaftendes */
function arrowShape(pts, corners, length) {
  if (corners.length > 4) return null;
  const tipIndex = corners[0], start = pts[0], tip = pts[tipIndex], shaft = dist(start, tip);
  if (shaft < MIN_LENGTH * 0.8 || shaft < 0.5 * length) return null;
  const deviation = Math.max(...pts.slice(0, tipIndex + 1).map(p => distToLine(p, start, tip)));
  if (deviation > Math.max(4, 0.08 * shaft)) return null;
  const head = pts.slice(tipIndex), reach = Math.max(...head.map(p => dist(p, tip)));
  if (reach < 6 || reach > 0.5 * shaft) return null;
  const back = { x: start.x - tip.x, y: start.y - tip.y };
  const slanted = head.some(p => {
    const d = { x: p.x - tip.x, y: p.y - tip.y };
    if (hyp(d.x, d.y) < 0.5 * reach) return false;
    const a = angleBetween(back, d);
    return a >= 15 && a <= 80;
  });
  return slanted ? { kind: "arrow", from: start, to: tip } : null;
}

/** Form zu einer Punktfolge; null, wenn es keine der fuenf Formen ist */
export function recognize(raw) {
  const pts = resample(trimHold(raw), 3);
  if (pts.length < 8) return null;
  const length = pathLength(pts), box = bounds(pts);
  if (length < MIN_LENGTH || Math.max(box.w, box.h) < 12) return null;
  const closed = dist(pts[0], pts[pts.length - 1]) <= Math.max(12, 0.15 * length);
  const corners = cornerIndices(pts, closed);
  if (closed) {
    if (corners.length === 3) return { kind: "triangle", points: corners.map(i => pts[i]) };
    if (corners.length === 4) return rectangleShape(pts, corners);
    if (corners.length <= 1) return ellipseShape(pts);
    return null;
  }
  if (!corners.length) return lineShape(pts);
  return arrowShape(pts, corners, length);
}

/** Name der Form fuer die Meldung ("line", "rectangle", "circle", "ellipse", "triangle", "arrow") */
export function shapeName(s) {
  if (!s) return "";
  if (s.kind === "ellipse") return Math.abs(s.rx - s.ry) <= 0.001 ? "circle" : "ellipse";
  return s.kind;
}

// ---------------------------------------------------------------- Ideale Form als Strich
function polyline(vertices, closed, step = 3) {
  const out = [], v = closed ? vertices.concat([vertices[0]]) : vertices;
  for (let i = 0; i < v.length - 1; i++) {
    const a = v[i], b = v[i + 1], len = dist(a, b), n = Math.max(1, Math.floor(len / step));
    out.push(a, a, a);   // Ecke scharf (dreifacher Punkt)
    for (let k = 1; k < n; k++) { const t = k / n; out.push({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t }); }
  }
  const last = v[v.length - 1]; out.push(last, last, last);
  return out;
}

/** Punkte der Form (alle 3 pt, Ecken dreifach) */
export function outline(s) {
  switch (s.kind) {
    case "line": return polyline([s.from, s.to], false);
    case "rectangle": {
      const hw = s.w / 2, hh = s.h / 2, c = Math.cos(s.angle), sn = Math.sin(s.angle);
      const local = [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]];
      return polyline(local.map(([x, y]) => ({ x: s.center.x + x * c - y * sn, y: s.center.y + x * sn + y * c })), true);
    }
    case "ellipse": {
      const n = Math.max(48, Math.floor((2 * Math.PI * Math.max(s.rx, s.ry)) / 3)), out = [];
      for (let i = 0; i <= n; i++) { const t = i / n * 2 * Math.PI; out.push({ x: s.center.x + s.rx * Math.cos(t), y: s.center.y + s.ry * Math.sin(t) }); }
      return out;
    }
    case "triangle": return polyline(s.points, true);
    case "arrow": {
      const dx = s.to.x - s.from.x, dy = s.to.y - s.from.y, len = hyp(dx, dy);
      const head = Math.min(0.25 * len, Math.max(12, 0.12 * len)), angle = Math.atan2(dy, dx);
      const left = { x: s.to.x - head * Math.cos(angle - Math.PI / 6), y: s.to.y - head * Math.sin(angle - Math.PI / 6) };
      const right = { x: s.to.x - head * Math.cos(angle + Math.PI / 6), y: s.to.y - head * Math.sin(angle + Math.PI / 6) };
      return polyline([s.from, s.to, left, s.to, right], false);
    }
    default: return [];
  }
}

/** Gesamtablauf fuer den Editor: flache Punktliste eines Strichs ([x, y, x, y, …]) + "Stift blieb still" -> ideale Form
 *  als flache Punktliste und ihr Name, sonst null */
export function snapStroke(flat, held) {
  if (!held || !Array.isArray(flat) || flat.length < 16) return null;
  const pts = []; for (let i = 0; i + 1 < flat.length; i += 2) pts.push({ x: flat[i], y: flat[i + 1] });
  const shape = recognize(pts); if (!shape) return null;
  const pl = outline(shape), points = []; for (const p of pl) points.push(Math.round(p.x * 100) / 100, Math.round(p.y * 100) / 100);
  return { name: shapeName(shape), label: SHAPE_NAMES[shapeName(shape)], points, shape };
}

/** Einrasten an/aus: Standard an, `localStorage["ed.shapeSnap"] = "0"` schaltet es ab (Knopf in der Stiftleiste) */
export function snapEnabled(storage) {
  try { return (storage || (typeof localStorage !== "undefined" ? localStorage : null))?.getItem("ed.shapeSnap") !== "0"; } catch { return true; }
}
export function setSnapEnabled(on, storage) {
  try { (storage || localStorage).setItem("ed.shapeSnap", on ? "1" : "0"); } catch { /* nur Komfort */ }
}
