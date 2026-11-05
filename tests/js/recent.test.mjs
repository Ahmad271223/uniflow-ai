import { test } from "node:test";
import assert from "node:assert/strict";
import { itemHref, subtitle, resumeEntry, resumeTarget, resumeKey } from "../../app/static/recent-logic.js";

test("Ziel je Art: Dokument auf der Seite, Gespräch mit KI-Hilfe, Wochentest", () => {
  assert.equal(itemHref({ kind: "document", id: "f1", page: 4 }), "#/doc/f1?page=4");
  assert.equal(itemHref({ kind: "document", id: "f1", page: 1 }), "#/doc/f1");
  assert.equal(itemHref({ kind: "conversation", id: "f 2" }), "#/doc/f%202?ki=1");
  assert.equal(itemHref({ kind: "conversation", id: "exam:7:2", test_id: 7 }), "#/exams/7");
  assert.equal(itemHref({ kind: "test", id: "12" }), "#/exams/12");
});

test("Unterzeile nur mit dem, was es gibt", () => {
  assert.equal(subtitle({ kind: "document", sub: "Analysis", page: 4, at: "2026-11-03T10:00:00" }), "Dokument · Analysis · Seite 4 · Di., 03.11.");
  assert.equal(subtitle({ kind: "document", page: 1, at: "" }), "Dokument");
  assert.equal(subtitle({ kind: "test", done: true, score: 9, max_score: 12, at: "2026-11-02T08:00:00" }), "Wochentest · 75 % · Mo., 02.11.");
  assert.equal(subtitle({ kind: "test", done: false, sub: "Physik" }), "Wochentest · Physik · begonnen");
  assert.equal(subtitle({ kind: "conversation", sub: "Skript.pdf" }), "KI-Gespräch · Skript.pdf");
});

test("Stand je Route", () => {
  assert.deepEqual(resumeEntry("#/doc/abc?page=3"), { route: "doc", file: "abc", page: 3, ai: false });
  assert.deepEqual(resumeEntry("#/doc/abc?page=3", { page: 7, ai: true }), { route: "doc", file: "abc", page: 7, ai: true });
  assert.deepEqual(resumeEntry("#/doc/a%20b?ki=1"), { route: "doc", file: "a b", page: 1, ai: true });
  assert.deepEqual(resumeEntry("#/plan?view=day"), { route: "plan" });
  assert.deepEqual(resumeEntry(""), { route: "dashboard" });
  assert.deepEqual(resumeEntry("#/doc"), { route: "doc" });
});

test("Weitermachen nur nach offenem Dokument und Start auf der Übersicht", () => {
  const saved = { route: "doc", file: "abc", page: 5, ai: true };
  assert.equal(resumeTarget(saved, ""), "#/doc/abc?page=5&ki=1");
  assert.equal(resumeTarget(saved, "#/dashboard"), "#/doc/abc?page=5&ki=1");
  assert.equal(resumeTarget({ ...saved, ai: false }, "#/"), "#/doc/abc?page=5");
  assert.equal(resumeTarget(saved, "#/abo"), null, "Abo-Seite (gesperrt) oder andere Adresse: nichts tun");
  assert.equal(resumeTarget({ route: "plan" }, ""), null, "Dokument ausdrücklich verlassen");
  assert.equal(resumeTarget(null, ""), null);
  assert.equal(resumeKey("u1"), "uniflow.resume.u1");
  assert.equal(resumeKey(), "uniflow.resume.local");
});
