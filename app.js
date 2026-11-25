const { remainingLabel, collectDue, buildNotifications } = self.GCNotify;

const HOUR = 3600e3;
const DAY = 24 * HOUR;
const STORE_KEY = 'gc-state';
const PALETTE = ['#ff7a90', '#5fd3a6', '#ffa94d', '#6ea8fe', '#d58cff', '#4dd4e6', '#e6d04d'];
const WEEKDAYS = ['日', '月', '火', '水', '木', '金', '土'];

const DEFAULTS = {
  manual: [], customGames: [], done: {}, hiddenEv: {}, hiddenGames: {}, notified: {},
  notify: { enabled: false }, view: 'list', cats: {}, rewardOnly: false,
};
// Used until events.json loads, and for manual events when it cannot be loaded.
const FALLBACK_CATEGORIES = [
  { id: 'endgame', name: '高難度・定期', defaultOn: true },
  { id: 'event', name: 'イベント', defaultOn: true },
  { id: 'campaign', name: '配布・キャンペーン', defaultOn: true },
  { id: 'gacha', name: 'ガチャ', defaultOn: true },
  { id: 'shop', name: '販売・パス', defaultOn: false },
  { id: 'other', name: 'その他', defaultOn: false },
];

let state = loadState();
let data = { games: [], events: [], categories: FALLBACK_CATEGORIES, updatedAt: null, failed: [] };
let loadError = null;

// ---------- state ----------
function loadState() {
  try {
    return { ...structuredClone(DEFAULTS), ...JSON.parse(localStorage.getItem(STORE_KEY) || '{}') };
  } catch {
    return structuredClone(DEFAULTS);
  }
}

function save() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch { /* private mode */ }
  // Mirror for the service worker, which cannot read localStorage.
  if ('caches' in self) {
    caches.open('gc-state')
      .then((c) => c.put('gc-state.json', new Response(JSON.stringify(state))))
      .catch(() => {});
  }
}

async function mergeWorkerState() {
  try {
    const res = await (await caches.open('gc-state')).match('gc-state.json');
    if (res) Object.assign(state.notified, (await res.json()).notified || {});
  } catch { /* no cache API */ }
}

const games = () => [...data.games, ...state.customGames];
const gameOf = (id) => games().find((g) => g.id === id) || { id, name: id, color: '#8a90a2' };
const allEvents = () => [...data.events, ...state.manual.map((m) => ({ ...m, manual: true }))];
const catName = (id) => (data.categories.find((c) => c.id === id) || { name: id }).name;
const currencyOf = (ev) => gameOf(ev.game).currency || '石';

// Make every category's on/off explicit in state so the service worker sees the same filter.
function syncCategories() {
  for (const c of data.categories) if (!(c.id in state.cats)) state.cats[c.id] = !!c.defaultOn;
}

function visibleEvents(now) {
  return allEvents()
    .filter((e) => Date.parse(e.end) > now
      && !state.hiddenGames[e.game] && !state.hiddenEv[e.id]
      && state.cats[e.cat] !== false
      && (!state.rewardOnly || e.reward))
    .sort((a, b) => Date.parse(a.end) - Date.parse(b.end));
}

// Drop bookkeeping for events that no longer exist so storage does not grow forever.
function prune() {
  const now = Date.now();
  state.manual = state.manual.filter((m) => Date.parse(m.end) > now - 7 * DAY);
  const ids = new Set(allEvents().map((e) => e.id));
  for (const key of ['done', 'hiddenEv']) {
    for (const id of Object.keys(state[key])) if (!ids.has(id)) delete state[key][id];
  }
  for (const k of Object.keys(state.notified)) {
    if (!ids.has(k.slice(0, k.lastIndexOf(':')))) delete state.notified[k];
  }
  const used = new Set(state.manual.map((m) => m.game));
  state.customGames = state.customGames.filter((g) => used.has(g.id));
}

// ---------- dom helpers ----------
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style') el.style.cssText = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  el.append(...kids.flat().filter((k) => k != null && k !== false));
  return el;
}
const $ = (sel) => document.querySelector(sel);
const pad = (n) => String(n).padStart(2, '0');

