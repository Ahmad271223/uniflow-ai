// Gemeinsame Zusammenfuehrungs-Testfaelle gegen app/static/merge.js. Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mergePage, stableStringify } from "../../app/static/merge.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const { cases } = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/merge/cases.json"), "utf8"));

for (const c of cases) {
  test(c.name, () => {
    const r = mergePage(c.base, c.local, c.server);
    if (c.expectIds === null) {
      assert.equal(r.page, null);
    } else {
      assert.deepEqual(r.page.objects.map(o => o.id ?? null), c.expectIds);
    }
    assert.equal(r.conflicts, c.expectConflicts);
    if (c.expectField) assert.equal(r.page.objects[c.expectField.index][c.expectField.key], c.expectField.value);
    if (c.expectPageField) assert.equal(stableStringify(r.page[c.expectPageField.key]), stableStringify(c.expectPageField.value));
  });
}

test("stableStringify ist unabhaengig von der Feldreihenfolge", () => {
  assert.equal(stableStringify({ b: 1, a: [2, { d: 3, c: 4 }] }), stableStringify({ a: [2, { c: 4, d: 3 }], b: 1 }));
});
