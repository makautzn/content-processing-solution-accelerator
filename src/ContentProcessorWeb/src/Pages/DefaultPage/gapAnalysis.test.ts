// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { parseGapAnalysis } from './gapAnalysis';

describe('parseGapAnalysis', () => {
  it.each([undefined, null, ''])('reports missing analysis as unavailable (%s)', (raw) => {
    expect(parseGapAnalysis(raw)).toEqual({ status: 'unavailable' });
  });

  it.each([
    '{"narrative_report":"truncated',
    'not JSON',
    'null',
    '[]',
    '{}',
    '{"narrative_report":null}',
    '{"narrative_report":"   "}',
  ])('reports invalid analysis explicitly (%s)', (raw) => {
    expect(parseGapAnalysis(raw)).toEqual({
      status: 'invalid',
      message: expect.stringContaining('Please reprocess the claim'),
    });
  });

  it.each([
    { narrative_report: 'Found 0 Gaps, 2 Discrepancies.' },
    JSON.stringify({ narrative_report: 'Found 0 Gaps, 2 Discrepancies.' }),
  ])('preserves the generated narrative', (raw) => {
    expect(parseGapAnalysis(raw)).toEqual({
      status: 'available',
      narrative: 'Found 0 Gaps, 2 Discrepancies.',
    });
  });
});
