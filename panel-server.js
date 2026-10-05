// =====================================================================
// PC Toolkit Panel - server provider (tanpa dependensi)
// Jalankan: node panel-server.js   ->  buka http://127.0.0.1:5700/p/<KUNCI>
// ---------------------------------------------------------------------
// Arah: agent client melakukan outbound request ke server ini.
// Server tidak pernah menghubungi client.
// =====================================================================
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = parseInt(process.env.PORT || '5700', 10);
const HOST = process.env.HOST || '0.0.0.0';
const OFFLINE_MS = parseInt(process.env.OFFLINE_MS || String(90 * 1000), 10);
const MAX_HISTORY = 40;

const DIR = __dirname;
const STORE_FILE = path.join(DIR, 'clients.json');
const PANEL_HTML = path.join(DIR, 'panel.html');

const TASKS = [
  { task: 'summary', label: 'Ringkasan sistem', group: 'Baca' },
  { task: 'battery', label: 'Kesehatan baterai', group: 'Baca' },
  { task: 'disk', label: 'SSD / HDD', group: 'Baca' },
  { task: 'cpu', label: 'Suhu & beban CPU', group: 'Baca' },
  { task: 'power-list', label: 'Daftar skema daya', group: 'Baca' },
  { task: 'startup-list', label: 'Daftar aplikasi startup', group: 'Baca' },
  { task: 'leftover-scan', label: 'Pindai sisa aplikasi', group: 'Baca' },
  { task: 'junk-size', label: 'Hitung ukuran sampah', group: 'Baca' },
  { task: 'junk', label: 'Bersihkan cache & sampah', group: 'Tindakan', risky: true },
  { task: 'browser', label: 'Bersihkan cache browser', group: 'Tindakan', risky: true },
  { task: 'disable-startup', label: 'Nonaktifkan startup terpilih', group: 'Tindakan', risky: true, needsInput: true },
  { task: 'delete-leftover', label: 'Hapus leftover terpilih', group: 'Tindakan', risky: true, needsInput: true },
  { task: 'set-power', label: 'Ganti skema daya', group: 'Tindakan', risky: true, needsGuid: true }
];
const TASK_OK = new Set(TASKS.map((t) => t.task));

// ============================== STORE ==================================
let store = { panelKey: null, enrollCode: null, clients: {}, createdAt: new Date().toISOString() };

function load() {
  if (!fs.existsSync(STORE_FILE)) return;
  try {
    const raw = JSON.parse(fs.readFileSync(STORE_FILE, 'utf8'));
    store = Object.assign(store, raw);
    if (!store.clients) store.clients = {};
  } catch (e) {
    console.error('clients.json rusak, pakai store kosong: ' + e.message);
  }
}

let saveTimer = null;
function save() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    const tmp = STORE_FILE + '.tmp';
    try {
      fs.writeFileSync(tmp, JSON.stringify(store, null, 2), 'utf8');
      fs.renameSync(tmp, STORE_FILE);
    } catch (e) {
      console.error('Gagal menulis clients.json: ' + e.message);
    }
  }, 400);
}

function nowIso() { return new Date().toISOString(); }
function newId(prefix) { return prefix + '_' + crypto.randomBytes(9).toString('hex'); }
function token() { return crypto.randomBytes(32).toString('hex'); }

function eq(a, b) {
  const x = Buffer.from(String(a || ''));
  const y = Buffer.from(String(b || ''));
  if (x.length !== y.length || x.length === 0) return false;
  return crypto.timingSafeEqual(x, y);
}

function publicClient(c) {
  const last = c.lastSeen ? new Date(c.lastSeen).getTime() : 0;
  const online = last > 0 && (Date.now() - last) < OFFLINE_MS;
  const queued = (c.queue || []).length;
  const running = (c.queue || []).filter((t) => t.state === 'running').length;
  return {
    id: c.id,
    name: c.name,
    enrolledAt: c.enrolledAt,
    lastSeen: c.lastSeen || null,
    online,
    meta: c.meta || {},
    queued,
    running,
    lastTask: c.lastTask || null,
    history: (c.history || []).slice(0, 12)
  };
}

function findByToken(t) {
  if (!t) return null;
  for (const id of Object.keys(store.clients)) {
    if (eq(store.clients[id].token, t)) return store.clients[id];
  }
  return null;
}

// ============================== HELPERS ================================
function send(res, code, obj, type) {
  const body = type === 'html' ? obj : JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': type === 'html' ? 'text/html; charset=utf-8' : 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => { if (data.length < 2e6) data += c; });
    req.on('end', () => resolve(data));
    req.on('error', () => resolve(''));
  });
}

function readCookie(req, name) {
  const raw = req.headers.cookie || '';
  const hit = raw.split(';').map((s) => s.trim()).find((s) => s.startsWith(name + '='));
  return hit ? decodeURIComponent(hit.slice(name.length + 1)) : '';
}

function hasPanelAccess(req, url) {
  if (req.headers['x-panel-key']) return eq(req.headers['x-panel-key'], store.panelKey);
  if (url.searchParams.get('k')) return eq(url.searchParams.get('k'), store.panelKey);
  return eq(readCookie(req, 'pctk'), store.panelKey);
}

