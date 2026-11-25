importScripts('notify-core.js');

const CACHE = 'gc-shell-v1';
const STATE_CACHE = 'gc-state';
const STATE_URL = 'gc-state.json';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

// Network-first so new event data always wins; cache is the offline fallback.
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return;
  e.respondWith((async () => {
    try {
      const res = await fetch(e.request);
      if (res.ok) (await caches.open(CACHE)).put(e.request, res.clone());
      return res;
    } catch (err) {
      const hit = await caches.match(e.request, { ignoreSearch: true });
      if (hit) return hit;
      throw err;
    }
  })());
});

async function readState() {
  const res = await (await caches.open(STATE_CACHE)).match(STATE_URL);
  return res ? res.json() : {};
}

// Background check (Chrome/Edge, installed PWA only). The page mirrors its
// localStorage state into the Cache API because workers cannot read localStorage.
async function backgroundCheck() {
  const state = await readState();
  if (!state.notify || !state.notify.enabled) return;
  const data = await (await fetch('data/events.json', { cache: 'no-cache' })).json();
  const games = {};
  for (const g of [...(data.games || []), ...(state.customGames || [])]) games[g.id] = g.name;
  const events = [...(data.events || []), ...(state.manual || [])];
  const { due, notified } = GCNotify.collectDue(events, state, Date.now());
  for (const n of GCNotify.buildNotifications(due, (id) => games[id] || '')) {
    await self.registration.showNotification(n.title, { body: n.body, tag: n.tag, icon: 'icons/icon-192.png' });
  }
  state.notified = notified;
  await (await caches.open(STATE_CACHE)).put(STATE_URL, new Response(JSON.stringify(state)));
}

self.addEventListener('periodicsync', (e) => {
  if (e.tag === 'gc-check') e.waitUntil(backgroundCheck().catch(() => {}));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (all.length) return all[0].focus();
    return self.clients.openWindow('./');
  })());
});
