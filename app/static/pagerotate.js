// Seite drehen ohne Verrutschen (P0-7): Notizobjekte stehen in Punkten der angezeigten Seite (Ursprung oben links,
// inklusive Drehung). Dreht man die Seite im Uhrzeigersinn, drehen alle Objekte als Ganzes mit, damit sie auf
// demselben Inhalt der Seite bleiben. Referenz fuer UniFlowCore/PageRotation.swift; gemeinsame Testfaelle:
// packages/shared-contracts/fixtures/rotate/cases.json.
//
// Je 90 Grad: Punkt (x, y) der Seite mit angezeigter Groesse W x H -> (H - y, x). Ein Objekt (Konva: skalieren,
// drehen, verschieben um x/y) bekommt dafuer den neuen Ursprung (H - y, x) und 90 Grad mehr Drehung; Punkte, Breite,
// Hoehe und Massstab bleiben, ebenso alle anderen Felder.

const r2 = v => Math.round(v * 100) / 100;

/** Objekte einer Seite mit angezeigter Groesse `width` x `height` um `deg` (Vielfaches von 90) im Uhrzeigersinn
 *  drehen. Gibt neue Objekte zurueck; die uebergebenen bleiben unveraendert. */
export function rotateObjects(objects, width, height, deg = 90) {
  const turns = (((Math.round(deg / 90)) % 4) + 4) % 4;
  return (objects || []).map(o => {
    if (!o || typeof o !== "object") return o;
    let x = Number.isFinite(o.x) ? o.x : 0, y = Number.isFinite(o.y) ? o.y : 0, w = width, h = height;
    for (let i = 0; i < turns; i++) { [x, y] = [h - y, x]; [w, h] = [h, w]; }
    if (!turns) return { ...o };
    const rot = (Number.isFinite(o.rotation) ? o.rotation : 0) + 90 * turns;
    return { ...o, x: r2(x), y: r2(y), rotation: ((rot % 360) + 360) % 360 };
  });
}

/** Angezeigte Groesse nach dem Drehen um `deg`. */
export function rotatedSize(width, height, deg = 90) {
  return (((Math.round(deg / 90)) % 2) + 2) % 2 ? { w: height, h: width } : { w: width, h: height };
}
