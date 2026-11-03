// Lasttest des StudiNow-Dienstes mit k6 (https://k6.io), Plan: docs/LASTTEST-PLAN-GROSS.md
//   k6 run -e BASE_URL=https://lasttest.example.de -e TOKENS=tokens.json tools/lasttest-k6.js
// Wahlweise: -e STEPS=250,500,1000,2000,3000 (Anfragen je Sekunde je Stufe)  -e STEP_MIN=5 (Minuten je Stufe)
//            -e MAXVUS=8000 (gleichzeitige Verbindungen des Lastgebers)
// Nur gegen den eigenen Testserver mit Testkonten aus tools/lasttest-aufbau.py. Bricht von selbst ab, wenn mehr als 1 %
// der Anfragen scheitern (spart Miete). Nur lesende Pfade; Schreiben (Notizen, Likes) ist nicht Teil dieses Skripts.
import http from 'k6/http';
import { check } from 'k6';
import { SharedArray } from 'k6/data';
import { Counter } from 'k6/metrics';

const tokens = new SharedArray('tokens', () => JSON.parse(open(__ENV.TOKENS || './tokens.json')));
const BASE = (__ENV.BASE_URL || '').replace(/\/$/, '');
if (!BASE) { throw new Error('BASE_URL fehlt'); }
// dieselben Lesepfade wie tools/lasttest-dienst.py
const PATHS = ['/api/account/me', '/api/entitlements', '/api/modules', '/api/files', '/api/dashboard', '/api/billing/plans'];
const steps = (__ENV.STEPS || '250,500,1000,2000,3000').split(',').map(Number);
const stepMin = Number(__ENV.STEP_MIN || 5);
const serverErrors = new Counter('server_errors_5xx');

const stages = [];
for (const rate of steps) {
  stages.push({ target: rate, duration: '30s' });          // hochfahren
  stages.push({ target: rate, duration: `${stepMin}m` });  // halten
}

export const options = {
  scenarios: {
    lesen: {
      executor: 'ramping-arrival-rate',
      startRate: 50, timeUnit: '1s',
      preAllocatedVUs: 500, maxVUs: Number(__ENV.MAXVUS || 8000),
      stages,
    },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true, delayAbortEval: '1m' }],
    http_req_duration: ['p(95)<500', 'p(99)<2000'],
    server_errors_5xx: ['count<50'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const token = tokens[Math.floor(Math.random() * tokens.length)];
  const path = PATHS[Math.floor(Math.random() * PATHS.length)];
  const res = http.get(BASE + path, { headers: { Authorization: 'Bearer ' + token }, tags: { name: path } });
  check(res, { 'Status 200': (r) => r.status === 200 });
  if (res.status >= 500) { serverErrors.add(1); }
}
