/**
 * FRV-43 E2E stack: synthetic DB + API + vite preview on free ports.
 */
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createFrv43E2eDatabase } from './create-fixture.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(__dirname, '..');
const apiRoot = path.resolve(webRoot, '../api');
const statePath = path.join(__dirname, '.run-state.json');

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

function waitHttp(url, timeoutMs = 60000) {
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

/** Kill only the given PID tree (E2E-owned). Waits for taskkill to finish. */
function killTreeSync(pid) {
  if (!pid) return;
  if (process.platform === 'win32') {
    const r = spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], {
      encoding: 'utf8',
      windowsHide: true,
    });
    // 128 / 255: process already gone — OK
    if (r.error) throw r.error;
    const code = r.status ?? 0;
    if (code !== 0 && code !== 128 && !String(r.stderr || r.stdout || '').includes('not found')) {
      // taskkill says "not found" when PID already dead
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

async function waitUntil(predicate, label, timeoutMs = 15000, intervalMs = 200) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await predicate()) return;
    await sleep(intervalMs);
  }
  throw new Error(`E2E teardown: timeout waiting for ${label}`);
}

function assertGone(filePath, label) {
  if (fs.existsSync(filePath)) {
    throw new Error(`E2E teardown: ${label} still exists: ${filePath}`);
  }
}

function unlinkOrThrow(filePath, label) {
  if (!fs.existsSync(filePath)) return;
  try {
    fs.unlinkSync(filePath);
  } catch (e) {
    throw new Error(`E2E teardown: failed to remove ${label} (${filePath}): ${e}`);
  }
  assertGone(filePath, label);
}

export async function startE2eStack() {
  const { dbPath } = createFrv43E2eDatabase();
  const apiPort = await freePort();
  const webPort = await freePort();

  const apiDist = path.join(apiRoot, 'dist/index.js');
  const useBuiltApi = fs.existsSync(apiDist);
  const apiProc = useBuiltApi
    ? spawn(process.execPath, [apiDist], {
        cwd: apiRoot,
        env: {
          ...process.env,
          REVIEW_DB_PATH: dbPath,
          REVIEW_API_PORT: String(apiPort),
          REVIEW_API_HOST: '127.0.0.1',
        },
        stdio: 'ignore',
        windowsHide: true,
      })
    : spawn(
        process.execPath,
        [path.join(apiRoot, 'node_modules/tsx/dist/cli.mjs'), path.join(apiRoot, 'src/index.ts')],
        {
          cwd: apiRoot,
          env: {
            ...process.env,
            REVIEW_DB_PATH: dbPath,
            REVIEW_API_PORT: String(apiPort),
            REVIEW_API_HOST: '127.0.0.1',
          },
          stdio: 'ignore',
          windowsHide: true,
        },
      );

  const viteJs = path.join(webRoot, 'node_modules/vite/bin/vite.js');
  const webProc = spawn(
    process.execPath,
    [viteJs, 'preview', '--host', '127.0.0.1', '--port', String(webPort), '--strictPort'],
    {
      cwd: webRoot,
      env: {
        ...process.env,
        REVIEW_API_PORT: String(apiPort),
      },
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
    for (const p of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]) {
      try {
        fs.unlinkSync(p);
      } catch {
        /* best-effort on failed start */
      }
    }
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
  return { ...state, apiProc, webProc };
}

export function readE2eState() {
  return JSON.parse(fs.readFileSync(statePath, 'utf8'));
}

/**
 * Stop API/Web (tracked PIDs only), verify dead + ports free, then remove temp DB/state.
 * Throws if cleanup cannot be proven.
 */
export async function stopE2eStack() {
  if (!fs.existsSync(statePath)) return;
  const state = readE2eState();
  const { apiPid, webPid, apiPort, webPort, dbPath } = state;

  killTreeSync(apiPid);
  killTreeSync(webPid);

  await waitUntil(() => !isPidAlive(apiPid), `API pid ${apiPid} dead`);
  await waitUntil(() => !isPidAlive(webPid), `Web pid ${webPid} dead`);
  await waitUntil(async () => !(await isPortOpen(apiPort)), `API port ${apiPort} free`);
  await waitUntil(async () => !(await isPortOpen(webPort)), `Web port ${webPort} free`);

  unlinkOrThrow(dbPath, 'temp DB');
  unlinkOrThrow(`${dbPath}-wal`, 'temp DB WAL');
  unlinkOrThrow(`${dbPath}-shm`, 'temp DB SHM');
  unlinkOrThrow(statePath, '.run-state.json');

  assertGone(dbPath, 'temp DB');
  assertGone(`${dbPath}-wal`, 'temp DB WAL');
  assertGone(`${dbPath}-shm`, 'temp DB SHM');
  assertGone(statePath, '.run-state.json');
}

export { statePath };
