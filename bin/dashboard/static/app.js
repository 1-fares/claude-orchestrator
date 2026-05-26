// u5-frontend: app entry — poll loop, KPIs, freshness, empty state,
// and the click-on-agent panel (per ux-spec section 3).

import { GraphView } from './graph.js';
import { Sidebar, fmtDuration } from './sidebar.js';
import {
  assetForRole, prefixInfo,
  STATE_COLOR_VAR, STATE_LABEL, STATE_BADGE,
  cssVar, withAlpha,
} from './glyphs.js';

const POLL_MS         = 1500;
const POLL_HIDDEN_MS  = 10000;
const FRESH_GOOD_MS   = 3000;
const FRESH_STALE_MS  = 6000;
const FEED_DEFAULT_LIMIT = 100;
const FEED_BODY_PREVIEW_CAP = 140;
const FEED_ROW_NEW_MS = 200;

const el = id => document.getElementById(id);

const state = {
  lastResponseAt: 0,
  lastSnap: null,
  lastSnapAtPerf: 0,
  hidden: false,
  poller: null,
  panelOpen: false,
  panelRole: null,
  feedSeenIds: new Set(),
};

// ---------------------------------------------------------------- ui handles

const ui = {
  runId:        el('hdr-run-id'),
  elapsed:      el('hdr-elapsed'),
  roster:       el('hdr-roster'),
  rosterCap:    el('hdr-roster-cap'),
  freshDot:     el('hdr-fresh-dot'),
  freshText:    el('hdr-fresh-text'),
  warnPill:     el('hdr-warn-pill'),
  empty:        el('empty'),
  emptyReason:  el('empty-reason'),
  emptyTeamDir: el('empty-team-dir'),
  emptyMascot:  el('empty-mascot'),
  panel:        el('agent-panel'),
  panelHeader:  el('agent-panel-header'),
  panelFeed:    el('agent-panel-feed'),
  panelClose:   el('agent-panel-close'),
  panelRoleName:    el('agent-panel-role-name'),
  panelStateChip:   el('agent-panel-state-chip'),
  panelLastActivity:el('agent-panel-last-activity'),
  panelMascot: el('agent-panel-mascot'),
};

const graph = new GraphView(el('graph'), {
  onNodeClick:   (name) => openPanel(name),
  onCanvasClick: ()     => closePanel(),
});
const sidebar = new Sidebar(el('sidebar'));

// ---------------------------------------------------------------- panel state

ui.panelClose.addEventListener('click', () => closePanel());
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && state.panelOpen) {
    e.preventDefault();
    closePanel();
  }
});

function openPanel(name) {
  if (state.panelRole !== name) {
    state.feedSeenIds = new Set();
  }
  state.panelOpen = true;
  state.panelRole = name;
  graph.setSelected(name);
  ui.panel.setAttribute('aria-hidden', 'false');
  ui.panel.dataset.open = 'true';
  document.body.dataset.panel = 'open';
  renderPanelHeader();
  ui.panelFeed.replaceChildren(mkLoadingRow());
  refreshFeed();
}

function closePanel() {
  if (!state.panelOpen) return;
  state.panelOpen = false;
  state.panelRole = null;
  state.feedSeenIds = new Set();
  graph.setSelected(null);
  ui.panel.setAttribute('aria-hidden', 'true');
  delete ui.panel.dataset.open;
  delete document.body.dataset.panel;
  ui.panelFeed.replaceChildren();
}

function renderPanelHeader() {
  const name = state.panelRole;
  if (!name) return;
  ui.panelRoleName.textContent = name;
  const role = (state.lastSnap?.roster || []).find(r => r.name === name);
  const s = role?.state || 'idle';
  const color = cssVar(STATE_COLOR_VAR[s] || STATE_COLOR_VAR.idle);
  const badge = STATE_BADGE[s];
  ui.panelStateChip.textContent =
    (badge ? badge + ' ' : '') + (STATE_LABEL[s] || s);
  ui.panelStateChip.style.color = color;
  ui.panelStateChip.style.background = withAlpha(color, 0.18);
  ui.panelStateChip.dataset.state = s;

  // Last activity (server clock, snap-aligned).
  const lastTs = role?.last_msg_ts;
  if (lastTs && state.lastSnap?.now_ts) {
    const age = Math.max(0, state.lastSnap.now_ts - lastTs);
    ui.panelLastActivity.textContent = `last activity: ${relStr(age)}`;
  } else {
    ui.panelLastActivity.textContent = 'last activity: —';
  }
  // Panel mascot (faint behind the feed when empty); we set the src here
  // and CSS shows/hides it.
  if (ui.panelMascot) {
    const url = assetForRole(name);
    if (ui.panelMascot.dataset.src !== url) {
      ui.panelMascot.src = url;
      ui.panelMascot.dataset.src = url;
    }
  }
}

