// Bibliothek: Modulordner (Vorlage), Schnellzugriff, Typ-Chips, Ordner, Vorschauen, Favoriten, Zuletzt, Papierkorb, Neu-Menü
import { $, $$, api, esc, icon, toast, modal, fmtDate, debounce, initial, TYPE_TXT, TYPE_ICON, state } from "./core.js?v=20";
import { renderThumbnail, TEMPLATES } from "./editor.js?v=20";

const TYPE_FOLDERS = [["vorlesung", "Vorlesungen"], ["uebung", "Übungen"], ["loesung", "Lösungen"], ["skript", "Skripte"], ["klausur", "Klausuren"], ["sonstiges", "Sonstiges"]];
const CHIPS = [["all", "Alle"], ["vorlesung", "Vorlesungen"], ["uebung", "Übungen"], ["skript", "Skripte"], ["klausur", "Klausuren"], ["notes", "Notizen"], ["sonstiges", "Sonstiges"]];
const FILE_COLORS = { vorlesung: "#e5484d", uebung: "#2f7fd1", skript: "#d9851e", klausur: "#8b5cf6", loesung: "#1f9d5b", notebook: "#7c3aed", whiteboard: "#0ea5a0", image: "#1f9d5b", sonstiges: "#7a8199" };
let lib = null, mode = "grid", sort = "date", filter = "all";
try { mode = localStorage.getItem("lib-mode") || "grid"; } catch {}
const ago = v => { if (!v) return ""; const d = typeof v === "number" ? new Date(v * 1000) : new Date(v); const days = Math.floor((Date.now() - d) / 864e5); return days <= 0 ? "heute" : days === 1 ? "gestern" : days < 30 ? `vor ${days} Tagen` : fmtDate(d); };
const fileType = f => f.kind === "pdf" ? (f.doc_type || "sonstiges") : f.kind;

