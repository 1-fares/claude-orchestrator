# Goal: csv-dashboard

## Working tree
~/projects/tests/csv-dashboard

## What I want
A CSV data dashboard whose point is to surface edge cases in three areas at once:
CSV parsing, networking, and front-end/UI state handling. It is deliberately a
harder test than the expense tracker.

Backend (Python, use uv; FastAPI):
- Ingest a CSV two ways: (a) multipart file upload; (b) fetch from a user-supplied
  URL. The URL path is the networking surface: handle timeouts, non-200 responses,
  redirects, wrong/missing content-type, and oversized bodies, returning a clear
  error shape rather than crashing.
- Parse robustly and report what happened. Handle: quoted fields, embedded
  commas/newlines/quotes, a configurable delimiter, header vs headerless input,
  ragged rows (too few/too many columns), a UTF-8 BOM, an encoding fallback
  (utf-8 then latin-1), empty files, and leading/trailing whitespace. Infer a type
  per column (integer, float, ISO date, string). Produce a warnings report: which
  rows were coerced or skipped and why.
- Expose an API: dataset summary (row count, columns, inferred types); per-column
  aggregates (min/max/mean/distinct count for numeric, distinct count for text);
  a filtered + sorted + paginated row listing; and the parse warnings report.
- pytest covering the parsing edge cases above, the networking paths (against a
  local fixture HTTP server, not the public internet), the aggregates, and the
  warnings report.

Front-end (React):
- Two input modes: upload a CSV file, or enter a URL to fetch.
- Show the inferred schema, a sortable/filterable/paginated table, a summary view
  (cards or a simple bar chart for a chosen numeric column), and a distinct panel
  listing parse warnings/errors.
- Handle loading, empty, malformed-CSV, and network-error states explicitly.
  Render every cell value safely (no XSS via crafted CSV content).

## Acceptance criteria
- Backend `uv run pytest -q` passes, including explicit edge-case tests: quoted/
  embedded delimiters, ragged rows, BOM, encoding fallback, empty input, type
  inference, and URL fetch for both success and the failure modes (timeout,
  non-200, wrong content-type).
- API supports upload + URL ingest, schema/summary, per-column aggregates,
  filtered/sorted/paginated rows, and a warnings report, all covered by tests.
- The React app builds (`npm run build`) and loads in a browser; it can ingest a
  CSV by upload and by URL (against a local fixture server), show the table and
  summary, and show a friendly error for a malformed CSV and for a bad URL.
  Verified via chrome-devtools, screenshot saved under docs/.

## Scope
In scope: a new app in this working tree (backend/ and frontend/).
Out of scope: authentication, multi-user, persisting more than the current
dataset, deployment, cloud services.

## Team
Use the team as appropriate: architect (one-page API + parsing/warnings contract),
backend implementer, front-end developer, tester (edge-case + networking pass),
reviewer, integrator.

## Notes
- Stack: FastAPI + Vite/React. Python via uv; front-end via npm.
- A parsing library is allowed, but the listed edge cases and the per-row
  warnings/coercion report are required behavior; do not silently drop bad rows.
- Networking must be tested against a local fixture/mock HTTP server. Tests must
  be hermetic and not reach the public internet.
- Backend unit verify command: `uv run pytest -q`.
- Front-end developer verifies the UI in a real browser via chrome-devtools and
  saves a screenshot.
