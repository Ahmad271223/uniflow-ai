// Cache-Nummern der Oberflaeche (?v=N): jede Datei wird ueberall mit derselben Nummer eingebunden. Sonst laedt der
// Browser ein Modul doppelt (zwei getrennte Zustaende, z. B. views-qa.js mit v=10 und v=11 bis 13.11.2026) oder eine
// Seite einen veralteten Stil. Hochzaehlen mit tools/bump-static.py. Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

test("jede Datei hat ueberall dieselbe Cache-Nummer", () => {
  const dir = join(import.meta.dirname, "../../app/static");
  const refs = new Map();
  for (const f of readdirSync(dir).filter(n => /\.(js|mjs|html)$/.test(n))) {
    for (const m of readFileSync(join(dir, f), "utf8").matchAll(/([\w.-]+\.(?:js|mjs|css))\?v=(\d+)/g)) {
      if (!refs.has(m[1])) refs.set(m[1], new Map());
      refs.get(m[1]).set(m[2], [...(refs.get(m[1]).get(m[2]) || []), f]);
    }
  }
  const bad = [...refs].filter(([, v]) => v.size > 1).map(([k, v]) => `${k}: ${[...v].map(([n, fs]) => `v=${n} in ${fs.join(", ")}`).join(" | ")}`);
  assert.deepEqual(bad, []);
});
