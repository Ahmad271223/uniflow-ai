// Bildschirm fixieren im Editor (app/static/editor-freeze.js, 05.11.2026), ohne Browser: dieselbe Zustandsfolge wie
// EditorFreezeTests auf dem iPad (Stufen, Bildschirm an und zurück, Entsperren erst nach 2 s Halten, Abbruch), dazu
// welche Zeiger und Tasten bei fixierter Ansicht bzw. beim Abpausen durchkommen.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createFreeze, pointerPolicy, keyAction, browserScreen, UNLOCK_HOLD_MS, TEXTS } from "../../app/static/editor-freeze.js";

const fakeScreen = (brightness = false) => ({ idleTimerDisabled: false, supportsBrightness: brightness, brightness: 0.4 });

test("Stufen: fixieren, lösen, Abpausen führt zur Stufe davor zurück", () => {
  const s = fakeScreen(); const f = createFreeze(s); const seen = []; f.onChange = m => seen.push(m);
  assert.equal(f.mode, "off"); assert.equal(f.locksView, false); assert.equal(f.acceptsInput, true);
  assert.equal(f.fixView(), true); assert.equal(f.mode, "view"); assert.equal(f.locksView, true); assert.equal(f.acceptsInput, true, "Stift schreibt weiter");
  assert.equal(f.showsChrome, true);
  assert.equal(f.fixView(), false, "zweimal fixieren ändert nichts");
  assert.equal(f.startTracing(), true); assert.equal(f.mode, "trace"); assert.equal(f.acceptsInput, false); assert.equal(f.showsChrome, false);
  assert.equal(s.idleTimerDisabled, true, "Bildschirm bleibt an");
  assert.equal(f.toggleView(), false, "Strg+L löst das Abpausen nicht");
  assert.equal(f.startTracing(), false);
  f.unlock(); assert.equal(f.mode, "view", "war vorher fixiert"); assert.equal(s.idleTimerDisabled, false, "Bildschirm wie vorher");
  f.unlock(); assert.equal(f.mode, "off");
  f.startTracing(); f.unlock(); assert.equal(f.mode, "off", "ohne Fixieren vorher ganz frei");
  assert.deepEqual(seen, ["view", "trace", "view", "off", "trace", "off"]);
  assert.equal(f.toggleView(), true); assert.equal(f.mode, "view"); assert.equal(f.toggleView(), true); assert.equal(f.mode, "off");
});

test("Entsperren erst nach etwa 2 s Halten; kurzes Halten und Abbruch entsperren nicht", () => {
  const f = createFreeze(fakeScreen()); f.startTracing();
  f.holdBegan(1000); assert.equal(f.isHolding, true);
  assert.equal(f.holdProgress(2000), 0.5);
  assert.equal(f.holdEnded(2500), false, "losgelassen nach 1,5 s"); assert.equal(f.mode, "trace"); assert.equal(f.isHolding, false);
  f.holdBegan(3000); assert.equal(f.holdCheck(3000 + UNLOCK_HOLD_MS - 1), false);
  f.holdCancelled(); assert.equal(f.holdCheck(9000), false, "abgebrochen"); assert.equal(f.mode, "trace");
  f.holdBegan(10000); assert.equal(f.holdCheck(10000 + UNLOCK_HOLD_MS), true); assert.equal(f.mode, "off");
  assert.equal(f.holdProgress(20000), 0);
  const g = createFreeze(fakeScreen()); g.holdBegan(0); assert.equal(g.isHolding, false, "nur beim Abpausen");
  g.startTracing(); g.holdBegan(0); assert.equal(g.holdEnded(UNLOCK_HOLD_MS + 5), true, "loslassen nach 2 s entsperrt");
});

test("Helligkeit nur wo steuerbar, zurück beim Entsperren, Schließen und im Hintergrund", () => {
  const s = fakeScreen(true); const f = createFreeze(s);
  f.startTracing({ maxBrightness: true }); assert.equal(s.brightness, 1);
  f.suspend(); assert.equal(s.brightness, 0.4); assert.equal(f.isSuspended, true);
  f.resume(); assert.equal(s.brightness, 1);
  f.end(); assert.equal(s.brightness, 0.4); assert.equal(s.idleTimerDisabled, false); assert.equal(f.mode, "off");
  const b = fakeScreen(false); const g = createFreeze(b); g.startTracing({ maxBrightness: true }); assert.equal(b.brightness, 0.4, "Browser: keine Helligkeit");
  g.unlock(); assert.equal(b.idleTimerDisabled, false);
  const h = createFreeze(fakeScreen()); h.startTracing({ highContrast: true }); assert.equal(h.options.highContrast, true);
});

