// u13-frontend-themes: app entry — theme boot, poll loop, mission strip,
// header KPIs, freshness, empty state, click-on-agent panel.

import { GraphView } from './graph.js';
import { Sidebar, fmtDuration } from './sidebar.js';
import {
  prefixInfo,
  STATE_COLOR_VAR, STATE_LABEL, STATE_BADGE,
  cssVar, withAlpha,
} from './glyphs.js';
import * as themes from './glyphs.js';
import { ChatPanel } from './chat.js';

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
  panelEmpty:   el('agent-panel-empty'),
  panelEmptyLine: el('agent-panel-empty-line'),
  panelClose:   el('agent-panel-close'),
  panelRoleName:    el('agent-panel-role-name'),
  panelStateChip:   el('agent-panel-state-chip'),
  panelLastActivity:el('agent-panel-last-activity'),
  panelMascot:  el('agent-panel-mascot'),
  themeSelect:  el('theme-select'),
  missionStrip: el('mission-strip'),
  missionGoal:  el('mission-goal'),
  missionStatus:el('mission-status'),
  missionBadges:el('mission-badges'),
};

themes.bindMascotImage(ui.emptyMascot);
themes.bindMascotImage(ui.panelMascot);

const graph = new GraphView(el('graph'), {
  onNodeClick:   (name) => openPanel(name),
  onCanvasClick: ()     => closePanel(),
});
const sidebar = new Sidebar(el('sidebar'));
const chat = new ChatPanel({ poll_ms: POLL_MS });

// ---------------------------------------------------------------- theme switcher

async function bootTheme() {
  await themes.fetchThemes();
  populateThemeSelect();
  const picked = themes.initialTheme();
  themes.applyTheme(picked, { persist: false });
  if (ui.themeSelect) ui.themeSelect.value = picked;
}

function populateThemeSelect() {
  if (!ui.themeSelect) return;
  const sel = ui.themeSelect;
  const list = themes.getRegistry();
  // Default theme first, then the rest by display_name ascending. The
  // canonical default name lives in glyphs.js so a future change updates
  // a single constant.
  const def = list.find(t => t.name === themes.DEFAULT_THEME);
  const rest = list
    .filter(t => t !== def)
    .sort((a, b) => (a.display_name || '').localeCompare(b.display_name || ''));
  const ordered = def ? [def, ...rest] : rest;
  sel.replaceChildren(...ordered.map(t => {
    const opt = document.createElement('option');
    opt.value = t.name;
    opt.textContent = t.display_name || t.name;
    if (t.summary) opt.title = t.summary;
    return opt;
  }));
  sel.addEventListener('change', () => {
    themes.applyTheme(sel.value);
  });
}

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
  setEmptyVisible(false);
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
  setEmptyVisible(false);
}

function setEmptyVisible(yes) {
  if (!ui.panelEmpty) return;
  if (yes) ui.panelEmpty.removeAttribute('hidden');
  else ui.panelEmpty.setAttribute('hidden', '');
}

