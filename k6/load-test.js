// k6/load-test.js - Test de charge catalog-api (TP2 - etape 5)
// 3 scenarios enchaines : montee en charge (100 VUs), stress (500 VUs), pic (1500 VUs)
// Lancement : k6 run k6/load-test.js   (BASE_URL par defaut : http://localhost:30080)
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:30080';
const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };
const ORDER = JSON.stringify({ items: [{ product_id: 1, quantity: 2 }, { product_id: 2, quantity: 1 }] });

export const options = {
  scenarios: {
    ramp_up: {            // Montee progressive jusqu'a 100 utilisateurs
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 100 },
        { duration: '1m', target: 100 },
      ],
      gracefulRampDown: '10s',
    },
    stress: {             // Charge soutenue a 500 utilisateurs
      executor: 'ramping-vus',
      startTime: '2m',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 500 },
        { duration: '3m', target: 500 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
    spike: {              // Pic soudain a 1500 utilisateurs
      executor: 'ramping-vus',
      startTime: '6m30s',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 1500 },
        { duration: '40s', target: 1500 },
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  // Seuils = traduction directe des SLO
  thresholds: {
    http_req_failed: ['rate<0.005'],                          // disponibilite >= 99,5 %
    http_req_duration: ['p(95)<200'],                         // latence p95 <= 200 ms
    'http_req_duration{scenario:ramp_up}': ['p(95)<200'],
    'http_req_duration{scenario:stress}': ['p(95)<200'],
    'http_req_duration{scenario:spike}': ['p(95)<200'],
    'http_req_failed{scenario:spike}': ['rate<0.005'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const r = Math.random();
  let res;
  if (r < 0.5) {
    res = http.get(`${BASE}/products/${1 + Math.floor(Math.random() * 3)}`, { tags: { name: 'GET /products/{id}' } });
  } else if (r < 0.75) {
    res = http.post(`${BASE}/checkout`, ORDER, { ...JSON_HEADERS, tags: { name: 'POST /checkout' } });
  } else {
    res = http.get(`${BASE}/flaky`, { tags: { name: 'GET /flaky' } });
  }
  check(res, { 'statut < 500': (x) => x.status > 0 && x.status < 500 });
  sleep(0.5 + Math.random() * 0.5);
}
