// =====================================================================
// PC Toolkit Dashboard - server lokal (tanpa dependensi eksternal)
// Jalankan: node server.js  ->  buka http://127.0.0.1:5599
// =====================================================================
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, exec } = require('child_process');

const PORT = parseInt(process.env.PORT || '5599', 10);
const HOST = '127.0.0.1';
const ENGINE = path.join(__dirname, '..', 'PC-Toolkit.ps1');
const LOG_DIR = path.join(__dirname, '..', 'logs');
const INDEX = path.join(__dirname, 'index.html');

// Jalankan engine PowerShell (-Task <task> -Json) dan parse hasil JSON-nya
function runEngine(task, extraArgs, stdinData) {
  extraArgs = extraArgs || [];
  return new Promise((resolve) => {
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ENGINE, '-Task', task, '-Json'].concat(extraArgs);
    const p = spawn('powershell.exe', args, { cwd: path.dirname(ENGINE), windowsHide: true });
    let out = '';
    let err = '';
    const timer = setTimeout(() => { try { p.kill(); } catch (e) {} }, 300000); // safety 5 menit
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    if (stdinData != null) p.stdin.write(stdinData);
    p.stdin.end();
    p.on('error', (e) => { clearTimeout(timer); resolve({ code: -1, out: '', err: String(e), json: null }); });
    p.on('close', (code) => {
      clearTimeout(timer);
      let json = null;
      // PowerShell bisa menyisipkan "WARNING: Waiting for service ..." di stdout
      try { json = JSON.parse(out.slice(out.indexOf('{'))); } catch (e) { /* output bukan JSON */ }
      resolve({ code: code, out: out, err: err, json: json });
    });
  });
}

function engineResult(res, r) {
  if (r.json === null) {
    const detail = String(r.out || r.err || '').slice(0, 1500);
    return sendJson(res, 500, { error: 'Gagal membaca hasil engine', detail: detail });
  }
  return sendJson(res, 200, r.json);
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => { data += c; });
    req.on('end', () => resolve(data));
  });
}

function serveIndex(res) {
  fs.readFile(INDEX, (e, buf) => {
    if (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('index.html tidak ditemukan');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(buf);
  });
}

const server = http.createServer(async (req, res) => {
  let pathname = '/';
  try { pathname = new URL(req.url, 'http://' + (req.headers.host || 'localhost')).pathname; } catch (e) {}

  try {
    // ---- halaman utama ----
    if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
      serveIndex(res);
      return;
    }

    // ---- ping ----
    if (req.method === 'GET' && pathname === '/api/ping') {
      return sendJson(res, 200, { ok: true, app: 'pc-toolkit' });
    }

    // ---- buka folder log di Explorer ----
    if (req.method === 'GET' && pathname === '/api/open-logs') {
      exec('explorer.exe "' + LOG_DIR + '"');
      return sendJson(res, 200, { ok: true });
    }

    // ---- API baca data (GET) ----
    if (req.method === 'GET' && pathname.indexOf('/api/') === 0) {
      const map = {
        '/api/junk-size': 'junk-size',
        '/api/summary': 'summary',
        '/api/battery': 'battery',
        '/api/disk': 'disk',
        '/api/cpu': 'cpu',
        '/api/startup': 'startup-list',
        '/api/power': 'power-list',
        '/api/leftover': 'leftover-scan'
      };
      const task = map[pathname];
      if (!task) return sendJson(res, 404, { error: 'Endpoint tidak ditemukan' });
      const r = await runEngine(task);
      return engineResult(res, r);
    }

    // ---- API aksi (POST) ----
    if (req.method === 'POST' && pathname.indexOf('/api/') === 0) {
      const body = await readBody(req);
      let data = {};
      try { data = JSON.parse(body || '{}'); } catch (e) {}

      if (pathname === '/api/clean-junk') {
        const r = await runEngine('junk'); // -Json: bersihkan termasuk Recycle Bin + DNS
        return engineResult(res, r);
      }
      if (pathname === '/api/clean-browser') {
        const r = await runEngine('browser');
        return engineResult(res, r);
      }
      if (pathname === '/api/delete-leftover') {
        const lines = [];
        (data.paths || []).forEach((x) => lines.push(String(x)));
        (data.regKeys || []).forEach((x) => lines.push('REG::' + String(x)));
        const stdin = lines.length ? lines.join('\n') + '\n' : '';
        const r = await runEngine('delete-leftover', [], stdin);
        return engineResult(res, r);
      }
      if (pathname === '/api/disable-startup') {
        const lines = (data.targets || []).map((x) => String(x));
        const stdin = lines.length ? lines.join('\n') + '\n' : '';
        const r = await runEngine('disable-startup', [], stdin);
        return engineResult(res, r);
      }
      if (pathname === '/api/set-power') {
        const r = await runEngine('set-power', ['-Guid', String(data.guid || '')]);
        return engineResult(res, r);
      }
      if (pathname === '/api/shutdown') {
        sendJson(res, 200, { ok: true, bye: true });
        setTimeout(() => process.exit(0), 300);
        return;
      }
      return sendJson(res, 404, { error: 'Endpoint tidak ditemukan' });
    }

    return sendJson(res, 404, { error: 'Not found' });
  } catch (e) {
    return sendJson(res, 500, { error: String((e && e.message) || e) });
  }
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.log('Dashboard sudah berjalan di http://' + HOST + ':' + PORT);
    process.exit(0);
  } else {
    console.error('Error server: ' + e.message);
    process.exit(1);
  }
});

server.listen(PORT, HOST, () => {
  const url = 'http://' + HOST + ':' + PORT;
  console.log('==============================================');
  console.log('  PC Toolkit Dashboard berjalan di: ' + url);
  console.log('  Tekan Ctrl+C untuk menghentikan.');
  console.log('==============================================');
  try { exec('start "" "' + url + '"'); } catch (e) { /* biarkan user buka manual */ }
});