async function refreshFeed() {
  if (!state.panelOpen || !state.panelRole) return;
  const role = state.panelRole;
  try {
    const resp = await fetch(
      `/role-feed/${encodeURIComponent(role)}?limit=${FEED_DEFAULT_LIMIT}`,
      { cache: 'no-store' },
    );
    if (resp.status === 404) {
      renderFeedError(`unknown role "${role}".`);
      return;
    }
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    renderFeed(role, data.messages || []);
  } catch (err) {
    renderFeedError(String(err && err.message ? err.message : err));
  }
}

function renderFeed(role, messages) {
  if (!state.panelOpen || state.panelRole !== role) return;
  if (!messages.length) {
    renderFeedEmpty(role);
    return;
  }
  // Server returns chronologically (newest last). UX wants newest at top.
  const rows = messages.slice().reverse();

  const list = document.createElement('div');
  list.className = 'feed-rows';
  const newIds = new Set();
  const now = state.lastSnap?.now_ts || (Date.now() / 1000);

  for (const m of rows) {
    const tsAbs = parseIsoTs(m.ts);
    const age = (tsAbs != null) ? Math.max(0, now - tsAbs) : null;
    const direction = (m.direction === 'sent') ? 'out' : 'in';
    const arrow = (direction === 'out') ? '→' : '←';
    const peerWord = (direction === 'out') ? 'to' : 'from';
    const pi = prefixInfo(m.prefix || 'other');
    const isFresh = !state.feedSeenIds.has(m.id);
    if (isFresh) newIds.add(m.id);

    const row = mkRow();
    row.dataset.direction = direction;
    row.dataset.prefix = m.prefix || 'other';
    if (isFresh) row.dataset.fresh = 'true';

    const meta = mkEl('div', { cls: 'feed-meta' });
    meta.append(
      mkEl('span', { cls: 'rel-ts', text: (age != null ? relStr(age) : '') }),
      mkEl('span', { cls: 'arrow',  text: arrow }),
      mkPrefixChip(m.prefix || 'other'),
      mkEl('span', { cls: 'peer-line' }, [
        mkEl('span', { cls: 'peer-prep', text: peerWord + ' ' }),
        mkEl('span', { cls: 'peer-name', text: m.peer || '?' }),
      ]),
    );
    row.appendChild(meta);

    const preview = mkEl('div', { cls: 'feed-body' });
    let body = String(m.body_preview || '');
    if (body.length > FEED_BODY_PREVIEW_CAP) {
      body = body.slice(0, FEED_BODY_PREVIEW_CAP - 1) + '…';
    }
    preview.textContent = body;
    preview.title = String(m.body_preview || '');
    row.appendChild(preview);

    list.appendChild(row);
  }

  // Mascot (faint) shown only when feed empty; toggle visibility.
  if (ui.panelMascot) ui.panelMascot.dataset.faint = 'false';

  ui.panelFeed.replaceChildren(list);

  // Mark new rows; clear the "new" data attr after the slide-in window.
  if (newIds.size && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    setTimeout(() => {
      for (const row of list.querySelectorAll('[data-fresh="true"]')) {
        delete row.dataset.fresh;
      }
    }, FEED_ROW_NEW_MS + 50);
  }

  // Update seen set; cap to ~2x feed size.
  for (const m of messages) state.feedSeenIds.add(m.id);
  if (state.feedSeenIds.size > FEED_DEFAULT_LIMIT * 2) {
    state.feedSeenIds = new Set([...state.feedSeenIds].slice(-FEED_DEFAULT_LIMIT));
  }
}

function renderFeedEmpty(role) {
  if (ui.panelMascot) ui.panelMascot.dataset.faint = 'true';
  const empty = mkEl('div', { cls: 'feed-empty' }, [
    mkEl('div', { cls: 'feed-empty-line', text: `No bus messages yet for ${role}.` }),
  ]);
  ui.panelFeed.replaceChildren(empty);
}

function renderFeedError(reason) {
  if (ui.panelMascot) ui.panelMascot.dataset.faint = 'true';
  const card = mkEl('div', { cls: 'feed-error' }, [
    mkEl('div', { cls: 'feed-error-row' }, [
      mkEl('span', { cls: 'icon', text: '⚠' }),
      mkEl('span', { cls: 'msg',
        text: `Could not fetch feed for ${state.panelRole}. Retrying every ${(POLL_MS / 1000).toFixed(1)}s.` }),
    ]),
    mkEl('pre', { cls: 'feed-error-detail', text: reason }),
  ]);
  ui.panelFeed.replaceChildren(card);
}

