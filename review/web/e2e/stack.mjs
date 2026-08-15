/**
 * FRV-43 E2E stack: synthetic DB + API + vite preview on free ports.
 */
import { spawn } from 'node:child_process';
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

function killTree(pid) {
  if (!pid) return;
  try {
    if (process.platform === 'win32') {
      spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
    } else {
      process.kill(pid, 'SIGTERM');
    }
  } catch {
    /* ignore */
  }
}

export async function startE2eStack() {
  const { dbPath, cleanup: cleanupDb } = createFrv43E2eDatabase();
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
    killTree(apiProc.pid);
    killTree(webProc.pid);
    cleanupDb();
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
  return { ...state, cleanupDb, apiProc, webProc };
}

export function readE2eState() {
  return JSON.parse(fs.readFileSync(statePath, 'utf8'));
}

export function stopE2eStack() {
  if (!fs.existsSync(statePath)) return;
  const state = readE2eState();
  killTree(state.apiPid);
  killTree(state.webPid);
  for (const p of [state.dbPath, `${state.dbPath}-wal`, `${state.dbPath}-shm`]) {
    try {
      fs.unlinkSync(p);
    } catch {
      /* ignore */
    }
  }
  try {
    fs.unlinkSync(statePath);
  } catch {
    /* ignore */
  }
}

export { statePath };