export async function viewFiles(_, params, view) {
  lib = await api("/library");
  const path = params.path || ""; const section = params.section || (params.new ? "new" : "docs");
  const crumbs = [{ label: "Dokumente & Notizen", path: "" }];
  let items = [];
  const modById = Object.fromEntries(lib.modules.map(m => [m.id, m]));
  const folderById = Object.fromEntries(lib.folders.map(f => [f.id, f]));
  const activeFiles = lib.files;
  const docItem = f => ({ kind: "doc", f });
  const q = (params.q || "").toLowerCase();
  const root = section === "docs" && !path && !q && filter === "all";
  if (section === "fav") items = activeFiles.filter(f => f.favorite).map(docItem);
  else if (section === "recent") items = activeFiles.filter(f => f.last_opened || f.edited_at).sort((a, b) => (b.edited_at || b.last_opened || "").localeCompare(a.edited_at || a.last_opened || "")).slice(0, 60).map(docItem);
  else if (section === "new") items = activeFiles.filter(f => f.status === "neu").map(docItem);
  else if (section === "trash") items = lib.trash.map(f => ({ kind: "trash", f }));
  else {
    const seg = path ? path.split("/") : [];
    if (!seg.length) {
      items = [...lib.modules.map(m => ({ kind: "folder", id: "m" + m.id, label: m.name, color: m.color, count: activeFiles.filter(f => f.module_id === m.id).length, path: "m" + m.id, module: m })),
        ...lib.folders.filter(f => !f.parent_id && !f.module_id).map(f => ({ kind: "folder", id: "f" + f.id, label: f.name, color: f.color || "#8b93a8", count: activeFiles.filter(x => x.folder_id === f.id).length, path: "f" + f.id, user: f })),
        ...activeFiles.filter(f => f.course_id === "__user__" && !f.folder_id).map(docItem)];
      if (filter !== "all") items = activeFiles.filter(f => filter === "notes" ? f.kind !== "pdf" && f.kind !== "image" : fileType(f) === filter).map(docItem);
    } else if (seg[0].startsWith("m")) {
      const mid = +seg[0].slice(1); const m = modById[mid]; crumbs.push({ label: m?.name || "Modul", path: seg[0] });
      const modFiles = activeFiles.filter(f => f.module_id === mid);
      if (seg.length === 1) {
        items = [...TYPE_FOLDERS.map(([k, l]) => ({ k, l, n: modFiles.filter(f => (f.doc_type || "sonstiges") === k && f.course_id !== "__user__").length })).filter(x => x.n).map(x => ({ kind: "folder", id: seg[0] + "/" + x.k, label: x.l, color: m?.color, count: x.n, path: seg[0] + "/" + x.k })),
          ...lib.folders.filter(f => f.module_id === mid && !f.parent_id).map(f => ({ kind: "folder", id: "f" + f.id, label: f.name, color: f.color || m?.color, count: activeFiles.filter(x => x.folder_id === f.id).length, path: seg[0] + "/f" + f.id, user: f })),
          ...modFiles.filter(f => f.course_id === "__user__" && !f.folder_id).map(docItem)];
      } else if (seg[1].startsWith("f")) { const fid = +seg[1].slice(1); crumbs.push({ label: folderById[fid]?.name || "Ordner", path: seg.join("/") }); items = [...lib.folders.filter(f => f.parent_id === fid).map(f => ({ kind: "folder", id: "f" + f.id, label: f.name, color: f.color || m?.color, count: activeFiles.filter(x => x.folder_id === f.id).length, path: seg.join("/") + "/f" + f.id, user: f })), ...activeFiles.filter(f => f.folder_id === fid).map(docItem)]; }
      else { const t = seg[1]; crumbs.push({ label: TYPE_FOLDERS.find(x => x[0] === t)?.[1] || t, path: seg.join("/") }); items = modFiles.filter(f => (f.doc_type || "sonstiges") === t && f.course_id !== "__user__").map(docItem); }
      if (filter !== "all" && seg.length === 1) items = modFiles.filter(f => filter === "notes" ? f.kind !== "pdf" && f.kind !== "image" : fileType(f) === filter).map(docItem);
    } else if (seg[0].startsWith("f")) {
      let parent = null; seg.forEach(s => { const fid = +s.slice(1); const fo = folderById[fid]; crumbs.push({ label: fo?.name || "Ordner", path: seg.slice(0, seg.indexOf(s) + 1).join("/") }); parent = fid; });
      items = [...lib.folders.filter(f => f.parent_id === parent).map(f => ({ kind: "folder", id: "f" + f.id, label: f.name, color: f.color || "#8b93a8", count: activeFiles.filter(x => x.folder_id === f.id).length, path: path + "/f" + f.id, user: f })), ...activeFiles.filter(f => f.folder_id === parent).map(docItem)];
    }
  }
  if (q) items = activeFiles.filter(f => (f.title + " " + f.name + " " + (f.ai_title || "") + " " + (f.subject || "")).toLowerCase().includes(q)).map(docItem);
  items.sort((a, b) => { if (a.kind !== b.kind) return a.kind === "folder" ? -1 : 1; if (a.kind !== "doc") return 0; return sort === "name" ? a.f.title.localeCompare(b.f.title, "de") : (b.f.edited_at || "").localeCompare(a.f.edited_at || "") || b.f.chdate - a.f.chdate; });
  const current = crumbs[crumbs.length - 1]; const curMod = path.startsWith("m") ? +path.split("/")[0].slice(1) : "";
  const newCount = lib.files.filter(f => f.status === "neu").length;
  const recent = activeFiles.filter(f => f.last_opened || f.edited_at).sort((a, b) => (b.edited_at || b.last_opened || "").localeCompare(a.edited_at || a.last_opened || "")).slice(0, 4);
  const sectionTitle = { fav: "Favoriten", recent: "Zuletzt bearbeitet", new: "Neu aus Stud.IP", trash: "Papierkorb" }[section];
  view.innerHTML = `<div class="content" style="max-width:1480px">
    <div class="page-head"><div><h1>Dokumente & Notizen</h1><div class="sub">Alle Materialien deiner Module an einem Ort. Übersichtlich, schnell und fokussiert.</div></div>
      <div class="actions"><div class="search-inline">${icon("search", 15)}<input class="input" id="libQ" placeholder="In Dokumenten suchen…" value="${esc(params.q || "")}"></div>
        <select class="input" id="libMod" style="width:auto"><option value="">Alle Module</option>${lib.modules.map(m => `<option value="${m.id}" ${curMod === m.id ? "selected" : ""}>${esc(m.name)}</option>`).join("")}</select>
        <select class="input" id="libSort" style="width:auto"><option value="date" ${sort === "date" ? "selected" : ""}>Zuletzt bearbeitet</option><option value="name" ${sort === "name" ? "selected" : ""}>Name</option></select>
        <div class="seg"><button class="${mode === "grid" ? "active" : ""}" data-m="grid" title="Kacheln">${icon("grid", 15)}</button><button class="${mode === "list" ? "active" : ""}" data-m="list" title="Liste">${icon("list", 15)}</button></div><button class="btn primary" id="libNew">${icon("plus", 16)} Neu</button></div></div>
    <div class="row between wrap" style="margin-bottom:1.2rem"><div class="chips">${CHIPS.map(([k, l]) => `<button class="chip ${filter === k && section === "docs" ? "on" : ""}" data-chip="${k}">${l}</button>`).join("")}</div>
      <div class="row small" style="gap:.3rem">${[["fav", "Favoriten", "star"], ["recent", "Zuletzt", "clock"], ["new", "Neu aus Stud.IP", "sparkles"], ["trash", "Papierkorb", "trash"]].map(([k, l, i]) => `<a class="btn ghost sm ${section === k ? "active" : ""}" href="#/files?section=${k}" style="${section === k ? "background:var(--accent-soft);color:var(--accent-text)" : ""}">${icon(i, 14)} ${l}${k === "new" && newCount ? ` <span class="badge">${newCount}</span>` : ""}</a>`).join("")}</div></div>
    ${!root ? `<div class="lib-head"><div class="lib-crumbs">${section !== "docs" ? `<b>${sectionTitle}</b>` : crumbs.map((c, i) => i === crumbs.length - 1 ? `<b>${esc(c.label)}</b>` : `<a href="#/files?path=${c.path}">${esc(c.label)}</a><span class="muted">›</span>`).join("")}${q ? `<span class="muted">· Suche „${esc(params.q)}“</span>` : filter !== "all" && section === "docs" ? `<span class="muted">· ${CHIPS.find(c => c[0] === filter)?.[1]}</span>` : ""}</div></div>` : ""}
    ${section === "trash" ? `<p class="muted small">Dokumente im Papierkorb lassen sich wiederherstellen. Stud.IP-Dokumente bleiben erhalten, eigene Dokumente können endgültig gelöscht werden.</p>` : ""}
    ${root ? `<div class="folder-grid">${items.filter(i => i.kind === "folder").map(folderCard).join("")}</div>${items.some(i => i.kind === "doc") ? `<div class="quick-card"><div class="card-head"><h2>${icon("note", 18)} Eigene Dokumente</h2></div>${mode === "grid" ? `<div class="lib-grid">${items.filter(i => i.kind === "doc").map(gridItem).join("")}</div>` : `<div class="lib-list">${items.filter(i => i.kind === "doc").map(listItem).join("")}</div>`}</div>` : ""}
      <div class="quick-card"><div class="card-head"><h2>${icon("clock", 18)} Schnellzugriff</h2><a class="small" href="#/files?section=recent">Alle anzeigen →</a></div>${recent.length ? `<div class="quick-list">${recent.map(quickItem).join("")}</div>` : `<div class="muted small">Zuletzt geöffnete Dokumente erscheinen hier.</div>`}</div>`
      : items.length ? (mode === "grid" ? `<div class="lib-grid">${items.map(gridItem).join("")}</div>` : `<div class="card pad-0 lib-list">${items.map(listItem).join("")}</div>`) : `<div class="card empty">${icon("folder", 36)}<div>${section === "trash" ? "Papierkorb ist leer." : q ? "Keine Treffer." : "Hier ist noch nichts. Über „Neu“ ein Notizbuch anlegen oder eine PDF importieren."}</div></div>`}
    </div>`;
  $("#libQ").oninput = debounce(e => { const v = e.target.value; location.hash = `#/files?section=${section}&path=${path}&q=${encodeURIComponent(v)}`; }, 300);
  $("#libMod").onchange = e => { location.hash = e.target.value ? `#/files?path=m${e.target.value}` : "#/files"; }; $("#libSort").onchange = e => { sort = e.target.value; state.route(); };
  $$("[data-chip]", view).forEach(c => c.onclick = () => { filter = c.dataset.chip; if (section !== "docs") location.hash = "#/files"; else state.route(); });
  $$("[data-m]", view).forEach(b => b.onclick = () => { mode = b.dataset.m; try { localStorage.setItem("lib-mode", mode); } catch {} state.route(); });
  $("#libNew").onclick = () => newMenu(path, current);
  $$("[data-open]", view).forEach(el => el.onclick = e => { if (e.target.closest("[data-menu]")) return; const it = el.dataset.open; if (!it) return; location.hash = it.startsWith("doc:") ? `#/doc/${it.slice(4)}` : `#/files?path=${it.slice(5)}`; });
  $$("[data-menu]", view).forEach(b => b.onclick = e => { e.stopPropagation(); itemMenu(b.dataset.menu, b); });
  $$("[data-fav]", view).forEach(b => b.onclick = async e => { e.stopPropagation(); const f = lib.files.find(x => x.id === b.dataset.fav); await api(`/files/${f.id}/favorite`, { method: "POST", body: { favorite: !f.favorite } }); state.route(); });
  // Vorschaubilder lazy laden
  const io = new IntersectionObserver(ens => ens.forEach(async en => { if (!en.isIntersecting) return; io.unobserve(en.target); const f = lib.files.find(x => x.id === en.target.dataset.thumb); if (!f) return; const data = await renderThumbnail(f.id, `/api/files/${f.id}/content`, f.edited_at || f.chdate, 220); if (data) en.target.innerHTML = `<img src="${data}" alt="">` + (en.target.querySelector(".lib-star")?.outerHTML || ""); }), { rootMargin: "400px" });
  $$("[data-thumb]", view).forEach(el => io.observe(el));
}
function folderCard(it) {
  const ini = it.module ? initial(it.label) : icon("folder", 20);
  return `<div class="folder-card" style="--fc:${it.color || "#4f8ef7"}" data-open="path:${it.path}"><div class="wave"></div><div class="fold"></div><div class="ini">${ini}</div><div class="row2"><div class="nm">${esc(it.label)}</div><button class="kebab" data-menu="${it.module ? "module:" + it.module.id : "folder:" + it.user.id}" title="Mehr">${icon("more", 18)}</button></div><div class="cnt">${it.count} Dokument${it.count === 1 ? "" : "e"}</div></div>`;
}
function quickItem(f) {
  const t = fileType(f); const ic = f.kind === "pdf" ? "file-text" : (TYPE_ICON[f.kind] || "file");
  return `<div class="quick-item" data-open="doc:${f.id}"><div class="fi" style="background:${FILE_COLORS[t] || FILE_COLORS.sonstiges}">${icon(ic, 18)}</div><div class="m"><b>${esc(f.title)}</b><span>${esc(f.subject || "Eigene Notizen")} · ${ago(f.edited_at || f.last_opened)}</span></div></div>`;
}
function gridItem(it) {
  if (it.kind === "folder") return `<div class="lib-item" data-open="path:${it.path}"><div class="lib-folder" style="--fc:${it.color || "#4f8ef7"}"></div><div class="nm"><span>${esc(it.label)}</span>${it.user ? `<i class="menu-btn2" data-menu="folder:${it.user.id}">${icon("chevron-down", 14)}</i>` : ""}</div><div class="dt">${it.count} Dokumente</div></div>`;
  const f = it.f; const isPdf = f.kind === "pdf" && f.downloaded_at;
  return `<div class="lib-item ${f.favorite ? "fav" : ""}" data-open="${it.kind === "trash" ? "" : "doc:" + f.id}"><div class="lib-thumb ${f.kind}" ${isPdf ? `data-thumb="${f.id}"` : ""}>${isPdf ? `<span class="ph">${icon("file-text", 28)}</span>` : f.kind === "whiteboard" ? `<span class="ph">${icon("square", 28)}</span>` : f.kind === "image" ? `<img src="/api/files/${f.id}/content">` : `<span class="ph">${icon("note", 28)}</span>`}${it.kind !== "trash" ? `<span class="lib-star" data-fav="${f.id}">${icon("star", 16)}</span>` : ""}</div><div class="nm"><span>${esc(f.title)}</span><i class="menu-btn2" data-menu="${it.kind === "trash" ? "trash" : "doc"}:${f.id}">${icon("chevron-down", 14)}</i></div><div class="dt">${it.kind === "trash" ? "gelöscht " + fmtDate(f.deleted_at) : (f.edited_at ? "bearbeitet " + fmtDate(f.edited_at) : fmtDate(f.chdate)) + (f.status === "neu" ? " · <b style='color:var(--accent-text)'>Neu</b>" : "")}</div></div>`;
}
function listItem(it) {
  if (it.kind === "folder") return `<div class="lib-row" data-open="path:${it.path}"><div class="mini folder" style="--fc:${it.color || "#4f8ef7"}">${icon("folder", 16)}</div><b>${esc(it.label)}</b><span class="muted small hide-m">Ordner</span><span class="muted small hide-m">${it.count} Dokumente</span><span class="hide-m"></span><span>${it.user ? `<i class="menu-btn2" data-menu="folder:${it.user.id}">${icon("more", 16)}</i>` : ""}</span></div>`;
  const f = it.f; const isPdf = f.kind === "pdf" && f.downloaded_at;
  return `<div class="lib-row" data-open="${it.kind === "trash" ? "" : "doc:" + f.id}"><div class="mini" ${isPdf ? `data-thumb="${f.id}"` : ""}>${icon(TYPE_ICON[f.kind === "pdf" ? (f.doc_type || "pdf") : f.kind] || "file", 16)}</div><div><b>${esc(f.title)}</b>${f.ai_title && f.ai_title !== f.title ? `<div class="muted tiny">${esc(f.name)}</div>` : ""}</div><span class="muted small hide-m">${esc(TYPE_TXT[f.kind === "pdf" ? (f.doc_type || "pdf") : f.kind] || "")}</span><span class="muted small hide-m">${esc(f.subject || "Eigene")}</span><span class="muted small hide-m">${fmtDate(f.edited_at || f.chdate)}</span><span><i class="menu-btn2" data-menu="${it.kind === "trash" ? "trash" : "doc"}:${f.id}">${icon("more", 16)}</i></span></div>`;
}
function newMenu(path, current) {
  const seg = path ? path.split("/") : []; const moduleId = seg[0]?.startsWith("m") ? +seg[0].slice(1) : null; const folderId = seg.length && seg[seg.length - 1].startsWith("f") ? +seg[seg.length - 1].slice(1) : null;
  const m = modal(`<h3>Neu${current.path ? ` in „${esc(current.label)}“` : ""}</h3><div class="stack">
    <button class="btn" data-n="notebook">${icon("note", 16)} Notizbuch</button><button class="btn" data-n="whiteboard">${icon("square", 16)} Whiteboard</button><button class="btn" data-n="folder">${icon("folder", 16)} Ordner</button>
    <button class="btn" data-n="pdf">${icon("file-text", 16)} PDF importieren</button><button class="btn" data-n="image">${icon("image", 16)} Bild importieren</button></div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button></div>`);
  $$("[data-n]", m).forEach(b => b.onclick = async () => {
    const k = b.dataset.n; m.remove();
    if (k === "folder") { const name = prompt("Name des Ordners:", "Neuer Ordner"); if (!name) return; await api("/folders", { method: "POST", body: { name, parent_id: folderId, module_id: moduleId } }); state.route(); return; }
    if (k === "notebook" || k === "whiteboard") { notebookDialog(k, moduleId, folderId); return; }
    const inp = document.createElement("input"); inp.type = "file"; inp.accept = k === "pdf" ? "application/pdf" : "image/*"; inp.multiple = true;
    inp.onchange = async () => { for (const file of inp.files) { const fd = new FormData(); fd.append("kind", k); fd.append("title", file.name.replace(/\.[^.]+$/, "")); if (moduleId) fd.append("module_id", String(moduleId)); if (folderId) fd.append("folder_id", String(folderId)); fd.append("upload", file); await api("/notebooks", { method: "POST", body: fd }); } toast("Importiert"); state.route(); }; inp.click();
  });
}
function notebookDialog(kind, moduleId, folderId) {
  const m = modal(`<h3>${kind === "whiteboard" ? "Neues Whiteboard" : "Neues Notizbuch"}</h3><label class="field">Titel<input class="input" id="nbTitle" value="${kind === "whiteboard" ? "Whiteboard" : "Notizen"}"></label>
    ${kind === "notebook" ? `<label class="field">Vorlage<div class="ed-tpl-grid" style="grid-template-columns:repeat(6,1fr)">${Object.entries(TEMPLATES).map(([k, n]) => `<button type="button" class="chip ${k === "lined" ? "on" : ""}" data-tpl="${k}" style="flex-direction:column"><i class="ed-tpl ${k}" style="width:38px;height:48px"></i>${n}</button>`).join("")}</div></label>` : ""}
    <label class="field">Modul (optional)<select class="input" id="nbMod"><option value="">– keins –</option>${lib.modules.map(x => `<option value="${x.id}" ${x.id === moduleId ? "selected" : ""}>${esc(x.name)}</option>`).join("")}</select></label>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="nbOk">Erstellen</button></div>`);
  let tpl = "lined"; $$("[data-tpl]", m).forEach(b => b.onclick = () => { tpl = b.dataset.tpl; $$("[data-tpl]", m).forEach(x => x.classList.toggle("on", x === b)); });
  $("#nbOk", m).onclick = async () => { const fd = new FormData(); fd.append("kind", kind); fd.append("title", $("#nbTitle", m).value || "Notizen"); fd.append("template", tpl); if ($("#nbMod", m).value) fd.append("module_id", $("#nbMod", m).value); if (folderId) fd.append("folder_id", String(folderId)); const r = await api("/notebooks", { method: "POST", body: fd }); m.remove(); location.hash = `#/doc/${r.id}`; };
}
function itemMenu(key, anchor) {
  const [kind, id] = key.split(":");
  if (kind === "folder") { const f = lib.folders.find(x => x.id === +id); const m = modal(`<h3>Ordner „${esc(f.name)}“</h3><div class="stack"><button class="btn" data-a="rename">${icon("pencil", 16)} Umbenennen</button><button class="btn" data-a="color">${icon("circle", 16)} Farbe</button><button class="btn danger" data-a="delete">${icon("trash", 16)} Ordner löschen (Inhalt bleibt erhalten)</button></div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button></div>`); $$("[data-a]", m).forEach(b => b.onclick = async () => { const a = b.dataset.a; m.remove(); if (a === "rename") { const n = prompt("Neuer Name:", f.name); if (n) await api(`/folders/${f.id}`, { method: "PATCH", body: { name: n } }); } if (a === "color") { const c = prompt("Farbe (Hex):", f.color || "#4f8ef7"); if (c) await api(`/folders/${f.id}`, { method: "PATCH", body: { color: c } }); } if (a === "delete" && confirm("Ordner löschen? Dokumente bleiben erhalten.")) await api(`/folders/${f.id}`, { method: "DELETE" }); state.route(); }); return; }
  if (kind === "trash") { const m = modal(`<h3>Papierkorb</h3><div class="stack"><button class="btn" data-a="restore">${icon("rotate", 16)} Wiederherstellen</button><button class="btn danger" data-a="forever">${icon("trash", 16)} Endgültig löschen</button></div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button></div>`); $$("[data-a]", m).forEach(b => b.onclick = async () => { m.remove(); try { await api(`/library/files/${id}`, { method: "PATCH", body: b.dataset.a === "restore" ? { restore: true } : { delete_forever: true } }); } catch (e) { toast(e.message, 4000); } state.route(); }); return; }
  const f = lib.files.find(x => x.id === id); const own = f.course_id === "__user__";
  const m = modal(`<h3>${esc(f.title)}</h3><div class="stack"><button class="btn" data-a="open">${icon("book", 16)} Öffnen</button><button class="btn" data-a="fav">${icon("star", 16)} ${f.favorite ? "Aus Favoriten entfernen" : "Zu Favoriten"}</button><button class="btn" data-a="rename">${icon("pencil", 16)} Umbenennen</button><button class="btn" data-a="move">${icon("move", 16)} In Ordner verschieben</button><button class="btn" data-a="dup">${icon("copy", 16)} Duplizieren</button>${f.kind === "pdf" && f.downloaded_at ? `<a class="btn" href="/api/files/${f.id}/content" download>${icon("download", 16)} Original herunterladen</a>` : ""}<button class="btn danger" data-a="trash">${icon("trash", 16)} In den Papierkorb</button></div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button></div>`);
  $$("[data-a]", m).forEach(b => b.onclick = async () => {
    const a = b.dataset.a; m.remove();
    if (a === "open") location.hash = `#/doc/${f.id}`;
    if (a === "fav") await api(`/files/${f.id}/favorite`, { method: "POST", body: { favorite: !f.favorite } });
    if (a === "rename") { const n = prompt("Neuer Titel:", f.title); if (n) await api(`/library/files/${f.id}`, { method: "PATCH", body: { title: n } }); }
    if (a === "move") { const mm = modal(`<h3>Verschieben nach</h3><select class="input" id="mvF"><option value="">(kein Ordner – Stammebene / Modulordner)</option>${lib.folders.map(fo => `<option value="${fo.id}">${esc((fo.module_id ? (lib.modules.find(x => x.id === fo.module_id)?.name || "") + " › " : "") + fo.name)}</option>`).join("")}</select><div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="mvOk">Verschieben</button></div>`); $("#mvOk", mm).onclick = async () => { await api(`/library/files/${f.id}`, { method: "PATCH", body: { folder_id: $("#mvF", mm).value ? +$("#mvF", mm).value : null } }); mm.remove(); state.route(); }; return; }
    if (a === "dup") await api(`/library/files/${f.id}`, { method: "PATCH", body: { duplicate: true } });
    if (a === "trash" && confirm(own ? "In den Papierkorb legen?" : "In den Papierkorb legen? Das Stud.IP-Original bleibt auf dem Server und kann wiederhergestellt werden.")) await api(`/library/files/${f.id}`, { method: "PATCH", body: { trash: true } });
    state.route();
  });
}