function formatDate(ms) {
  const d = new Date(ms);
  return `${d.getMonth() + 1}/${d.getDate()}(${WEEKDAYS[d.getDay()]}) ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

let toastTimer;
function toast(msg) {
  const el = $('#toast');
  el.textContent = msg;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3200);
}

function googleCalendarUrl(ev) {
  const end = Date.parse(ev.end);
  const fmt = (ms) => new Date(ms).toISOString().replace(/[-:]|\.\d{3}/g, '');
  const params = new URLSearchParams({
    action: 'TEMPLATE',
    text: `【${gameOf(ev.game).name}】${ev.title} 終了`,
    dates: `${fmt(end - 30 * 60e3)}/${fmt(end)}`,
  });
  return `https://calendar.google.com/calendar/render?${params}`;
}

// ---------- rendering ----------
function render() {
  const now = Date.now();
  const events = visibleEvents(now);

  $('#updated').textContent = data.updatedAt
    ? `自動取得：${formatDate(Date.parse(data.updatedAt))} 更新${data.failed?.length ? `（取得失敗：${data.failed.map((id) => gameOf(id).name).join('、')}）` : ''}`
    : '';

  renderSummary(events, now);
  renderFilters(now);
  for (const tab of document.querySelectorAll('.tab')) {
    tab.classList.toggle('active', tab.dataset.view === state.view);
    tab.setAttribute('aria-selected', tab.dataset.view === state.view);
  }

  const main = $('#main');
  const scroller = main.querySelector('.tl-scroll');
  const scrollLeft = scroller ? scroller.scrollLeft : 0;
  main.replaceChildren();
  if (loadError) main.append(h('p', { class: 'notice' }, `自動取得データを読み込めませんでした（${loadError}）。手動で追加したイベントのみ表示しています。`));
  main.append(state.view === 'timeline' ? renderTimeline(events, now) : renderList(events, now));
  const next = main.querySelector('.tl-scroll');
  if (next) next.scrollLeft = scrollLeft;
}

function renderSummary(events, now) {
  const active = events.filter((e) => !state.done[e.id] && Date.parse(e.start) <= now);
  const within = (hours) => active.filter((e) => Date.parse(e.end) - now <= hours * HOUR).length;
  const tile = (n, label, cls) => h('div', { class: `stat ${n ? cls : ''}` }, h('b', null, String(n)), h('span', null, label));
  $('#summary').replaceChildren(
    tile(within(24), '24時間以内に終了', 'hot'),
    tile(within(72), '3日以内に終了', 'warm'),
    tile(active.length, '開催中（未完了）', ''),
  );
}

function renderFilters(now) {
  const counts = {};
  for (const e of allEvents()) {
    if (Date.parse(e.end) > now && !state.hiddenEv[e.id]) counts[e.game] = (counts[e.game] || 0) + 1;
  }
  const chips = games().map((g) => h('button', {
    class: `chip ${state.hiddenGames[g.id] ? 'off' : ''}`,
    style: `--c:${g.color}`,
    'aria-pressed': String(!state.hiddenGames[g.id]),
    onclick: () => {
      if (state.hiddenGames[g.id]) delete state.hiddenGames[g.id]; else state.hiddenGames[g.id] = 1;
      save(); render();
    },
  }, h('i', { class: 'dot' }), g.name, h('small', null, String(counts[g.id] || 0))));
  $('#filters').replaceChildren(...chips);

  const catCounts = {};
  for (const e of allEvents()) {
    if (Date.parse(e.end) > now && !state.hiddenEv[e.id] && !state.hiddenGames[e.game]) catCounts[e.cat] = (catCounts[e.cat] || 0) + 1;
  }
  const catChips = data.categories.map((c) => h('button', {
    class: `chip plain ${state.cats[c.id] === false ? 'off' : ''}`,
    'aria-pressed': String(state.cats[c.id] !== false),
    onclick: () => { state.cats[c.id] = state.cats[c.id] === false; save(); render(); },
  }, c.name, h('small', null, String(catCounts[c.id] || 0))));
  catChips.push(h('button', {
    class: `chip reward ${state.rewardOnly ? '' : 'off'}`,
    'aria-pressed': String(state.rewardOnly),
    title: 'ガチャ用の石（原石・オーブ・魔法石など）がもらえるものだけ表示',
    onclick: () => { state.rewardOnly = !state.rewardOnly; save(); render(); },
  }, '💎 石がもらえるものだけ'));
  $('#cat-filters').replaceChildren(...catChips);
}