// Installer yang dipanggil lewat: irm http://host/p/<kunci>/win | iex
const FILES_OK = new Set(['PC-Toolkit.ps1', 'agent.ps1', 'gui.ps1']);

function serveInstaller(res, url, hostHeader) {
  fs.readFile(path.join(DIR, 'win.ps1'), (e, buf) => {
    if (e) return send(res, 500, { error: 'win.ps1 tidak ditemukan' });
    const host = req_host(hostHeader);
    const key = decodeURIComponent(url.pathname.split('/')[2]);
    let teks = buf.toString('utf8')
      .split('http://ALAMAT-PROVIDER:5700').join(host)
      .split('KUNCI/win').join(key + '/win')
      .split("'KUNCI'").join("'" + key + "'");
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(teks);
  });
}

function req_host(hostHeader) {
  if (hostHeader && !/^0\.0\.0\.0/.test(hostHeader)) return 'http://' + hostHeader;
  return 'http://127.0.0.1:' + PORT;
}

function servePanel(res, setCookie) {
  fs.readFile(PANEL_HTML, (e, buf) => {
    if (e) return send(res, 500, { error: 'panel.html tidak ditemukan' });
    const head = { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' };
    if (setCookie) head['Set-Cookie'] = 'pctk=' + encodeURIComponent(store.panelKey) + '; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000';
    res.writeHead(200, head);
    res.end(buf);
  });
}

// ============================== SERVER =================================
const server = http.createServer(async (req, res) => {
  let url;
  try { url = new URL(req.url, 'http://localhost'); } catch (e) { return send(res, 400, { error: 'URL salah' }); }
  const p = url.pathname;
  const hostHeader = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim();

  try {
    // ---------- /p/<kunci>/win : installer client (dicek sebelum /p/<kunci>) ----------
    if (req.method === 'GET' && /^\/p\/[^/]+\/win$/.test(p)) {
      const key = decodeURIComponent(p.split('/')[2]);
      if (!eq(key, store.panelKey)) return send(res, 404, { error: 'Kunci panel salah.' });
      return serveInstaller(res, url, hostHeader);
    }

    // ---------- halaman panel: /p/<kunci> ----------
    if (req.method === 'GET' && p.startsWith('/p/')) {
      const key = decodeURIComponent(p.slice(3));
      if (!eq(key, store.panelKey)) return send(res, 404, { error: 'Kunci panel salah.' });
      return servePanel(res, true);
    }

    // ---------- /files/<nama> : file toolkit, hanya untuk-holder kunci ----------
    if (req.method === 'GET' && p.startsWith('/files/')) {
      if (!hasPanelAccess(req, url)) return send(res, 401, { error: 'Kunci dibutuhkan.' });
      const nama = path.basename(decodeURIComponent(p.slice(7)));
      if (!FILES_OK.has(nama)) return send(res, 404, { error: 'File tidak ada' });
      return fs.readFile(path.join(DIR, nama), (e, buf) => {
        if (e) return send(res, 404, { error: 'File tidak ada' });
        res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
        res.end(buf);
      });
    }

    if (req.method === 'GET' && (p === '/' || p === '/index.html')) {
      if (hasPanelAccess(req, url)) return servePanel(res, false);
      res.writeHead(401, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end('<!doctype html><meta charset="utf-8"><title>Panel</title>' +
        '<body style="font:15px/1.6 Segoe UI,system-ui;background:#12151a;color:#c8cfdb;padding:48px">' +
        '<h1 style="font-size:19px;font-weight:600">Panel PC Toolkit</h1>' +
        '<p>Buka panel lewat URL yang berisi kunci, bentuknya <code>http://HOST:PORT/p/&lt;KUNCI&gt;</code>. ' +
        'Kunci ada di file <code>clients.json</code>.</p></body>');
    }

    // ---------- API panel ----------
    if (p.startsWith('/api/')) {
      if (!hasPanelAccess(req, url)) return send(res, 401, { error: 'Akses ditolak. Buka lewat /p/<kunci>.' });
      const body = req.method === 'POST' ? await readBody(req) : '';
      let data = {};
      try { data = JSON.parse(body || '{}'); } catch (e) { return send(res, 400, { error: 'Body JSON tidak valid' }); }

      if (p === '/api/state' && req.method === 'GET') {
        return send(res, 200, {
          tasks: TASKS,
          enrollCode: store.enrollCode,
          clients: Object.keys(store.clients).map((k) => publicClient(store.clients[k]))
            .sort((a, b) => Number(b.online) - Number(a.online) || a.name.localeCompare(b.name)),
          offlineAfterSec: Math.round(OFFLINE_MS / 1000)
        });
      }

      if (p === '/api/new-code' && req.method === 'POST') {
        store.enrollCode = newId('ENROLL').toUpperCase();
        save();
        return send(res, 200, { enrollCode: store.enrollCode });
      }

      if (p === '/api/queue' && req.method === 'POST') {
        const c = store.clients[data.clientId];
        if (!c) return send(res, 404, { error: 'Client tidak ditemukan' });
        if (!TASK_OK.has(data.task)) return send(res, 400, { error: 'Task tidak diizinkan' });
        c.queue = c.queue || [];
        const item = {
          id: newId('t'),
          task: data.task,
          guid: String(data.guid || ''),
          stdin: String(data.stdin || '').slice(0, 200000),
          state: 'queued',
          queuedAt: nowIso()
        };
        c.queue.push(item);
        save();
        return send(res, 200, { queued: item });
      }

      if (p === '/api/cancel' && req.method === 'POST') {
        const c = store.clients[data.clientId];
        if (!c) return send(res, 404, { error: 'Client tidak ditemukan' });
        c.queue = (c.queue || []).filter((t) => t.id !== data.taskId || t.state === 'running');
        save();
        return send(res, 200, { ok: true });
      }

      if (p === '/api/remove' && req.method === 'POST') {
        const c = store.clients[data.clientId];
        if (!c) return send(res, 404, { error: 'Client tidak ditemukan' });
        delete store.clients[data.clientId];
        save();
        return send(res, 200, { ok: true });
      }

      if (p === '/api/rename' && req.method === 'POST') {
        const c = store.clients[data.clientId];
        if (!c) return send(res, 404, { error: 'Client tidak ditemukan' });
        const nama = String(data.name || '').trim().slice(0, 60);
        if (nama) c.name = nama;
        save();
        return send(res, 200, { ok: true, name: c.name });
      }

      return send(res, 404, { error: 'Endpoint tidak ditemukan' });
    }

    // ---------- API agent ----------
    if (p.startsWith('/agent/') && req.method === 'POST') {
      const body = await readBody(req);
      let data = {};
      try { data = JSON.parse(body || '{}'); } catch (e) { return send(res, 400, { error: 'Body JSON tidak valid' }); }
      const auth = req.headers['x-agent-token'];

      if (p === '/agent/enroll') {
        if (!store.enrollCode) return send(res, 400, { error: 'Belum ada kode enroll. Buat dulu di panel.' });
        if (!eq(data.code, store.enrollCode)) return send(res, 403, { error: 'Kode enroll salah' });
        const meta = data.meta || {};
        const id = newId('c');
        const c = {
          id,
          token: token(),
          name: String(meta.computer || id).slice(0, 60),
          enrolledAt: nowIso(),
          lastSeen: nowIso(),
          meta,
          queue: [],
          history: []
        };
        store.clients[id] = c;
        store.enrollCode = null;
        save();
        console.log('Enroll: ' + c.name + ' (' + id + ')');
        return send(res, 200, { id: c.id, token: c.token });
      }

      const c = findByToken(auth);
      if (!c) return send(res, 401, { error: 'Token tidak dikenal' });

      if (p === '/agent/heartbeat') {
        c.lastSeen = nowIso();
        if (data.meta) c.meta = data.meta;
        const out = [];
        while (c.queue && c.queue.length) {
          const t = c.queue[0];
          if (t.state === 'running') break;
          t.state = 'running';
          t.startedAt = nowIso();
          out.push({ id: t.id, task: t.task, guid: t.guid, stdin: t.stdin });
          break;
        }
        save();
        return send(res, 200, { ok: true, tasks: out, name: c.name, intervalHintSec: 20 });
      }

      if (p === '/agent/result') {
        c.lastSeen = nowIso();
        const t = (c.queue || []).find((x) => x.id === data.taskId);
        c.queue = (c.queue || []).filter((x) => x.id !== data.taskId);
        const rec = {
          task: t ? t.task : (data.task || '?'),
          ok: !!data.ok,
          at: nowIso(),
          ms: t && t.startedAt ? Date.now() - new Date(t.startedAt).getTime() : null,
          error: data.error ? String(data.error).slice(0, 500) : null,
          data: data.data == null ? null : data.data
        };
        c.history = [rec].concat(c.history || []).slice(0, MAX_HISTORY);
        c.lastTask = rec;
        save();
        return send(res, 200, { ok: true });
      }

      return send(res, 404, { error: 'Endpoint agent tidak ditemukan' });
    }

    return send(res, 404, { error: 'Not found' });
  } catch (e) {
    return send(res, 500, { error: String((e && e.message) || e) });
  }
});

load();
if (!store.panelKey) { store.panelKey = token(); save(); }
if (!store.enrollCode) { store.enrollCode = newId('ENROLL').toUpperCase(); save(); }

if (process.argv.includes('--new-code')) {
  store.enrollCode = newId('ENROLL').toUpperCase();
  save();
  console.log('Kode enroll baru: ' + store.enrollCode);
  process.exit(0);
}

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') { console.error('Port ' + PORT + ' sudah dipakai.'); process.exit(1); }
  console.error('Error server: ' + e.message);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  const n = Object.keys(store.clients).length;
  console.log('================================================');
  console.log('  PC Toolkit Panel  ->  http://' + HOST + ':' + PORT + '/p/' + store.panelKey);
  console.log('  Client terdaftar : ' + n);
  console.log('  Kode enroll      : ' + (store.enrollCode || '(tidak ada, buat dengan --new-code)'));
  console.log('================================================');
});