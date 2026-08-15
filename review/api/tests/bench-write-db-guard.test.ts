import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import path from 'node:path';
import {
  BENCH_WRITE_ROOT,
  assertSafeBenchDb,
  assertSafeBenchWriteDb,
} from '../scripts/bench-shared.js';

describe('FRV-40 assertSafeBenchWriteDb', () => {
  it('PASS: C:\\Temp\\FindSeries-Review-Test\\bench-write-copy.db', () => {
    const p = assertSafeBenchWriteDb('C:/Temp/FindSeries-Review-Test/bench-write-copy.db');
    assert.equal(path.resolve(p).toLowerCase(), path.resolve(p).toLowerCase());
    assert.ok(p.toLowerCase().startsWith(BENCH_WRITE_ROOT.toLowerCase()));
  });

  it('FAIL: productive DB', () => {
    assert.throws(
      () => assertSafeBenchWriteDb('C:/FindSeriesV5-Workspace/findseries-v5.db'),
      /REFUSING productive DB/,
    );
  });

  it('FAIL: other C: user path', () => {
    assert.throws(
      () => assertSafeBenchWriteDb('C:/Users/pschr/anything.db'),
      /REFUSING write DB outside/,
    );
  });

  it('FAIL: E: temp path', () => {
    assert.throws(
      () => assertSafeBenchWriteDb('E:/Temp/FindSeries-Review-Test/anything.db'),
      /REFUSING E:/,
    );
  });

  it('FAIL: other C: directory outside Temp root', () => {
    assert.throws(
      () => assertSafeBenchWriteDb('C:/Temp/other-folder/bench.db'),
      /REFUSING write DB outside/,
    );
  });

  it('FAIL: gate DB as write target', () => {
    assert.throws(
      () => assertSafeBenchWriteDb('C:/Temp/FindSeries-Review-Test/findseries-v5-phase1-gate.db'),
      /REFUSING gate/,
    );
  });

  it('read assertSafeBenchDb still allows C: gate outside write root', () => {
    const p = assertSafeBenchDb('C:/Temp/FindSeries-Review-Test/findseries-v5-phase1-gate.db');
    assert.ok(p.includes('phase1-gate'));
  });
});
