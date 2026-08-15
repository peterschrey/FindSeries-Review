import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(__dirname, '..');
const distIndex = path.join(webRoot, 'dist/index.html');
const apiDist = path.resolve(webRoot, '../api/dist/index.js');

if (process.env.E2E_SKIP_REBUILD === '1' && fs.existsSync(distIndex) && fs.existsSync(apiDist)) {
  console.log('E2E_SKIP_REBUILD=1 — using existing dist');
  process.exit(0);
}

console.log('Building review/api...');
execFileSync('npm', ['run', 'build'], {
  cwd: path.resolve(webRoot, '../api'),
  stdio: 'inherit',
  shell: true,
});
console.log('Building review/web...');
execFileSync('npm', ['run', 'build'], { cwd: webRoot, stdio: 'inherit', shell: true });