function renderList(events, now) {
  const groups = [
    { key: 'hot', label: '24時間以内に終了', items: [] },
    { key: 'warm', label: '3日以内に終了', items: [] },
    { key: 'week', label: '7日以内に終了', items: [] },
    { key: 'later', label: 'それ以降', items: [] },
    { key: 'upcoming', label: '開催前', items: [] },
  ];
  const done = [];
  for (const e of events) {
    const left = Date.parse(e.end) - now;
    if (state.done[e.id]) done.push(e);
    else if (Date.parse(e.start) > now) groups[4].items.push(e);
    else if (left <= DAY) groups[0].items.push(e);
    else if (left <= 3 * DAY) groups[1].items.push(e);
    else if (left <= 7 * DAY) groups[2].items.push(e);
    else groups[3].items.push(e);
  }
  const wrap = h('div', { class: 'list' });
  for (const g of groups) {
    if (!g.items.length) continue;
    wrap.append(h('section', { class: `group ${g.key}` },
      h('h2', null, g.label, h('small', null, `${g.items.length}件`)),
      h('div', { class: 'cards' }, g.items.map((e) => card(e, now)))));
  }
  if (done.length) {
    wrap.append(h('details', { class: 'group done' },
      h('summary', null, `完了済み（${done.length}件）`),
      h('div', { class: 'cards' }, done.map((e) => card(e, now)))));
  }
  if (!wrap.children.length) {
    wrap.append(h('p', { class: 'empty' }, '表示できるイベントがありません。「＋ 追加」から登録するか、フィルターを確認してください。'));
  }
  return wrap;
}

function card(ev, now) {
  const game = gameOf(ev.game);
  const start = Date.parse(ev.start);
  const end = Date.parse(ev.end);
  const upcoming = start > now;
  const isDone = !!state.done[ev.id];
  const img = /^https:\/\//.test(ev.image || '')
    ? h('img', { class: 'thumb', src: ev.image, alt: '', loading: 'lazy', referrerpolicy: 'no-referrer', onerror: (e) => e.target.remove() })
    : null;
  return h('article', { class: `card ${isDone ? 'is-done' : ''}`, style: `--c:${game.color}` },
    img,
    h('div', { class: 'card-body' },
      h('div', { class: 'meta' },
        h('span', { class: 'game' }, game.name),
        h('span', { class: `badge cat-${ev.cat}` }, catName(ev.cat)),
        ev.reward && h('span', { class: 'badge gem', title: `${currencyOf(ev)}がもらえる` }, `💎 ${currencyOf(ev)}`),
        ev.manual && h('span', { class: 'badge' }, '手動')),
      h('h3', null, /^https:\/\//.test(ev.url || '')
        ? h('a', { href: ev.url, target: '_blank', rel: 'noopener' }, ev.title)
        : ev.title),
      h('div', { class: 'when' },
        h('b', { class: 'left' }, upcoming ? `開始まで${remainingLabel(start - now).replace('あと', '')}` : remainingLabel(end - now)),
        h('span', null, upcoming ? `${formatDate(start)} 〜 ${formatDate(end)}` : `${formatDate(end)} まで`))),
    h('div', { class: 'card-actions' },
      h('button', {
        class: `btn small ${isDone ? '' : 'primary'}`,
        onclick: () => {
          if (isDone) delete state.done[ev.id]; else state.done[ev.id] = 1;
          save(); render();
        },
      }, isDone ? '未完了に戻す' : '完了'),
      h('a', { class: 'btn small', href: googleCalendarUrl(ev), target: '_blank', rel: 'noopener' }, 'カレンダー'),
      h('button', {
        class: 'btn small ghost',
        onclick: () => {
          if (ev.manual) {
            state.manual = state.manual.filter((m) => m.id !== ev.id);
            prune();
            toast('削除しました');
          } else {
            state.hiddenEv[ev.id] = 1;
            toast('非表示にしました（設定から戻せます）');
          }
          save(); render();
        },
      }, ev.manual ? '削除' : '非表示')));
}

