// App entry — poll loop, header KPIs, tooltip, empty state.
import { GraphView } from './graph.js';
import { Sidebar, fmtDuration } from './sidebar.js';
import { glyphForRole, STATE_COLOR_VAR, cssVar } from './glyphs.js';

const POLL_INTERVAL_MS         = 1500;
const POLL_INTERVAL_HIDDEN_MS  = 10000;
const FRESH_GOOD_MS = 3000;
const FRESH_STALE_MS = 6000;
const FRESH_LOST_MS = 15000;

const el = id => document.getElementById(id);

const state = {
  lastResponseAt: 0,
  lastSnapshot: null,
  lastSnapshotRecvAt: 0,
  poller: null,
  hidden: false,
};

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
  tooltip:      el('tooltip'),
};

const graph = new GraphView(el('graph'), showNodeTooltip, hideTooltip);
const sidebar = new Sidebar(el('sidebar'));

function showNodeTooltip(node) {
  if (!node) return;
  const counts = node.counts || {};
  const lines = [];
  lines.push(`<div class="tt-name">${escapeHtml(node.id)}</div>`);
  lines.push(`<div class="tt-row"><span class="key">state</span><span class="val">${node.state}</span></div>`);
  if (node.state_source) {
    lines.push(`<div class="tt-row"><span class="key">source</span><span class="val">${node.state_source}</span></div>`);
  }
  if (node.state_age_sec != null) {
    lines.push(`<div class="tt-row"><span class="key">age</span><span class="val">${node.state_age_sec.toFixed(1)}s</span></div>`);
  }
  lines.push(`<div class="tt-sep"></div>`);
  lines.push(`<div class="tt-row"><span class="key">sent 1m / total</span><span class="val">${counts.sent_1m ?? 0} / ${counts.sent_total ?? 0}</span></div>`);
  lines.push(`<div class="tt-row"><span class="key">recv 1m / total</span><span class="val">${counts.recv_1m ?? 0} / ${counts.recv_total ?? 0}</span></div>`);
  if (node.health) {
    lines.push(`<div class="tt-sep"></div>`);
    lines.push(`<div class="tt-row"><span class="key">health</span><span class="val">${node.health.state || 'n/a'}</span></div>`);
    if (node.health.retries != null) {
      lines.push(`<div class="tt-row"><span class="key">retries</span><span class="val">${node.health.retries}</span></div>`);
    }
  }
  if (node.open_question_ids && node.open_question_ids.length) {
    lines.push(`<div class="tt-row"><span class="key">open Qs</span><span class="val">${node.open_question_ids.length}</span></div>`);
  }
  if (node.last_msg_prefix && node.last_msg_ts) {
    lines.push(`<div class="tt-msg">last: ${node.last_msg_prefix}: ${ageStr(node.last_msg_ts)}</div>`);
  }
  ui.tooltip.innerHTML = lines.join('');
  ui.tooltip.classList.add('visible');
  positionTooltip();
  document.addEventListener('mousemove', positionTooltip);
}

function positionTooltip(e) {
  if (!ui.tooltip.classList.contains('visible')) return;
  const x = (e ? e.clientX : window.innerWidth / 2);
  const y = (e ? e.clientY : window.innerHeight / 2);
  const w = ui.tooltip.offsetWidth, h = ui.tooltip.offsetHeight;
  let left = x + 18, top = y + 18;
  if (left + w > window.innerWidth - 8)  left = x - w - 18;
  if (top  + h > window.innerHeight - 8) top  = y - h - 18;
  ui.tooltip.style.left = left + 'px';
  ui.tooltip.style.top  = top + 'px';
}

function hideTooltip() {
  setTimeout(() => {
    ui.tooltip.classList.remove('visible');
    document.removeEventListener('mousemove', positionTooltip);
  }, 200);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  })[c]);
}

function ageStr(ts) {
  if (!ts) return '';
  const now = state.lastSnapshot ? state.lastSnapshot.now_ts : Date.now() / 1000;
  const dt = Math.max(0, now - ts);
  if (dt < 60) return `${dt.toFixed(1)}s ago`;
  if (dt < 3600) return `${Math.floor(dt/60)}m ago`;
  return `${Math.floor(dt/3600)}h ago`;
}

async function poll() {
  try {
    const resp = await fetch('/state.json', { cache: 'no-store' });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const snap = await resp.json();
    if (snap.schema_version && snap.schema_version > 1) {
      console.warn('Unknown schema_version', snap.schema_version, '— attempting to render anyway.');
    }
    state.lastResponseAt = performance.now();
    state.lastSnapshot = snap;
    state.lastSnapshotRecvAt = state.lastResponseAt;
    render(snap);
  } catch (err) {
    // Leave state.lastSnapshot in place; freshness dot will go red.
    console.warn('poll failed:', err);
  }
}

function render(snap) {
  // Header
  const run = snap.run || {};
  ui.runId.textContent = run.run_id ? run.run_id : (snap.team_dir ? 'legacy' : '—');
  ui.elapsed.textContent = fmtDuration(run.elapsed_seconds || 0);
  ui.roster.textContent = String(run.roster_count ?? 0);
  ui.rosterCap.textContent = String(run.roster_cap ?? 12);
  if (snap.warnings && snap.warnings.length) {
    ui.warnPill.classList.add('visible');
    ui.warnPill.textContent = `${snap.warnings.length} warning${snap.warnings.length>1?'s':''}`;
    ui.warnPill.title = snap.warnings.join('\n');
  } else {
    ui.warnPill.classList.remove('visible');
  }

  // Empty state
  const empty = (run.roster_count == null || run.roster_count === 0);
  if (empty) {
    ui.empty.classList.add('visible');
    const reason = (snap.warnings && snap.warnings[0]) || 'no roster available';
    ui.emptyReason.textContent = reason;
    ui.emptyTeamDir.textContent = snap.team_dir || '(not set)';
  } else {
    ui.empty.classList.remove('visible');
  }

  // Graph + sidebar
  graph.update(snap, state.lastSnapshotRecvAt);
  sidebar.update(snap);
}

function updateFreshness() {
  if (state.lastResponseAt === 0) {
    ui.freshDot.classList.remove('stale','lost');
    ui.freshText.textContent = 'connecting…';
    return;
  }
  const age = performance.now() - state.lastResponseAt;
  if (age < FRESH_GOOD_MS) {
    ui.freshDot.classList.remove('stale','lost');
  } else if (age < FRESH_STALE_MS) {
    ui.freshDot.classList.add('stale');
    ui.freshDot.classList.remove('lost');
  } else {
    ui.freshDot.classList.add('lost');
    ui.freshDot.classList.remove('stale');
  }
  ui.freshText.textContent = `updated ${(age/1000).toFixed(1)}s ago`;
}

function schedulePolling() {
  if (state.poller) clearInterval(state.poller);
  const ms = state.hidden ? POLL_INTERVAL_HIDDEN_MS : POLL_INTERVAL_MS;
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
