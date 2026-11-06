// Erststart in Web und Windows wie die Onboarding-Seiten des iPad (WelcomeView, UniversityPickerView, FirstLoginFlow,
// PlanPickerView; 05.11.2026): nach der Anmeldung mit dem StudiNow-Konto einmal je Hochschule (Einstellung
// `onboarding_done` in der Datenbank der Hochschule bzw. des Kontos) die Schritte Willkommen (mit Rufname), Hochschule
// waehlen, an der Hochschule anmelden, Tarif. Reine Funktionen ohne DOM (tests/js/onboarding.test.mjs).

export const STEPS = [
  { id: "welcome", title: "Willkommen" },
  { id: "university", title: "Hochschule" },
  { id: "login", title: "Anmeldung" },
  { id: "plan", title: "Tarif" },
];

/** Erststart zeigen? Nur einmal, nicht ohne Abo (dann zuerst die Abo-Seite), nicht in der Demo und nicht fuer
 *  bestehende Nutzer (es gibt schon Module oder eine Hochschul-Sitzung) */
export function shouldShow({ done, locked, demo, modules, session, hash } = {}) {
  if (done || locked || demo || session) return false;
  if ((Number(modules) || 0) > 0) return false;
  const h = String(hash || "").replace(/^#\/?/, "");
  return !h || h === "dashboard";
}

/** Erledigt-Markierung aus den Einstellungen ("1", true) */
export const isDone = s => s?.onboarding_done === true || s?.onboarding_done === "1" || s?.onboarding_done === 1;

/** Schritt "An der Hochschule anmelden" je Hochschule und Ort (PC: Anmeldefenster; Dienst: Zugangsdaten) */
export function loginStep(uni, hosted) {
  const hi = uni === "hildesheim";
  // Dienst (Entscheidung 06.11.2026): keine Hochschul-Passwörter auf dem Server, der Abgleich läuft auf dem Gerät
  if (hosted) return {
    title: "Hochschul-Zugang auf deinem Gerät",
    intro: "StudiNow speichert keine Hochschul-Passwörter auf dem Server. Der Abgleich läuft auf deinem iPad oder in der Windows-App; dort meldest du dich selbst an. Hier im Web lädst du deine Unterlagen selbst hoch.",
    action: "Weiter",
  };
  if (uni === "hsh") return { title: "Bei Moodle und im Campusmanagement anmelden", intro: "StudiNow holt danach deine Moodle-Kurse und -Dateien sowie Stundenplan, Leistungen und angemeldete Prüfungen aus dem Campusmanagement auf diesen PC. Du meldest dich im Anmeldefenster selbst an (SSO-Account, erst Moodle, dann das Campusmanagement im selben Fenster); StudiNow merkt sich nur die Sitzung.", action: "Anmeldefenster öffnen" };
  return hi
    ? { title: "Beim Learnweb anmelden", intro: "StudiNow holt danach deine Learnweb-Kurse und -Dateien sowie Stundenplan und Noten aus dem LSF auf diesen PC. Du meldest dich im Anmeldefenster selbst an (UNI-Account); StudiNow merkt sich nur die Sitzung.", action: "Anmeldefenster öffnen" }
    : { title: "Bei Stud.IP anmelden", intro: "StudiNow holt danach deine Kurse, Dateien und den Stundenplan auf diesen PC. Du meldest dich im Anmeldefenster selbst an (LUH-ID über das WebSSO); StudiNow merkt sich nur die Sitzung.", action: "Anmeldefenster öffnen" };
}

/** Text zum Tarif aus dem Abo-Stand (account-gate.js gateState) */
export function planInfo(gate, ent) {
  const days = Math.max(1, Number(ent?.access?.trial_days_left) || 1);
  if (gate === "trial") return { title: `Probe: noch ${days} ${days === 1 ? "Tag" : "Tage"}`, text: "In der Probe kannst du alles nutzen wie mit StudiNow Pro AI. Danach brauchst du StudiNow Plus oder Pro AI; deine Daten bleiben in jedem Fall erhalten." };
  if (gate === "active") return { title: `Dein Tarif: ${ent?.plan_name || "StudiNow"}`, text: "Alles ist eingerichtet. Deinen Tarif siehst und änderst du jederzeit auf der Abo-Seite." };
  return { title: "Alles frei auf diesem PC", text: "Ohne Konto-Pflicht ist auf diesem PC alles nutzbar. Tarife siehst du auf der Abo-Seite." };
}

/** "Schritt 2 von 4: Hochschule" */
export const stepLabel = i => `Schritt ${i + 1} von ${STEPS.length}: ${STEPS[i]?.title || ""}`;

/** Wechsel der Hochschule am PC braucht einen Neustart (jede Hochschule hat ihren eigenen Datenordner) */
export const needsRestart = (chosen, running, hosted) => !hosted && !!chosen && chosen !== running;