function renderTimeline(events, now) {
  const PX = 34;
  const DAYS = 42;
  const t0 = new Date(now); t0.setHours(0, 0, 0, 0);
  const startMs = t0.getTime() - DAY;
  const endMs = startMs + DAYS * DAY;
  const x = (ms) => ((Math.min(Math.max(ms, startMs), endMs) - startMs) / DAY) * PX;

  const head = h('div', { class: 'tl-head' });
  for (let i = 0; i < DAYS; i++) {
    const d = new Date(startMs + i * DAY);
    const cls = ['tl-day', d.getDay() === 0 ? 'sun' : d.getDay() === 6 ? 'sat' : '', i === 1 ? 'today' : ''].join(' ');
    head.append(h('div', { class: cls, style: `width:${PX}px` },
      h('small', null, d.getDate() === 1 || i === 0 ? `${d.getMonth() + 1}月` : ''),
      h('b', null, String(d.getDate())),
      h('span', null, WEEKDAYS[d.getDay()])));
  }

  const tl = h('div', { class: 'tl', style: `width:${DAYS * PX}px;--px:${PX}px` }, head);
  const shown = events.filter((e) => !state.done[e.id] && Date.parse(e.start) < endMs);
  for (const g of games()) {
    const rows = shown.filter((e) => e.game === g.id);
    if (!rows.length) continue;
    tl.append(h('div', { class: 'tl-game', style: `--c:${g.color}` }, h('span', null, g.name)));
    for (const ev of rows) {
      const s = Date.parse(ev.start);
      const e = Date.parse(ev.end);
      const left = x(s);
      const width = Math.max(x(e) - left, 6);
      const cls = ['tl-bar', ev.cat === 'gacha' ? 'gacha' : '', ev.reward ? 'gem' : '', s < startMs ? 'cut-l' : '', e > endMs ? 'cut-r' : ''].join(' ');
      tl.append(h('div', { class: 'tl-row' },
        h('div', {
          class: cls,
          style: `left:${left}px;width:${width}px;--c:${g.color}`,
          title: `${ev.title}\n${formatDate(s)} 〜 ${formatDate(e)}（${s > now ? '開催前' : remainingLabel(e - now)}）`,
        }, h('span', null, ev.reward ? `💎 ${ev.title}` : ev.title))));
    }
  }
  tl.append(h('div', { class: 'tl-now', style: `left:${x(now)}px` }));
  if (!shown.length) return h('p', { class: 'empty' }, '表示できるイベントがありません。');
  return h('div', { class: 'tl-scroll' }, tl);
}

// ---------- notifications ----------
async function showNotification(n) {
  const opts = { body: n.body, tag: n.tag, icon: 'icons/icon-192.png' };
  try {
    const reg = await navigator.serviceWorker?.getRegistration();
    if (reg) return await reg.showNotification(n.title, opts);
  } catch { /* fall through */ }
  new Notification(n.title, opts);
}

async function checkNotifications() {
  if (!state.notify.enabled || !('Notification' in self) || Notification.permission !== 'granted') return;
  const { due, notified } = collectDue(allEvents(), state, Date.now());
  state.notified = notified;
  save();
  for (const n of buildNotifications(due, (id) => gameOf(id).name)) await showNotification(n);
}

async function registerBackgroundCheck() {
  try {
    const reg = await navigator.serviceWorker.ready;
    const perm = await navigator.permissions.query({ name: 'periodic-background-sync' });
    if (perm.state === 'granted') await reg.periodicSync.register('gc-check', { minInterval: 6 * HOUR });
  } catch { /* unsupported browser: reminders fire while the app is open */ }
}

