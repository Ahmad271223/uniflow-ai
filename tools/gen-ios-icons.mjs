// Erzeugt aus app/static/icons.js (Web-Icons) einen Xcode-Asset-Katalog mit denselben SVGs.
// Aufruf im Projektordner: node tools/gen-ios-icons.mjs
// Ergebnis: apps/apple/UniFlow/Assets.xcassets/Icons/uf-<name>.imageset (Vektor, Vorlage -> folgt der Textfarbe).
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "..");
const src = fs.readFileSync(path.join(root, "app/static/icons.js"), "utf8");

// Objekt-Literal "const P = { ... }" ausschneiden und auswerten (nur Zeichenketten, keine Funktionen)
const start = src.indexOf("const P = {") + "const P = ".length;
let depth = 0, end = start;
for (; end < src.length; end++) {
  if (src[end] === "{") depth++;
  else if (src[end] === "}" && --depth === 0) break;
}
const icons = new Function(`return ${src.slice(start, end + 1)}`)();

const out = path.join(root, "apps/apple/UniFlow/Assets.xcassets/Icons");
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2) + "\n");

// gleiche Attribute wie icon() in icons.js; Strichfarbe schwarz, die App faerbt per Template-Rendering ein
const svg = inner => `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>\n`;

for (const [name, inner] of Object.entries(icons)) {
  const id = `uf-${name}`;
  const dir = path.join(out, `${id}.imageset`);
  fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir, `${id}.svg`), svg(inner));
  fs.writeFileSync(path.join(dir, "Contents.json"), JSON.stringify({
    images: [{ filename: `${id}.svg`, idiom: "universal" }],
    info: { author: "xcode", version: 1 },
    properties: { "preserves-vector-representation": true, "template-rendering-intent": "template" },
  }, null, 2) + "\n");
}

// Liste fuer Swift (UFIcon.allNames), damit Tests fehlende Namen finden
fs.writeFileSync(path.join(root, "apps/apple/UniFlow/Design/UFIconNames.swift"),
  `// Automatisch erzeugt von tools/gen-ios-icons.mjs aus app/static/icons.js – nicht von Hand aendern.\n` +
  `enum UFIconNames {\n    static let all: [String] = [\n` +
  Object.keys(icons).map(n => `        "${n}",`).join("\n") + `\n    ]\n}\n`);

console.log(`${Object.keys(icons).length} Icons nach ${path.relative(root, out)} geschrieben`);
