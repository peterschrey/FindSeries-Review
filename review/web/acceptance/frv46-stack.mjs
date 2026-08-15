/**
 * FRV-46 browser stack: writable C: gate DB + API + static web with /api proxy.
 * No Vite preview (avoids proxy hang). Separate from FRV-43 synthetic e2e.
 */
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(__dirname, '..');
const apiRoot = path.resolve(webRoot, '../api');
const statePath = path.join(__dirname, '.run-state.json');
const PRODUCTION = path.resolve('C:/FindSeriesV5-Workspace/findseries-v5.db').toLowerCase();
const ALLOWED_PREFIX = path.resolve('C:/Temp/FindSeries-Review-Test').toLowerCase();

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const addr = s.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      s.close((err) => (err ? reject(err) : resolve(port)));
    });
    s.on('error', reject);
  });
}

function waitHttp(url, timeoutMs = 120000) {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      const req = http.get(url, (res) => {
        res.resume();
        if (res.statusCode && res.statusCode >= 200 && res.statusCode < 500) {
          resolve(undefined);
          return;
        }
        if (Date.now() - start > timeoutMs) reject(new Error(`timeout ${url}`));
        else setTimeout(tick, 400);
      });
      req.on('error', () => {
        if (Date.now() - start > timeoutMs) reject(new Error(`timeout ${url}`));
        else setTimeout(tick, 400);
      });
    };
    tick();
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function killTreeSync(pid) {
  if (!pid) return;
  if (process.platform === 'win32') {
    const r = spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], {
      encoding: 'utf8',
      windowsHide: true,
    });
    if (r.error) throw r.error;
    const code = r.status ?? 0;
    if (code !== 0 && code !== 128) {
      const errText = `${r.stdout || ''}${r.stderr || ''}`;
      if (!/not found|nicht gefunden|no running instance/i.test(errText)) {
        throw new Error(`taskkill pid=${pid} exit=${code}: ${errText.trim()}`);
      }
    }
  } else {
    try {
      process.kill(pid, 'SIGTERM');
    } catch (e) {
      if (e && e.code !== 'ESRCH') throw e;
    }
  }
}

function isPidAlive(pid) {
  if (!pid || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e && e.code === 'EPERM' ? true : false;
  }
}

function isPortOpen(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: '127.0.0.1', port }, () => {
      socket.destroy();
      resolve(true);
    });
    socket.on('error', () => resolve(false));
  });
}

async function waitUntil(predicate, label, timeoutMs = 20000, intervalMs = 200) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await predicate()) return;
    await sleep(intervalMs);
  }
  throw new Error(`FRV-46 teardown: timeout waiting for ${label}`);
}

function assertAllowedDb(dbPath) {
  const resolved = path.resolve(dbPath);
  const lower = resolved.toLowerCase();
  if (lower === PRODUCTION) throw new Error(`REFUSING productive DB: ${resolved}`);
  if (lower.includes('e:\\temp\\findseries-review-test\\archive')) {
    throw new Error(`REFUSING E: archive DB: ${resolved}`);
  }
  if (!lower.startsWith(ALLOWED_PREFIX)) {
    throw new Error(`FRV-46 DB must be under C:\\Temp\\FindSeries-Review-Test (got ${resolved})`);
  }
  if (!fs.existsSync(resolved)) throw new Error(`Gate DB missing: ${resolved}`);
  return resolved;
}

function contentType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === '.html') return 'text/html; charset=utf-8';
  if (ext === '.js') return 'text/javascript; charset=utf-8';
  if (ext === '.css') return 'text/css; charset=utf-8';
  if (ext === '.svg') return 'image/svg+xml';
  if (ext === '.json') return 'application/json';
  if (ext === '.map') return 'application/json';
  return 'application/octet-stream';
}

