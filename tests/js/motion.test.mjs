// Bewegung der Oberflaeche (app/static/motion.js) ohne Browser. Ausfuehren: node --test tests/js/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { numbersIn, textAt, staggerOnce, countUp, reveal, _resetMotion } from "../../app/static/motion.js";

const fakeEl = (n = 0) => {
  const classes = new Set();
  const children = Array.from({ length: n }, () => ({ props: {}, style: { setProperty(k, v) { this.owner.props[k] = v; } } }));
  children.forEach(c => { c.style.owner = c; });
  return { children, classList: { add: c => classes.add(c), remove: c => classes.delete(c), has: c => classes.has(c) } };
};

test("Zahlen im Text finden und dazwischen rechnen, Rest bleibt", () => {
  assert.deepEqual(numbersIn("2 / 5"), [2, 5]);
  assert.deepEqual(numbersIn("1 h 30 min"), [1, 30]);
  assert.deepEqual(numbersIn("–"), []);
  assert.equal(textAt("2 / 5", [0, 0], 0), "0 / 0");
  assert.equal(textAt("2 / 5", [0, 0], 1), "2 / 5");
  assert.equal(textAt("60%", [20], 0.5), "40%");
  assert.equal(textAt("1 h 30 min", [], 0.3), "1 h 30 min");        // ohne Ausgangswerte: sofort der Endwert
});

test("Karten staffeln sich nur beim ersten Erscheinen der Gruppe, Versatz begrenzt", () => {
  _resetMotion();
  const a = fakeEl(12);
  assert.equal(staggerOnce(a, "dashboard"), true);
  assert.equal(a.classList.has("uf-stagger"), true);
  assert.equal(a.children[3].props["--i"], "3");
  assert.equal(a.children[11].props["--i"], "8");                   // lange Listen warten nicht
  const b = fakeEl(3);
  assert.equal(staggerOnce(b, "dashboard"), false);                 // Neuladen: kein zweites Einblenden
  assert.equal(b.classList.has("uf-stagger"), false);
  assert.equal(staggerOnce(null, "modules"), false);
  _resetMotion();
});

test("Ohne Browser (kein requestAnimationFrame, kein animate) steht alles sofort im Endzustand", () => {
  _resetMotion();
  const el = { textContent: "3 / 5", isConnected: true };
  countUp(el, "k");
  assert.equal(el.textContent, "3 / 5");
  const panel = { hidden: true };
  reveal(panel, true);
  assert.equal(panel.hidden, false);
  reveal(panel, false);
  assert.equal(panel.hidden, true);
});
