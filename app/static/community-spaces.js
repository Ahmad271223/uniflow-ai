// Communities je Modul und Lerngruppe (wie CommunitySpacesCard auf dem iPad): beitreten, verlassen, Loesungen
// ansehen. Der Schluessel einer Community entsteht aus Modulname bzw. Beitrittscode und oeffnet ihre Pakete auch ohne die
// PDF; dann stehen die Notizen auf leeren Seiten. Codes bleiben in diesem Browser, der Dienst kennt nur den Gruppen-Schluessel.
import { $, $$, api, esc, icon, toast, showError, drawer, closeDrawer } from "./core.js?v=39";
import * as S from "./solutions.js?v=6";

const GROUPS = "community-groups";
export async function groupKey(university, code) { return S.sha256Hex(S.utf8(`uniflow.community.group.v1\0${university}\0${code}`)); }
const hexBytes = h => new Uint8Array(h.match(/../g).map(x => parseInt(x, 16)));
function storedGroups() { try { return JSON.parse(localStorage.getItem(GROUPS) || "[]"); } catch { return []; } }
function saveGroups(list) { try { localStorage.setItem(GROUPS, JSON.stringify(list)); } catch {} }

/** Kurse aus dem Abgleich und Lerngruppen dieses Browsers, zusammengefuehrt mit dem Stand des Dienstes. */
export async function loadSpaces() {
  // auch fruehere Semester (eingeklappt unter "Frühere Kurse"); `current` = ein Kurs des Moduls ist aktiv
  const { university, courses } = await api("/courses/community-keys?all=true");
  // aktuelle Module zuerst melden: die Tagesgrenze neuer Schluessel laesst sonst eher fruehere durch
  const claimKeys = [...new Set([...courses.filter(c => c.current), ...courses.filter(c => !c.current)].map(c => c.key).filter(Boolean))];
  await api("/community/claims", { method: "POST", body: { fingerprints: [], course_keys: claimKeys } });
  const rows = new Map((await api("/community/communities")).communities.map(r => [r.community_key, r]));
  // alle Veranstaltungen eines Moduls teilen sich eine Community
  const modules = [...new Map(courses.filter(c => c.key).map(c => [c.key, c])).values()];
  const spaces = modules.map(c => ({ key: c.key, kind: "course", name: c.module || c.title, current: c.current !== false, secret: hexBytes(c.secret), ...stateOf(rows.get(c.key)) }));
  for (const g of storedGroups()) {
    const key = await groupKey(university, g.code); const r = rows.get(key);
    if (r?.joined) spaces.push({ key, kind: "group", name: r.name || g.name, code: g.code, secret: await S.communitySecret("group", university, g.code), ...stateOf(r) });
  }
  return { university, spaces };
}
const stateOf = r => ({ joined: !!r?.joined, members: r?.members ?? 0, solutions: r?.solutions ?? 0 });

/** Community-Paket mit einem der bekannten Schluessel oeffnen; das Paket nennt seine Community nicht. */
export async function openWithSpaces(pkg, spaces) {
  for (const s of spaces) { try { return await S.openPackage(pkg, null, null, s.secret); } catch {} }
  throw Object.assign(new Error("Diese Lösung lässt sich hier nicht öffnen."), { code: "decryptionFailed" });
}

async function decodeImages(content) {
  const out = {};
  for (const [src, img] of Object.entries(content.images || {})) {
    await new Promise(res => { const i = new Image(); i.onload = () => { out[src] = i; res(); }; i.onerror = res; i.src = `data:${img.mime};base64,${img.data}`; });
  }
  return out;
}

async function showReader(solution, spaces) {
  const d = drawer(`<div class="drawer-head"><h2>${esc(solution.title || "Lösung")}</h2><button class="btn ghost icon" data-x>${icon("x", 16)}</button></div><div class="com-reader small muted">Wird geladen …</div>`);
  $("[data-x]", d).onclick = closeDrawer;
  const box = $(".com-reader", d);
  try {
    const { package: pkg } = await api(`/community/solutions/${solution.solution_id}`);
    const content = await openWithSpaces(pkg, spaces); const images = await decodeImages(content);
    const local = await fetch(`/api/files/by-fingerprint/${solution.fingerprint}`).then(r => (r.ok ? r.json() : null)).catch(() => null);
    box.className = "com-reader";
    box.innerHTML = local ? `<p class="small">Du hast dieselbe PDF. <a href="#/doc/${esc(local.file_id)}">Im Dokument ansehen</a> – dort liegt die Lösung über deiner PDF.</p>` : `<p class="small muted">Du hast diese PDF nicht, darum stehen die Notizen auf leeren Seiten.</p>`;
    for (const page of content.pages) {
      const c = document.createElement("canvas"), sc = 2; c.width = page.width * sc; c.height = page.height * sc; c.style.cssText = "width:100%;background:#fff;border:1px solid var(--line);margin-bottom:.6rem";
      const ctx = c.getContext("2d"); ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, c.width, c.height); ctx.scale(sc, sc); S.drawObjects(ctx, page, images); box.append(c);
    }
  } catch (e) { box.textContent = e.message; }
}

