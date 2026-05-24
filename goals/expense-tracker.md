# Goal: expense-tracker

## Working tree
~/projects/tests/expense-tracker

## What I want
A small but real expense-tracker app: a Python backend plus a polished React front-end.

Backend (Python, use uv):
- SQLite storage for expenses: id, date (ISO), amount (number), category (string), note (string).
- An HTTP API (FastAPI) with: add an expense; list expenses with optional category and date-range filters; a summary report (total per category and grand total); CSV export of all expenses.
- pytest tests covering storage, the API endpoints, the report, and CSV export.

Front-end (React):
- A clean, good-looking single page: a form to add an expense, a filterable table of expenses, and a summary view (totals per category as cards or a simple bar chart).
- Calls the backend API; handles loading, empty, and error states; renders values safely.

## Acceptance criteria
- Backend `uv run pytest -q` passes.
- API supports add / list (with filters) / report / CSV export, covered by tests.
- The React app builds and loads in a browser and can add and list expenses against the running backend.

## Scope
In scope: a new app in this working tree (e.g. backend/ and frontend/).
Out of scope: authentication, multi-user, deployment, cloud services.

## Team
Use the full team as you judge appropriate: analyst, architect, backend implementer(s), a front-end developer, tester, reviewer, integrator.

## Notes
- Greenfield. Stack: FastAPI + SQLite + Vite/React. Python via uv (uv init, uv add fastapi uvicorn pytest httpx; run with uv run). Front-end via npm.
- Backend unit verify command: `uv run pytest -q`.
- Front-end developer verifies the UI in a real browser via the chrome-devtools MCP and saves a screenshot.