// ---------------------------------------------------------------- helpers

function mkEl(tag, opts = {}, children = []) {
  const e = document.createElement(tag);
  if (opts.cls)  e.className = opts.cls;
  if (opts.text != null) e.textContent = opts.text;
  if (opts.attrs) for (const k in opts.attrs) e.setAttribute(k, opts.attrs[k]);
  for (const c of children) if (c) e.appendChild(c);
  return e;
}

function mkRow() {
  return mkEl('div', { cls: 'feed-row' });
}

function mkLoadingRow() {
  return mkEl('div', { cls: 'feed-loading', text: 'loading feed…' });
}

function mkPrefixChip(prefix) {
  const chip = mkEl('span', { cls: 'prefix-chip', text: `${prefix}:` });
  chip.dataset.prefix = prefix;
  const pi = prefixInfo(prefix);
  const c = cssVar(pi.colorVar);
  chip.style.color = c;
  chip.style.background = withAlpha(c, 0.18);
  return chip;
}

function relStr(sec) {
  if (sec == null) return '';
  if (sec < 60) return `${Math.round(sec)}s ago`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m ago`;
  return `${Math.floor(sec / 3600)}h ago`;
}

function parseIsoTs(s) {
  if (!s) return null;
  if (typeof s === 'number') return s;
  const t = Date.parse(s);
  return Number.isFinite(t) ? t / 1000 : null;
}

// ---------------------------------------------------------------- polling

async function poll() {
  try {
    const resp = await fetch('/state.json', { cache: 'no-store' });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const snap = await resp.json();
    if (snap.schema_version && snap.schema_version > 1) {
      console.warn('Unknown schema_version', snap.schema_version,
                   '— attempting to render anyway.');
    }
    state.lastResponseAt = performance.now();
    state.lastSnap = snap;
    state.lastSnapAtPerf = state.lastResponseAt;
    render(snap);
  } catch (err) {
    console.warn('poll failed:', err);
  }
  if (state.panelOpen) refreshFeed();
}

function render(snap) {
  const run = snap.run || {};
  ui.runId.textContent =
    run.run_id ? run.run_id : (snap.team_dir ? 'legacy' : '—');
  ui.elapsed.textContent = fmtDuration(run.elapsed_seconds || 0);
  ui.roster.textContent = String(run.roster_count ?? 0);
  ui.rosterCap.textContent = String(run.roster_cap ?? 12);

  const warns = snap.warnings || [];
  if (warns.length) {
    ui.warnPill.classList.add('visible');
    ui.warnPill.textContent =
      `${warns.length} warning${warns.length > 1 ? 's' : ''}`;
    ui.warnPill.title = warns.join('\n');
  } else {
    ui.warnPill.classList.remove('visible');
  }

  const empty = (run.roster_count == null || run.roster_count === 0);
  if (empty) {
    ui.empty.classList.add('visible');
    ui.emptyReason.textContent = snap.empty_reason || 'Waiting for roles to join…';
    ui.emptyTeamDir.textContent = snap.team_dir || '(not set)';
  } else {
    ui.empty.classList.remove('visible');
  }

  graph.update(snap, state.lastSnapAtPerf);
  sidebar.update(snap);

  if (state.panelOpen) renderPanelHeader();
}

function updateFreshness() {
  if (state.lastResponseAt === 0) {
    ui.freshDot.classList.remove('stale', 'lost');
    ui.freshText.textContent = 'connecting…';
    return;
  }
  const age = performance.now() - state.lastResponseAt;
  if (age < FRESH_GOOD_MS) {
    ui.freshDot.classList.remove('stale', 'lost');
  } else if (age < FRESH_STALE_MS) {
    ui.freshDot.classList.add('stale');
    ui.freshDot.classList.remove('lost');
  } else {
    ui.freshDot.classList.add('lost');
    ui.freshDot.classList.remove('stale');
  }
  ui.freshText.textContent = `updated ${(age / 1000).toFixed(1)}s ago`;
}

function schedulePolling() {
  if (state.poller) clearInterval(state.poller);
  const ms = state.hidden ? POLL_HIDDEN_MS : POLL_MS;
  state.poller = setInterval(poll, ms);
}

document.addEventListener('visibilitychange', () => {
  state.hidden = document.hidden;
  schedulePolling();
  if (!state.hidden) poll();
});

setInterval(updateFreshness, 200);

// Kick off
poll();
schedulePolling();