function renderPanelHeader() {
  const name = state.panelRole;
  if (!name) return;
  ui.panelRoleName.textContent = name;
  const role = (state.lastSnap?.roster || []).find(r => r.name === name);
  const s = role?.state || 'idle';
  const color = cssVar(STATE_COLOR_VAR[s] || STATE_COLOR_VAR.idle);
  const badge = STATE_BADGE[s];
  // u24: append subagent fan-out to the chip when the role is delegating,
  // matching the tri-state rule in design/u24-delegating-visual.md §2.
  //   subagent_count >= 1 → "·⚙ ×N"
  //   subagent_count === 0 → bare label (truly zero, no fan-out)
  //   subagent_count missing → "·⚙" (unknown count)
  const isDelegating = role?.activity === 'delegating';
  const rawN = role?.subagent_count;
  const base = (badge ? badge + ' ' : '') + (STATE_LABEL[s] || s);
  let suffix = '';
  if (isDelegating) {
    if (Number.isFinite(rawN) && rawN >= 1) suffix = ` ·⚙ ×${Math.floor(rawN)}`;
    else if (!Number.isFinite(rawN))         suffix = ' ·⚙';
  }
  ui.panelStateChip.textContent = base + suffix;
  ui.panelStateChip.style.color = color;
  ui.panelStateChip.style.background = withAlpha(color, 0.18);
  ui.panelStateChip.dataset.state = s;
  if (isDelegating) ui.panelStateChip.dataset.activity = 'delegating';
  else delete ui.panelStateChip.dataset.activity;

  const lastTs = role?.last_msg_ts;
  if (lastTs && state.lastSnap?.now_ts) {
    const age = Math.max(0, state.lastSnap.now_ts - lastTs);
    ui.panelLastActivity.textContent = `last activity: ${relStr(age)}`;
  } else {
    ui.panelLastActivity.textContent = 'last activity: —';
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

  ui.panelFeed.replaceChildren(list);
  setEmptyVisible(false);

  if (newIds.size && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    setTimeout(() => {
      for (const row of list.querySelectorAll('[data-fresh="true"]')) {
        delete row.dataset.fresh;
      }
    }, FEED_ROW_NEW_MS + 50);
  }

  for (const m of messages) state.feedSeenIds.add(m.id);
  if (state.feedSeenIds.size > FEED_DEFAULT_LIMIT * 2) {
    state.feedSeenIds = new Set([...state.feedSeenIds].slice(-FEED_DEFAULT_LIMIT));
  }
}

function renderFeedEmpty(role) {
  ui.panelFeed.replaceChildren();
  if (ui.panelEmptyLine) {
    ui.panelEmptyLine.textContent = `No bus messages yet for ${role}.`;
  }
  setEmptyVisible(true);
}

function renderFeedError(reason) {
  setEmptyVisible(false);
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

// ---------------------------------------------------------------- mission strip

function renderMissionStrip(snap) {
  // M2: server (SCHEMA 5) now emits `unit_counts` (6 buckets + total),
  // `goal_what`, and `team_idle`. The mission strip reads those three fields
  // directly; the old client-side derivation from snap.units.list +
  // snap.units.counts stays as a graceful fallback so an older server still
  // renders something coherent (the legacy "33/47 done" line shows up there).
  const goalEl   = ui.missionGoal;
  const statusEl = ui.missionStatus;
  const badgesEl = ui.missionBadges;
  if (!goalEl || !statusEl || !badgesEl) return;

  const uc = snap?.unit_counts || null;
  const legacyCounts = snap?.units?.counts || {};
  const legacyList   = snap?.units?.list   || [];
  const total = (uc?.total != null) ? uc.total
              : (legacyList.length || Object.values(legacyCounts).reduce((a, b) => a + (b || 0), 0));
  const done        = (uc?.done        != null) ? uc.done        : (legacyCounts.done || 0);
  const inProgress  = (uc?.in_progress != null) ? uc.in_progress
                    : legacyList.filter(u => u.status === 'in-progress').length;
  const deferred    = (uc?.deferred    != null) ? uc.deferred    : (legacyCounts.deferred || 0);
  const blkRole     = (uc?.blocked_role     != null) ? uc.blocked_role     : (legacyCounts.blocked || 0);
  const blkOperator = (uc?.blocked_operator != null) ? uc.blocked_operator
                    : (snap?.roster || []).reduce((acc, r) => acc + (r.open_question_ids?.length || 0), 0);
  const blkWatchdog = (uc?.blocked_watchdog != null) ? uc.blocked_watchdog
                    : (snap?.roster || []).filter(r => r.state === 'stalled-api').length;
  const blockedAll  = blkRole + blkOperator + blkWatchdog;
  const teamIdle    = (snap?.team_idle != null)
    ? !!snap.team_idle
    : (inProgress === 0 && blkOperator === 0);

  // Goal: prefer the new `goal_what` field; fall back to the legacy nested
  // location or a synthetic placeholder.
  const goalText = snap?.goal_what
    || snap?.run?.goal_what
    || `Active swarm · ${snap?.run?.roster_count ?? 0} roles`;
  goalEl.textContent = goalText;
  goalEl.title = goalText;        // hover-to-expand for truncated values

  // Status line, priority order:
  //   1. team_idle → "Team idle — N deferred for round 3" (large, neutral)
  //   2. blocked_operator > 0 → "N open questions for you" (warm yellow)
  //   3. in_progress > 0 → "N units in flight" (neutral)
  //   4. else → "Team idle" (small)
  let statusText = '';
  let statusKind = 'idle';
  if (teamIdle && deferred > 0) {
    statusText = `Team idle — ${deferred} deferred for round 3`;
    statusKind = 'team-idle-deferred';
  } else if (blkOperator > 0) {
    statusText = `${blkOperator} open question${blkOperator > 1 ? 's' : ''} for you`;
    statusKind = 'blocked-operator';
  } else if (inProgress > 0) {
    statusText = `${inProgress} unit${inProgress > 1 ? 's' : ''} in flight`;
    statusKind = 'in-progress';
  } else {
    statusText = 'Team idle';
    statusKind = 'idle';
  }
  statusEl.textContent = statusText;
  statusEl.title = statusText;
  statusEl.dataset.kind = statusKind;

  // 4-bucket counts pill (done / in_progress / deferred / blocked). Hover
  // breakdown lives in the title attribute on each segment so the operator
  // can see the underlying split (role / operator / watchdog) without
  // mousing into a sub-menu.
  badgesEl.replaceChildren(
    mkCountSeg('done',        done,        `${done} done`),
    mkCountSeg('in-progress', inProgress,  `${inProgress} in progress`),
    mkCountSeg('deferred',    deferred,    `${deferred} deferred`),
    mkCountSeg('blocked',     blockedAll,
               `${blockedAll} blocked — role ${blkRole} · operator ${blkOperator} · watchdog ${blkWatchdog}`),
  );

  // Show the strip only when there's any data to display.
  ui.missionStrip.dataset.empty = (total === 0 && !snap?.run?.roster_count)
    ? 'true' : 'false';
}

function mkCountSeg(kind, count, hover) {
  const seg = mkEl('span', { cls: 'mission-count' });
  seg.dataset.kind = kind;
  if (count === 0) seg.dataset.empty = 'true';
  seg.title = hover;
  seg.append(
    mkEl('span', { cls: 'count-num',   text: String(count) }),
    mkEl('span', { cls: 'count-label', text: kind === 'in-progress' ? 'in flight' : kind }),
  );
  return seg;
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
    if (snap.schema_version && snap.schema_version > 5) {
      console.warn('Unknown schema_version', snap.schema_version,
                   '— attempting to render anyway.');
    }
    state.lastResponseAt = performance.now();
    state.lastSnap = snap;
    state.lastSnapAtPerf = state.lastResponseAt;
    render(snap);
    chat.applySnapshot(snap);
  } catch (err) {
    console.warn('poll failed:', err);
  }
  if (state.panelOpen) refreshFeed();
  chat.tick();
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
  renderMissionStrip(snap);

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

// reduced-motion change tracking (the GraphView reads it once on
// construction; this listener keeps the global root class in sync for
// CSS to key off, which is what master spec section 8 specifies).
const motionMql = window.matchMedia('(prefers-reduced-motion: reduce)');
function applyMotionClass(e) {
  document.documentElement.classList.toggle('reduce-motion', e.matches);
}
applyMotionClass(motionMql);
motionMql.addEventListener?.('change', applyMotionClass);

setInterval(updateFreshness, 200);

// Kick off — boot the theme registry first so the right tokens.css is
// in the cascade before the initial render. The first poll then runs
// against a themed page.
bootTheme().then(() => {
  poll();
  schedulePolling();
}).catch(err => {
  console.warn('theme boot failed; rendering with base tokens:', err);
  themes.applyTheme(themes.DEFAULT_THEME, { persist: false });
  poll();
  schedulePolling();
});
