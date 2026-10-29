// Gemeinsame Drehen-Testfaelle gegen app/static/pagerotate.js. Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { rotateObjects, rotatedSize } from "../../app/static/pagerotate.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const { cases } = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/rotate/cases.json"), "utf8"));

for (const c of cases) {
  test(c.name, () => {
    const before = JSON.stringify(c.objects);
    assert.deepEqual(rotateObjects(c.objects, c.width, c.height, c.deg), c.expect);
    assert.equal(JSON.stringify(c.objects), before, "Eingabe bleibt unveraendert");
  });
}

test("Groesse nach dem Drehen", () => {
  assert.deepEqual(rotatedSize(595, 842, 90), { w: 842, h: 595 });
  assert.deepEqual(rotatedSize(595, 842, 180), { w: 595, h: 842 });
});
