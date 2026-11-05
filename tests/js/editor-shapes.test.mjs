// Formerkennung "zeichnen und halten" (app/static/editor-shapes.js, 05.11.2026), ohne Browser: dieselben Faelle wie
// EditorStepEFHKTests.swift (testRecognizesTheFiveShapes…, testCurvesDotsAndScribbles…, testHoldingAtTheEnd…).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  recognize, outline, snapStroke, shapeName, holdStart, holdNote, heldStill, HOLD_MS, snapEnabled, setSnapEnabled, SHAPE_NAMES,
} from "../../app/static/editor-shapes.js";

const P = (x, y) => ({ x, y });
/** Punkte entlang eines Polygons (alle 3 pt), optional geschlossen, leicht zittrig wie von Hand */
function along(vertices, closed, step = 3) {
  const out = [], v = closed ? vertices.concat([vertices[0]]) : vertices;
  for (let i = 0; i < v.length - 1; i++) {
    const a = v[i], b = v[i + 1], n = Math.max(1, Math.floor(Math.hypot(b.x - a.x, b.y - a.y) / step));
    for (let k = 0; k < n; k++) { const t = k / n; out.push(P(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)); }
  }
  out.push(v[v.length - 1]);
  return out;
}
const ellipse = (c, rx, ry, from = 0.3) => Array.from({ length: 121 }, (_, i) => { const t = from + i / 120 * 2 * Math.PI; return P(c.x + rx * Math.cos(t), c.y + ry * Math.sin(t)); });
const near = (a, b, tol) => assert.ok(Math.abs(a - b) <= tol, `${a} ~ ${b} (±${tol})`);

test("die fuenf Formen werden erkannt", () => {
  const l = recognize(along([P(100, 100), P(300, 160)], false));
  assert.equal(l.kind, "line"); near(l.from.x, 100, 2); near(l.to.y, 160, 2);
  const h = recognize(along([P(100, 100), P(300, 104)], false));
  near(h.to.y, 100, 1.5);                                  // bis 5 Grad: waagerecht eingerastet

  const rect = recognize(along([P(200, 100), P(300, 100), P(300, 180), P(100, 180), P(100, 100), P(196, 100)], false));
  assert.equal(rect.kind, "rectangle"); near(rect.center.x, 200, 3); near(rect.center.y, 140, 3); near(rect.w, 200, 6); near(rect.h, 80, 6); near(rect.angle, 0, 0.001);

  const rot = Math.PI / 6;
  const corners = [P(-80, -40), P(80, -40), P(80, 40), P(-80, 40)].map(p => P(300 + p.x * Math.cos(rot) - p.y * Math.sin(rot), 300 + p.x * Math.sin(rot) + p.y * Math.cos(rot)));
  const turned = recognize(along(corners, true));
  assert.equal(turned.kind, "rectangle"); near(Math.abs(turned.angle), rot, 0.08); near(Math.max(turned.w, turned.h), 160, 8);

  const circle = recognize(ellipse(P(200, 200), 50, 52));
  assert.equal(circle.kind, "ellipse"); assert.equal(circle.rx, circle.ry); near(circle.center.x, 200, 2); near(circle.rx, 51, 2);
  assert.equal(shapeName(circle), "circle");
  const oval = recognize(ellipse(P(200, 200), 90, 40));
  near(oval.rx, 90, 2); near(oval.ry, 40, 2); assert.equal(shapeName(oval), "ellipse");

  const tri = [P(100, 200), P(200, 50), P(300, 200)];
  const t = recognize(along(tri, true));
  assert.equal(t.kind, "triangle");
  for (const v of tri) assert.ok(t.points.some(p => Math.hypot(p.x - v.x, p.y - v.y) <= 8), `Ecke ${v.x},${v.y}`);

  const arrow = recognize(along([P(100, 300), P(300, 300), P(275, 285), P(300, 300), P(275, 315)], false));
  assert.equal(arrow.kind, "arrow"); near(arrow.from.x, 100, 2); near(arrow.to.x, 300, 3);
  assert.equal(recognize(along([P(100, 400), P(100, 200), P(118, 222)], false)).kind, "arrow");   // Pfeil mit nur einem Haken
});

