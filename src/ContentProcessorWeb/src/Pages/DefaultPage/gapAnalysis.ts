// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

type GapAnalysisResult =
  | { status: 'available'; narrative: string }
  | { status: 'unavailable' }
  | { status: 'invalid'; message: string };

export function parseGapAnalysis(raw: unknown): GapAnalysisResult {
  if (raw === undefined || raw === null || raw === '') {
    return { status: 'unavailable' };
  }

  let report: unknown = raw;
  if (typeof raw === 'string') {
    try {
      report = JSON.parse(raw);
    } catch {
      return {
        status: 'invalid',
        message: 'Gap analysis could not be displayed because the saved report is invalid or incomplete. Please reprocess the claim.',
      };
    }
  }

  if (typeof report !== 'object' || report === null || Array.isArray(report)
      || !('narrative_report' in report)
      || typeof report.narrative_report !== 'string'
      || !report.narrative_report.trim()) {
    return {
      status: 'invalid',
      message: 'Gap analysis could not be displayed because the saved report has no narrative. Please reprocess the claim.',
    };
  }

  return { status: 'available', narrative: report.narrative_report };
}
