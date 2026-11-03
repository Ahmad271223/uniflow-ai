// Importierte Marker so dick wie beim Absender (iPad e04c717): Auf dem iPad hing die Dicke am Azimut der Marker-Punkte
// (PencilKit-Keilspitze, StrokeConverter.markerAzimuth = pi/4). Der Web-Editor kennt keinen Azimut: ein Marker aus einem
// Loesungspaket wird als Linie mit genau der gespeicherten Breite gezeichnet. Dieser Test haelt fest, dass das so bleibt
// (die Breite wird weder skaliert noch aus anderen Werten abgeleitet) und dass Paket-Strichlisten die Breite unveraendert
// durch Kodieren und Dekodieren tragen.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as S from "../../app/static/solutions.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

test("Marker wird mit der gespeicherten Breite gezeichnet, ohne Azimut", () => {
  const src = readFileSync(join(root, "app/static/editor.js"), "utf8");
  const line = src.split("\n").find(l => l.includes("new Konva.Line({ ...common, points: o.points, stroke: o.color, strokeWidth: o.width"));
  assert.ok(line, "Marker-Zweig in makeNode gefunden");
  assert.match(line, /strokeWidth: o\.width,/, "Breite genau wie gespeichert");
  assert.match(line, /globalCompositeOperation: o\.tool === "marker" \? "multiply"/);
  assert.doesNotMatch(src, /azimuth/i, "kein Azimut im Web-Editor");
});

test("Breite und Werkzeug eines Markers bleiben beim Kodieren und Dekodieren eines Pakets gleich", () => {
  const marker = { id: "m1", type: "stroke", tool: "marker", color: "#ffd60a", width: 15, opacity: 0.35, points: [10, 10, 60, 10.5, 120, 12] };
  const back = S.decodeObject(S.encodeObject(marker));
  assert.equal(back.width, 15);
  assert.equal(back.tool, "marker");
  assert.equal(back.opacity, 0.35);
  assert.deepEqual(back.points, marker.points);
  // Marker mit Breiten je Punkt (widths) behalten sie ebenfalls
  const varied = { ...marker, widths: [14.5, 15, 15.5] };
  assert.deepEqual(S.decodeObject(S.encodeObject(varied)).widths, [14.5, 15, 15.5]);
});