async function showSpace(space, spaces) {
  const d = drawer(`<div class="drawer-head"><h2>${esc(space.name)}</h2><button class="btn ghost icon" data-x>${icon("x", 16)}</button></div><div class="com-list small muted">Wird geladen …</div>`);
  $("[data-x]", d).onclick = closeDrawer;
  const box = $(".com-list", d);
  try {
    const rows = (await api(`/community/communities/${space.key}/solutions`)).solutions;
    box.className = "com-list";
    box.innerHTML = rows.length ? rows.map(s => `<div class="row wrap" style="justify-content:space-between;padding:.4rem 0"><span><b>${esc(s.title || "Lösung")}</b><br><span class="tiny muted">${esc(s.display_name || s.pseudonym)}</span></span><button class="btn sm" data-read="${esc(s.solution_id)}">Ansehen</button></div>`).join("") : `<p class="small muted">Noch keine Lösungen in dieser Community.</p>`;
    $$("[data-read]", box).forEach(b => b.onclick = () => showReader(rows.find(s => s.solution_id === b.dataset.read), spaces));
  } catch (e) { box.textContent = e.message; }
}

/** Sichtbare Communities: Lerngruppen und Module des aktuellen Semesters, mit `showOlder` auch fruehere (wie
 *  CommunitySpacesCard auf dem iPad). `older` = Module nur frueherer Semester (Zahl am Knopf). */
export function visibleSpaces(spaces, showOlder) {
  const older = spaces.filter(s => s.kind === "course" && s.current === false);
  return { older, shown: showOlder ? spaces : spaces.filter(s => s.kind === "group" || s.current !== false) };
}
let showOlder = false;

/** Karte "Deine Communities" auf der Community-Seite. */
export async function renderSpaces(el) {
  el.innerHTML = `<p class="small muted">Wird geladen …</p>`;
  let data;
  try { data = await loadSpaces(); } catch (e) { el.innerHTML = `<p class="small">${esc(e.message)}</p>`; return; }
  const { university, spaces } = data; const reload = () => renderSpaces(el);
  const { older, shown } = visibleSpaces(spaces, showOlder);
  const line = s => `<div class="row wrap" style="justify-content:space-between;padding:.35rem 0"><span>${icon(s.kind === "group" ? "users" : "book", 15)} <b>${esc(s.name)}</b> <span class="tiny muted">${s.kind === "course" && s.current === false ? "früheres Semester · " : ""}${s.members} Mitglieder · ${s.solutions} Lösungen${s.code ? ` · Code ${esc(s.code)}` : ""}</span></span>
    <span class="row" style="gap:.3rem">${s.joined ? `<button class="btn sm" data-open="${s.key}">Öffnen</button><button class="btn sm ghost" data-leave="${s.key}">Verlassen</button>` : `<button class="btn sm primary" data-join="${s.key}">Beitreten</button>`}</span></div>`;
  el.innerHTML = `<p class="small muted" style="margin-top:0">Jeder Kurs hat seine eigene Community. Tritt bei, dann siehst und teilst du dort Lösungen.</p>
    ${shown.map(line).join("") || (older.length ? "" : `<p class="small muted">Noch keine Kurse. Gleiche zuerst deine Hochschule ab.</p>`)}
    ${older.length ? `<button class="btn sm ghost" id="spOlder" aria-expanded="${showOlder}" style="margin-top:.3rem">${icon(showOlder ? "eye-off" : "clock", 14)} ${showOlder ? "Frühere Kurse ausblenden" : `Frühere Kurse (${older.length})`}</button>` : ""}
    <div class="row wrap" style="gap:.4rem;margin-top:.6rem"><input class="input" id="grpName" placeholder="Name der neuen Lerngruppe" maxlength="60" style="max-width:220px"><button class="btn sm" id="grpNew">Anlegen</button>
    <input class="input" id="grpCode" placeholder="Beitrittscode" maxlength="9" style="max-width:150px"><button class="btn sm" id="grpJoin">Beitreten</button></div>`;
  const run = async fn => { try { await fn(); reload(); } catch (e) { showError(e, 4000); } };
  const byKey = k => spaces.find(s => s.key === k);
  $("#spOlder", el)?.addEventListener("click", () => { showOlder = !showOlder; reload(); });
  $$("[data-open]", el).forEach(b => b.onclick = () => showSpace(byKey(b.dataset.open), spaces));
  $$("[data-join]", el).forEach(b => b.onclick = () => run(() => api(`/community/communities/${b.dataset.join}/join`, { method: "POST", body: { kind: "course" } })));
  $$("[data-leave]", el).forEach(b => b.onclick = () => run(async () => {
    const s = byKey(b.dataset.leave); await api(`/community/communities/${s.key}/join`, { method: "DELETE" });
    if (s.code) saveGroups(storedGroups().filter(g => g.code !== s.code));
  }));
  $("#grpNew", el).onclick = () => run(async () => {
    const name = $("#grpName", el).value.trim(); const bytes = S.randomBytes(8);
    const code = [...bytes].map(x => S.CODE_ALPHABET[x % S.CODE_ALPHABET.length]).join("");
    await api("/community/groups", { method: "POST", body: { group_key: await groupKey(university, code), name } });
    saveGroups([...storedGroups(), { code, name }]); toast(`Beitrittscode: ${code}`, 8000);
  });
  $("#grpJoin", el).onclick = () => run(async () => {
    const code = S.normalizedCode($("#grpCode", el).value); if (!code) throw new Error("Ein Beitrittscode hat 8 Zeichen (Buchstaben und Ziffern).");
    await api(`/community/communities/${await groupKey(university, code)}/join`, { method: "POST", body: { kind: "group" } });
    saveGroups([...storedGroups().filter(g => g.code !== code), { code, name: code }]);
  });
}