function renderNotifyControls() {
  const supported = 'Notification' in self;
  const btn = $('#btn-notify');
  btn.disabled = !supported;
  btn.textContent = state.notify.enabled ? '通知をオフにする' : '通知をオンにする';
  $('#notify-status').textContent = !supported ? 'このブラウザは通知に対応していません。'
    : Notification.permission === 'denied' ? 'ブラウザ側で通知がブロックされています。サイトの設定から許可してください。'
    : state.notify.enabled ? '通知はオンです。アプリを閉じている間の通知は、Chrome/Edgeでインストールした場合のみ届きます。'
    : '';
}

// ---------- export / import ----------
// Notification settings stay on each device: permission is granted per browser.
function exportState() {
  const { notify, notified, ...portable } = state;
  const payload = { app: 'gaming-calendar', version: 1, exportedAt: new Date().toISOString(), state: portable };
  const url = URL.createObjectURL(new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' }));
  const d = new Date();
  const a = h('a', { href: url, download: `gaming-calendar-${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}.json` });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// Merges an exported file into this device's state. Everything is validated
// field by field because the file may be hand-edited or come from elsewhere.
function importState(payload) {
  const src = payload && payload.app === 'gaming-calendar' && payload.state;
  if (!src || typeof src !== 'object') throw new Error('ゲーミングカレンダーの書き出しファイルではありません。');
  const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
  const str = (v, max) => (typeof v === 'string' && v.length > 0 && v.length <= max ? v : null);
  const keysOf = (v) => (isObj(v) ? Object.keys(v).filter((k) => v[k] && k.length <= 100) : []);
  const count = { manual: 0, done: 0, hidden: 0 };

  for (const g of Array.isArray(src.customGames) ? src.customGames : []) {
    if (!isObj(g) || !str(g.id, 40) || !str(g.name, 60) || !/^#[0-9a-f]{6}$/i.test(g.color || '')) continue;
    if (!state.customGames.some((x) => x.id === g.id)) state.customGames.push({ id: g.id, name: g.name, color: g.color });
  }
  const knownGames = new Set(games().map((g) => g.id));
  for (const m of Array.isArray(src.manual) ? src.manual : []) {
    if (!isObj(m) || !str(m.id, 40) || !str(m.title, 200) || !knownGames.has(m.game)) continue;
    const start = Date.parse(m.start);
    const end = Date.parse(m.end);
    if (Number.isNaN(start) || Number.isNaN(end) || end <= start) continue;
    if (state.manual.some((x) => x.id === m.id)) continue;
    state.manual.push({
      id: m.id, game: m.game, title: m.title, cat: str(m.cat, 20) || 'event', reward: !!m.reward,
      start: new Date(start).toISOString(), end: new Date(end).toISOString(),
    });
    count.manual++;
  }
  for (const id of keysOf(src.done)) { if (!state.done[id]) count.done++; state.done[id] = 1; }
  for (const id of keysOf(src.hiddenEv)) { if (!state.hiddenEv[id]) count.hidden++; state.hiddenEv[id] = 1; }

  // Filters are a preference rather than a record, so the imported device's choice wins.
  if (isObj(src.hiddenGames)) state.hiddenGames = Object.fromEntries(keysOf(src.hiddenGames).map((k) => [k, 1]));
  if (isObj(src.cats)) {
    for (const [k, v] of Object.entries(src.cats)) if (k.length <= 20 && typeof v === 'boolean') state.cats[k] = v;
  }
  if (typeof src.rewardOnly === 'boolean') state.rewardOnly = src.rewardOnly;
  if (src.view === 'list' || src.view === 'timeline') state.view = src.view;
  return count;
}

// ---------- wiring ----------
function setupUi() {
  for (const tab of document.querySelectorAll('.tab')) {
    tab.addEventListener('click', () => { state.view = tab.dataset.view; save(); render(); });
  }
  for (const btn of document.querySelectorAll('[data-close]')) {
    btn.addEventListener('click', () => btn.closest('dialog').close());
  }

  $('#btn-add').addEventListener('click', () => {
    $('#game-list').replaceChildren(...games().map((g) => h('option', { value: g.name })));
    $('#form-add').reset();
    $('#form-add').cat.replaceChildren(...data.categories.map((c) => h('option', { value: c.id }, c.name)));
    $('#form-add').cat.value = 'event';
    $('#add-error').hidden = true;
    $('#dlg-add').showModal();
  });

  $('#form-add').addEventListener('submit', (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const name = String(f.get('game')).trim();
    const title = String(f.get('title')).trim();
    const end = new Date(f.get('end'));
    const start = f.get('start') ? new Date(f.get('start')) : new Date();
    const err = !name || !title ? 'ゲーム名とイベント名を入力してください。'
      : Number.isNaN(end.getTime()) ? '終了日時を入力してください。'
      : end <= start ? '終了は開始より後の日時にしてください。'
      : end.getTime() <= Date.now() ? '終了日時が過去になっています。' : '';
    if (err) {
      $('#add-error').textContent = err;
      $('#add-error').hidden = false;
      return;
    }
    let game = games().find((g) => g.name === name);
    if (!game) {
      game = { id: `c-${Date.now().toString(36)}`, name, color: PALETTE[state.customGames.length % PALETTE.length] };
      state.customGames.push(game);
    }
    state.manual.push({
      id: `m-${Date.now().toString(36)}`, game: game.id, title, cat: f.get('cat'), reward: f.get('reward') === 'on',
      start: start.toISOString(), end: end.toISOString(),
    });
    delete state.hiddenGames[game.id];
    state.cats[f.get('cat')] = true; // never hide what the user just added
    save(); render();
    $('#dlg-add').close();
    toast('追加しました');
  });

  $('#btn-settings').addEventListener('click', () => {
    $('#ics-url').value = new URL('calendar.ics', location.href).href;
    renderNotifyControls();
    $('#dlg-settings').showModal();
  });

  $('#btn-notify').addEventListener('click', async () => {
    if (state.notify.enabled) {
      state.notify.enabled = false;
    } else if (await Notification.requestPermission() === 'granted') {
      state.notify.enabled = true;
      registerBackgroundCheck();
    }
    save();
    renderNotifyControls();
    checkNotifications();
  });

  $('#btn-copy').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText($('#ics-url').value);
      toast('URLをコピーしました');
    } catch {
      $('#ics-url').select();
    }
  });

  $('#btn-export').addEventListener('click', () => { exportState(); toast('書き出しました'); });
  $('#btn-import').addEventListener('click', () => $('#file-import').click());
  $('#file-import').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    e.target.value = ''; // allow picking the same file again
    if (!file) return;
    try {
      if (file.size > 2e6) throw new Error('ファイルが大きすぎます。');
      let payload;
      try { payload = JSON.parse(await file.text()); } catch { throw new Error('ファイルを読み取れませんでした。'); }
      const n = importState(payload);
      prune();
      save(); render();
      toast(`読み込みました（手動イベント${n.manual}件・完了${n.done}件・非表示${n.hidden}件を追加）`);
    } catch (err) {
      toast(err.message);
    }
  });

  $('#btn-reset-hidden').addEventListener('click', () => { state.hiddenEv = {}; save(); render(); toast('非表示を解除しました'); });
  $('#btn-reset-done').addEventListener('click', () => { state.done = {}; save(); render(); toast('完了チェックを外しました'); });
}

async function loadData() {
  try {
    const res = await fetch('data/events.json', { cache: 'no-cache' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const json = await res.json();
    data = {
      games: json.games || [], events: json.events || [],
      categories: json.categories?.length ? json.categories : FALLBACK_CATEGORIES,
      updatedAt: json.updatedAt, failed: json.failed || [],
    };
    loadError = null;
    syncCategories();
    prune();
    save();
  } catch (err) {
    loadError = err.message;
  }
}

async function init() {
  syncCategories();
  setupUi();
  render();
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
  await mergeWorkerState();
  await loadData();
  render();
  checkNotifications();
  setInterval(render, 60e3);
  setInterval(checkNotifications, 10 * 60e3);
  // Pick up fresh data when the app is brought back to the foreground.
  document.addEventListener('visibilitychange', async () => {
    if (document.visibilityState !== 'visible') return;
    await loadData();
    render();
    checkNotifications();
  });
}

init();
