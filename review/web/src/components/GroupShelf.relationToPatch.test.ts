import { describe, expect, it } from 'vitest';
import type { FocusRelation } from '@findseries/review-shared';
import { relationToPatch } from './GroupShelf';

function uploaderRel(uploader: string | null): FocusRelation {
  return {
    kind: 'uploader',
    label: uploader == null ? 'Uploader (leer)' : `Uploader: ${uploader}`,
    total: 0,
    statusCounts: { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 },
    available: true,
    filter: { projectId: 7, uploader },
    note: 'conflict',
  };
}

describe('relationToPatch uploader', () => {
  it('passes focus uploader (including null) for applyPatch AND/conflict', () => {
    expect(relationToPatch(uploaderRel('Bob'))).toEqual({ uploader: 'Bob' });
    expect(relationToPatch(uploaderRel(null))).toEqual({ uploader: null });
  });
});
