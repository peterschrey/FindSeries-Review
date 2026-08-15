import { spawnSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const apiRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const testsDir = join(apiRoot, 'tests');
const files = readdirSync(testsDir)
  .filter((f) => f.endsWith('.test.ts'))
  .map((f) => join(testsDir, f).replace(/\\/g, '/'))
  .sort();

if (!files.length) {
  console.error('No tests/*.test.ts found');
  process.exit(1);
}

console.log(`Running ${files.length} test files…`);
// Sequential: better-sqlite3 + Node test-runner concurrency can crash on Windows
// CI (RemoveEnvironmentCleanupHook / Statement destructor) under Node 24+.
const r = spawnSync(
  process.execPath,
  ['--import', 'tsx', '--test', '--test-concurrency=1', ...files],
  {
    stdio: 'inherit',
    cwd: apiRoot,
    env: process.env,
    shell: false,
  },
);
process.exit(r.status ?? 1);
