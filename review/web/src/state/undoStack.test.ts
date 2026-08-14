import { describe, expect, it } from 'vitest';

type UndoEntry = { projectId: number; batchId: string };

function popUndoSafe(
  stack: UndoEntry[],
  busy: boolean,
  currentProjectId: number,
): { stack: UndoEntry[]; entry: UndoEntry | null; error?: string } {
  if (busy) return { stack, entry: null, error: 'busy' };
  const top = stack[stack.length - 1];
  if (!top) return { stack, entry: null };
  if (top.projectId !== currentProjectId) {
    return { stack, entry: null, error: 'wrong-project' };
  }
  return { stack: stack.slice(0, -1), entry: top };
}

function restoreOnError(stack: UndoEntry[], entry: UndoEntry): UndoEntry[] {
  return [...stack, entry];
}

describe('UI undo stack safety', () => {
  it('does not pop when busy', () => {
    const stack = [{ projectId: 7, batchId: 'a' }];
    const r = popUndoSafe(stack, true, 7);
    expect(r.entry).toBeNull();
    expect(r.stack).toHaveLength(1);
    expect(r.error).toBe('busy');
  });

  it('rejects cross-project undo', () => {
    const stack = [{ projectId: 7, batchId: 'a' }];
    const r = popUndoSafe(stack, false, 14);
    expect(r.entry).toBeNull();
    expect(r.error).toBe('wrong-project');
  });

  it('restores entry on API failure', () => {
    let stack = [{ projectId: 7, batchId: 'a' }, { projectId: 7, batchId: 'b' }];
    const r = popUndoSafe(stack, false, 7);
    expect(r.entry?.batchId).toBe('b');
    stack = r.stack;
    stack = restoreOnError(stack, r.entry!);
    expect(stack.map((e) => e.batchId)).toEqual(['a', 'b']);
  });

  it('project switch filters stack', () => {
    const stack = [
      { projectId: 7, batchId: 'a' },
      { projectId: 14, batchId: 'x' },
    ].filter((e) => e.projectId === 14);
    expect(stack).toEqual([{ projectId: 14, batchId: 'x' }]);
  });
});