/** Static dist + /api reverse proxy to Fastify (no Vite). Buffers bodies — pipe mode drops concurrent POSTs. */
function startStaticProxy(webPort, apiPort, distDir) {
  const server = http.createServer((req, res) => {
    const url = req.url || '/';
    if (url.startsWith('/api/') || url === '/health' || url.startsWith('/health?')) {
      // Placeholder thumbs — never touch E: media roots during acceptance
      if (/^\/api\/media\/\d+\/thumb/.test(url.split('?')[0] || '')) {
        const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>';
        res.writeHead(200, {
          'content-type': 'image/svg+xml',
          'content-length': String(Buffer.byteLength(svg)),
          'cache-control': 'no-store',
        });
        res.end(svg);
        return;
      }
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('error', (err) => {
        if (!res.headersSent) {
          res.writeHead(502, { 'content-type': 'text/plain' });
          res.end(`proxy req error: ${err.message}`);
        }
      });
      req.on('end', () => {
        const body = Buffer.concat(chunks);
        const headers = {
          host: `127.0.0.1:${apiPort}`,
          connection: 'close',
          accept: req.headers.accept || '*/*',
        };
        if (req.headers['content-type']) headers['content-type'] = req.headers['content-type'];
        if (body.length) headers['content-length'] = String(body.length);

        const proxy = http.request(
          {
            hostname: '127.0.0.1',
            port: apiPort,
            path: url,
            method: req.method,
            headers,
          },
          (up) => {
            const upChunks = [];
            up.on('data', (c) => upChunks.push(c));
            up.on('end', () => {
              const buf = Buffer.concat(upChunks);
              res.writeHead(up.statusCode || 502, {
                'content-type': up.headers['content-type'] || 'application/json',
                'content-length': String(buf.length),
                'cache-control': 'no-store',
              });
              res.end(buf);
            });
            up.on('error', (err) => {
              if (!res.headersSent) {
                res.writeHead(502, { 'content-type': 'text/plain' });
                res.end(`proxy upstream error: ${err.message}`);
              }
            });
          },
        );
        proxy.on('error', (err) => {
          if (!res.headersSent) {
            res.writeHead(502, { 'content-type': 'text/plain' });
            res.end(`proxy error: ${err.message}`);
          }
        });
        if (body.length) proxy.write(body);
        proxy.end();
      });
      return;
    }

    let rel = decodeURIComponent(url.split('?')[0] || '/');
    if (rel === '/') rel = '/index.html';
    const filePath = path.normalize(path.join(distDir, rel));
    if (!filePath.startsWith(distDir)) {
      res.writeHead(403);
      res.end('forbidden');
      return;
    }
    fs.readFile(filePath, (err, data) => {
      if (err) {
        fs.readFile(path.join(distDir, 'index.html'), (err2, html) => {
          if (err2) {
            res.writeHead(404);
            res.end('not found');
            return;
          }
          res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
          res.end(html);
        });
        return;
      }
      res.writeHead(200, { 'content-type': contentType(filePath) });
      res.end(data);
    });
  });

  // Large group/gallery payloads on Real-DB
  server.requestTimeout = 0;
  server.headersTimeout = 0;
  server.timeout = 0;

  return new Promise((resolve, reject) => {
    server.listen(webPort, '127.0.0.1', () => resolve(server));
    server.on('error', reject);
  });
}

export async function startFrv46Stack() {
  const dbPath = assertAllowedDb(
    process.env.REVIEW_PERF_DB_PATH ?? 'C:/Temp/FindSeries-Review-Test/findseries-v5-phase1-gate.db',
  );
  const distDir = path.join(webRoot, 'dist');
  if (!fs.existsSync(path.join(distDir, 'index.html'))) {
    throw new Error('review/web/dist missing — build web first');
  }
  const apiDist = path.join(apiRoot, 'dist/index.js');
  if (!fs.existsSync(apiDist)) throw new Error('review/api/dist missing — build api first');

  const apiPort = await freePort();
  const webPort = await freePort();
  const apiLog = path.join(__dirname, '.api-stderr.log');

  const apiProc = spawn(process.execPath, [apiDist], {
    cwd: apiRoot,
    env: {
      ...process.env,
      REVIEW_DB_PATH: dbPath,
      REVIEW_API_PORT: String(apiPort),
      REVIEW_API_HOST: '127.0.0.1',
      // No media roots → thumbs return placeholders without touching E:
      REVIEW_MEDIA_ROOTS: '',
      REVIEW_DELETE_ROOTS: '',
      // Writable — required for range reject + undo
      REVIEW_DB_READONLY: '0',
    },
    stdio: ['ignore', 'ignore', fs.openSync(apiLog, 'w')],
    windowsHide: true,
  });

  let webServer;
  try {
    await waitHttp(`http://127.0.0.1:${apiPort}/api/projects`);
    webServer = await startStaticProxy(webPort, apiPort, distDir);
    await waitHttp(`http://127.0.0.1:${webPort}/`);
    await waitHttp(`http://127.0.0.1:${webPort}/api/projects`);
  } catch (e) {
    killTreeSync(apiProc.pid);
    if (webServer) webServer.close();
    throw e;
  }

  const state = {
    dbPath,
    apiPort,
    webPort,
    apiPid: apiProc.pid,
    webPid: null,
    webServer: true,
    baseURL: `http://127.0.0.1:${webPort}`,
    apiLog,
  };
  // Keep server handle; proxy logs go to parent stderr for diagnosis
  apiProc.stderr?.on?.('data', () => {});
  globalThis.__frv46WebServer = webServer;
  // redirect proxy console via server - already console.error
  fs.writeFileSync(statePath, JSON.stringify(state, null, 2), 'utf8');
  return state;
}

export async function stopFrv46Stack() {
  if (!fs.existsSync(statePath)) return;
  const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
  const { apiPid, apiPort, webPort } = state;

  const webServer = globalThis.__frv46WebServer;
  if (webServer) {
    await new Promise((resolve) => webServer.close(() => resolve(undefined)));
    globalThis.__frv46WebServer = undefined;
  }

  killTreeSync(apiPid);

  await waitUntil(() => !isPidAlive(apiPid), `API pid ${apiPid} dead`);
  await waitUntil(async () => !(await isPortOpen(apiPort)), `API port ${apiPort} free`);
  await waitUntil(async () => !(await isPortOpen(webPort)), `Web port ${webPort} free`);

  try {
    fs.unlinkSync(statePath);
  } catch (e) {
    throw new Error(`FRV-46 teardown: failed to remove .run-state.json: ${e}`);
  }
  if (fs.existsSync(statePath)) {
    throw new Error('FRV-46 teardown: .run-state.json still exists');
  }
  try {
    if (state.apiLog && fs.existsSync(state.apiLog)) fs.unlinkSync(state.apiLog);
  } catch {
    /* non-fatal */
  }
}

export function readFrv46State() {
  return JSON.parse(fs.readFileSync(statePath, 'utf8'));
}

export { statePath };
