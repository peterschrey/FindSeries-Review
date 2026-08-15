/**
 * FRV-46 browser stack against C: gate DB (not synthetic, not production).
 * Separate from review/web/e2e (FRV-43).
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
        else setTimeout(tick, 500);
      });
      req.on('error', () => {
        if (Date.now() - start > timeoutMs) reject(new Error(`timeout ${url}`));
        else setTimeout(tick, 500);
      });
    };
    tick();
  });
}

function killTreeSync(pid) {
  if (!pid) return;
  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true });
  } else {
    try {
      process.kill(pid, 'SIGTERM');
    } catch {
      /* ignore */
    }
  }
}

export async function startFrv46Stack() {
  const dbPath = path.resolve(
    process.env.REVIEW_PERF_DB_PATH ?? 'C:/Temp/FindSeries-Review-Test/findseries-v5-phase1-gate.db',
  );
  if (dbPath.toLowerCase() === PRODUCTION) throw new Error('REFUSING productive DB');
  if (!fs.existsSync(dbPath)) throw new Error(`Gate DB missing: ${dbPath}`);

  const apiPort = await freePort();
  const webPort = await freePort();
  const apiDist = path.join(apiRoot, 'dist/index.js');
  if (!fs.existsSync(apiDist)) throw new Error('review/api/dist missing — build first');

  const apiProc = spawn(process.execPath, [apiDist], {
    cwd: apiRoot,
    env: {
      ...process.env,
      REVIEW_DB_PATH: dbPath,
      REVIEW_API_PORT: String(apiPort),
      REVIEW_API_HOST: '127.0.0.1',
      // Avoid existsSync hangs on missing E: media paths during acceptance.
      REVIEW_MEDIA_ROOTS: '',
      REVIEW_DELETE_ROOTS: '',
      // Browser acceptance is read-mostly; avoid writer locks during heavy concurrent UI fetches.
      REVIEW_DB_READONLY: '1',
    },
    stdio: 'ignore',
    windowsHide: true,
  });

  const viteJs = path.join(webRoot, 'node_modules/vite/bin/vite.js');
  const webProc = spawn(
    process.execPath,
    [viteJs, 'preview', '--host', '127.0.0.1', '--port', String(webPort), '--strictPort'],
    {
      cwd: webRoot,
      env: { ...process.env, REVIEW_API_PORT: String(apiPort) },
      stdio: 'ignore',
      windowsHide: true,
    },
  );

  try {
    await waitHttp(`http://127.0.0.1:${apiPort}/api/projects`);
    await waitHttp(`http://127.0.0.1:${webPort}/`);
    await waitHttp(`http://127.0.0.1:${webPort}/api/projects`);
  } catch (e) {
    killTreeSync(apiProc.pid);
    killTreeSync(webProc.pid);
    throw e;
  }

  const state = {
    dbPath,
    apiPort,
    webPort,
    apiPid: apiProc.pid,
    webPid: webProc.pid,
    baseURL: `http://127.0.0.1:${webPort}`,
  };
  fs.writeFileSync(statePath, JSON.stringify(state, null, 2), 'utf8');
  return state;
}

export function stopFrv46Stack() {
  if (!fs.existsSync(statePath)) return;
  const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
  killTreeSync(state.apiPid);
  killTreeSync(state.webPid);
  try {
    fs.unlinkSync(statePath);
  } catch {
    /* ignore */
  }
}

export { statePath };