test("Boegen, Punkte, Gekritzel und Fuenfecke bleiben, wie sie sind", () => {
  const arc = Array.from({ length: 61 }, (_, i) => { const t = i / 60 * Math.PI; return P(200 + 100 * Math.cos(t), 200 - 100 * Math.sin(t)); });
  assert.equal(recognize(arc), null, "Bogen");
  assert.equal(recognize(along([P(10, 10), P(20, 12)], false)), null, "zu kurz");
  assert.equal(recognize(along([P(100, 100), P(140, 160), P(180, 100), P(220, 160), P(260, 100), P(300, 160)], false)), null, "Zickzack");
  const penta = Array.from({ length: 5 }, (_, i) => { const t = i / 5 * 2 * Math.PI; return P(200 + 80 * Math.cos(t), 200 + 80 * Math.sin(t)); });
  assert.equal(recognize(along(penta, true)), null, "Fuenfeck");
  assert.equal(recognize([]), null);
});

test("Halten am Ende: erst nach einer halben Sekunde Stillstand", () => {
  let h = holdStart(100, 100, 0);
  h = holdNote(h, 150, 100, 100);                          // weiter unterwegs: Warten beginnt neu
  h = holdNote(h, 300, 100, 200);
  assert.equal(heldStill(h, 200 + HOLD_MS - 1), false, "ohne Halten keine Form");
  assert.equal(heldStill(h, 200 + HOLD_MS), true);
  h = holdNote(h, 302, 101, 600);                          // Zittern im Umkreis zaehlt als still
  assert.equal(heldStill(h, 750), true);
  h = holdNote(h, 330, 101, 760);                          // wieder bewegt
  assert.equal(heldStill(h, 800), false);
  assert.equal(heldStill(null, 1000), false);
});

test("die ideale Form bleibt ein gewoehnlicher Strich mit scharfen Ecken", () => {
  const rect = [P(100, 100), P(300, 100), P(300, 200), P(100, 200)];
  const s = snapStroke(along(rect, true).flatMap(p => [p.x + 0.4, p.y - 0.4]), true);
  assert.ok(s, "Rechteck erkannt"); assert.equal(s.name, "rectangle"); assert.equal(s.label, "Rechteck");
  assert.equal(s.points.length % 2, 0);
  const pts = []; for (let i = 0; i < s.points.length; i += 2) pts.push(P(s.points[i], s.points[i + 1]));
  for (const c of rect) assert.ok(pts.some(p => Math.hypot(p.x - c.x, p.y - c.y) <= 3), `Ecke ${c.x},${c.y}`);
  const first = pts[0];
  assert.ok(pts.filter(p => p.x === first.x && p.y === first.y).length >= 3, "Ecke als dreifacher Punkt");
  assert.equal(snapStroke(along(rect, true).flatMap(p => [p.x, p.y]), false), null, "ohne Halten bleibt der Strich");
  assert.equal(snapStroke([1, 2, 3, 4], true), null, "zu kurz");
  assert.ok(outline({ kind: "ellipse", center: P(0, 0), rx: 20, ry: 20 }).length >= 49);
  assert.deepEqual(Object.keys(SHAPE_NAMES).sort(), ["arrow", "circle", "ellipse", "line", "rectangle", "triangle"]);
});

test("Einrasten laesst sich abschalten (Standard: an)", () => {
  const mem = new Map(); const storage = { getItem: k => mem.has(k) ? mem.get(k) : null, setItem: (k, v) => mem.set(k, v) };
  assert.equal(snapEnabled(storage), true);
  setSnapEnabled(false, storage); assert.equal(snapEnabled(storage), false);
  setSnapEnabled(true, storage); assert.equal(snapEnabled(storage), true);
  assert.equal(snapEnabled({ getItem() { throw new Error("gesperrt"); } }), true, "ohne Speicher bleibt es an");
});

test("editor.js bindet die Formerkennung ein: Halten verfolgen, beim Absetzen ersetzen, Schalter in der Stiftleiste", () => {
  const ed = readFileSync(new URL("../../app/static/editor.js", import.meta.url), "utf8");
  assert.match(ed, /from "\.\/editor-shapes\.js\?v=\d+"/);
  assert.match(ed, /holdNote\(d\.hold/);                   // strokeMove
  assert.match(ed, /snapStroke\(/);                        // strokeEnd
  assert.match(ed, /data-snap/);                           // Schalter in der Stiftleiste
});