test("Bildschirm anlassen über die Wake-Lock-API (wo vorhanden), sonst still ohne Fehler", async () => {
  const calls = []; let released = 0;
  const nav = { wakeLock: { request: async t => { calls.push(t); return { release: async () => { released++; }, addEventListener() {} }; } } };
  const sc = browserScreen(nav); assert.equal(sc.supported, true); assert.equal(sc.supportsBrightness, false);
  sc.idleTimerDisabled = true; await new Promise(r => setTimeout(r, 0)); assert.deepEqual(calls, ["screen"]); assert.equal(sc.held, true);
  sc.idleTimerDisabled = false; await new Promise(r => setTimeout(r, 0)); assert.equal(released, 1); assert.equal(sc.held, false);
  const none = browserScreen({}); assert.equal(none.supported, false); none.idleTimerDisabled = true; assert.equal(none.idleTimerDisabled, true);
  const f = createFreeze(browserScreen(nav)); f.startTracing(); f.suspend(); f.resume(); await new Promise(r => setTimeout(r, 0));
  assert.ok(calls.length >= 2, "nach dem Hintergrund neu angefordert");
});

test("Zeiger bei fixierter Ansicht: Stift und Werkzeuge ja, Scrollen, Pinch und Hand nein; beim Abpausen nichts", () => {
  const P = o => pointerPolicy({ mode: "view", tool: "pen", penInput: "all", fingersDown: 0, ...o });
  assert.equal(P({ pointerType: "pen" }), "allow");
  assert.equal(P({ pointerType: "mouse", button: 0 }), "allow");
  assert.equal(P({ pointerType: "mouse", button: 1 }), "block", "mittlere Maustaste rollt");
  assert.equal(P({ pointerType: "pen", tool: "hand" }), "block");
  assert.equal(P({ pointerType: "mouse", spaceHand: true }), "block");
  assert.equal(P({ pointerType: "touch" }), "allow", "Finger darf schreiben");
  assert.equal(P({ pointerType: "touch", penInput: "pen_only" }), "block", "Finger würde scrollen");
  assert.equal(P({ pointerType: "touch", fingersDown: 1 }), "block", "zweiter Finger würde zoomen");
  assert.equal(P({ pointerType: "touch", tool: "lasso" }), "allow");
  for (const pointerType of ["pen", "mouse", "touch"]) {
    assert.equal(pointerPolicy({ mode: "trace", pointerType, tool: "pen" }), "block");
    assert.equal(pointerPolicy({ mode: "off", pointerType, tool: "hand", fingersDown: 3 }), "allow");
  }
});

test("Tasten: Strg/Cmd+L schaltet, Esc entsperrt nur beim Abpausen, Blättern und Zoomen gesperrt", () => {
  const K = (key, o = {}) => ({ key, ...o });
  assert.equal(keyAction("off", K("l", { ctrlKey: true })), "toggle");
  assert.equal(keyAction("view", K("L", { metaKey: true })), "toggle");
  assert.equal(keyAction("off", K("l", { ctrlKey: true, inField: true })), null, "im Textfeld nicht");
  assert.equal(keyAction("off", K("l", { ctrlKey: true, shiftKey: true })), null);
  assert.equal(keyAction("off", K("PageDown")), null);
  assert.equal(keyAction("view", K("PageDown")), "block");
  assert.equal(keyAction("view", K("+", { ctrlKey: true })), "block");
  assert.equal(keyAction("view", K("0", { ctrlKey: true })), "block");
  assert.equal(keyAction("view", K("z", { ctrlKey: true })), null, "Rückgängig geht weiter");
  assert.equal(keyAction("view", K("p")), null, "Werkzeugtasten gehen weiter");
  assert.equal(keyAction("view", K("ArrowDown", { inField: true })), null);
  assert.equal(keyAction("view", K("Escape")), null);
  assert.equal(keyAction("trace", K("Escape")), "unlock");
  assert.equal(keyAction("trace", K("l", { ctrlKey: true })), "block", "Strg+L löst das Abpausen nicht");
  assert.equal(keyAction("trace", K("z", { ctrlKey: true })), "block");
  assert.equal(keyAction("trace", K("Tab")), null);
  assert.equal(keyAction("trace", K("Enter", { onLock: true })), null, "Schloss per Tastatur");
  assert.equal(keyAction("trace", K("Enter")), "block");
});

test("Editor bindet das Fixieren ein (Import, Menü Mehr) und die Texte sind deutsch mit Umlauten", () => {
  const ed = readFileSync(new URL("../../app/static/editor.js", import.meta.url), "utf8");
  assert.match(ed, /import \{ attachFreeze \} from "\.\/editor-freeze\.js\?v=\d+"/);
  assert.match(ed, /this\.freeze = attachFreeze\(this\)/);
  assert.match(ed, /this\.freeze\?\.menuHtml\(\)/); assert.match(ed, /this\.freeze\?\.bindMenu\(this\.pop\)/);
  assert.equal(TEXTS.releaseView, "Ansicht lösen"); assert.equal(TEXTS.contrast, "Kontrast für Abpausen");
  const css = readFileSync(new URL("../../app/static/editor-freeze.css", import.meta.url), "utf8");
  assert.match(css, /\.ed\.ed-fixed \.ed-scroll \{ overflow: hidden/);
  assert.match(css, /\.ed\.ed-tracing \.ed-bar/);
});
