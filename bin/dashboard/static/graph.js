// u13-frontend-themes: fixed-radial swarm renderer (v2 update of u5).
// Vanilla canvas + requestAnimationFrame, with absolutely-positioned DOM
// labels and per-role transparent button overlays. State and motion
// vocabulary lives in glyphs.js; theme-aware role-image URLs come from
// themes.js so each repaint picks up the active theme's assets.
//
// v2 changes vs u5:
//  - Per-edge per-direction token serialisation: only one token in flight
//    per (from→to) at any moment, the rest queue. Queue tail coalesces
//    into a `×N` badge beyond depth 6.
//  - Synthetic heartbeat tokens emit a `status:` ping along edges with
//    recent activity if no real traffic has fired for HEARTBEAT_GAP_MS;
//    the master spec's aliveness floor (one token / 4 s / edge).
//  - Role images cached per (theme,url) so a theme switch invalidates
//    the cache via the themes.onChange listener.
//  - Selection cue is a 3 px offset ring outside the state ring, scoped
//    in CSS via [data-theme] when a theme wants to override.

import {
  prefixInfo,
  STATE_COLOR_VAR, STATE_BADGE,
  cssVar, withAlpha,
  glyphForRole, getActive as activeTheme, onChange as onThemeChange,
} from './glyphs.js';

const TOKEN_RADIUS_PX     = 9;
const TOKEN_LANE_PX       = 6;
const TOKEN_DUR_MIN_MS    = 600;
const TOKEN_DUR_MAX_MS    = 900;
const TRACE_DECAY_MS      = 6000;
const QUEUE_VISIBLE_CAP   = 6;
const HEARTBEAT_GAP_MS    = 4000;     // aliveness floor: 1 token / 4 s / edge
const HEARTBEAT_RECENT_MS = 20000;    // edge eligible if any peer was active recently
const FLASH_DUR_MS        = 200;
const HALO_LINGER_MS      = 200;
const RING_THICK_PX       = 3;
const SELECT_RING_PX      = 3;
const SELECT_RING_GAP_PX  = 4;
const SEEN_MSG_LIMIT      = 2000;
const REST_MASCOT_AFTER_MS = 30000;   // "swarm resting" mascot fades in after this
const ORBIT_PERIOD_MS     = 2400;     // delegating-orbit revolution (design/u24-delegating-visual.md §1)
const ORBIT_GAP_PX        = 9;        // distance from disc edge to orbit ring
const ORBIT_DOT_R_PX      = 3.5;      // 7 px diameter
const ORBIT_PHASE_STEP_MS = 370;      // (role-index * 0.37 s) % period; desyncs N orbits

// U7 message-token info layer (design/u7-token-info-layer.md).
const HALO_SIZE_TABLE     = [        // [thresholdChars, haloPx]
  [32,   0],
  [128,  4],
  [512,  8],
  [2048, 12],
  [Infinity, 14],
];
const QUESTION_FADE_MS    = 800;
const QUESTION_LANE_PX    = 6;
const QUESTION_VISIBLE_PER_PAIR = 3;
const POPOVER_DWELL_MS    = 200;
const POPOVER_HIT_GRACE_MS = 200;
const ORBIT_FADE_MS       = 200;      // u32-f1: enter/exit opacity tween (spec §1)

// Image cache: url → HTMLImageElement. A theme change invalidates entries
// via clearImageCache() so the next render fetches the new-theme assets.
const imageCache = new Map();
function loadImage(url) {
  if (imageCache.has(url)) return imageCache.get(url);
  const img = new Image();
  img.src = url;
  imageCache.set(url, img);
  return img;
}
function clearImageCache() { imageCache.clear(); }

// U7: halo radius from message body length per spec §1 piecewise table.
function haloRadiusFor(bodyLen) {
  if (!Number.isFinite(bodyLen) || bodyLen <= 0) return 4;  // medium default
  for (const [cap, r] of HALO_SIZE_TABLE) {
    if (bodyLen < cap) return r;
  }
  return 14;
}

// u24: derive the three-way activity behaviour (working / delegating / idle)
// from the server's optional `activity` field; fall back to the legacy `state`
// when the server hasn't been upgraded yet so old recorded snapshots and any
// pre-u24 server still render sanely.
function activityFor(r) {
  const a = r && r.activity;
  if (a === 'working' || a === 'delegating'
      || a === 'idle'  || a === 'stalled-api'
      || a === 'give-up') return a;
  switch (r && r.state) {
    case 'stalled-api': return 'stalled-api';
    case 'give-up':     return 'give-up';
    case 'active':      return 'working';
    case 'idle':
    case 'paused':
    case 'dead':        return 'idle';
    default:            return null;
  }
}

function subagentCount(r) {
  const n = r && r.subagent_count;
  return (Number.isFinite(n) && n > 0) ? Math.floor(n) : 0;
}

// Distinguish truly-zero (server reported `delegating:0`, hide pill) from
// unknown (server emitted plain `delegating`, render ⚙). Spec §2 hides on 0
// but draws a ⚙ glyph when the helper could not parse N.
function subagentBadge(r) {
  if (!r) return null;
  const n = r.subagent_count;
  if (Number.isFinite(n)) {
    if (n <= 0) return null;       // truly 0 → hide pill
    return String(Math.floor(n));
  }
  return '⚙';                       // unknown → ⚙ glyph at pill geometry
}

function roleTooltip(r, now, lastSeenActive) {
  const name = (r && r.name) || '';
  const act = activityFor(r);
  const n = subagentCount(r);
  switch (act) {
    case 'working':     return `${name}: working`;
    case 'delegating':  return `${name}: delegating to ${n || '?'} subagent${n === 1 ? '' : 's'}`;
    case 'stalled-api': return `${name}: stalled (API)`;
    case 'give-up':     return `${name}: give-up`;
    case 'idle': {
      const age = (lastSeenActive && now > lastSeenActive)
        ? Math.round((now - lastSeenActive) / 1000) : null;
      return age != null
        ? `${name}: idle (last activity ${age}s ago)`
        : `${name}: idle`;
    }
    default: return `open ${name} feed`;
  }
}

export class GraphView {
  constructor(rootEl, callbacks = {}) {
    this.root = rootEl;
    this.onNodeClick = callbacks.onNodeClick || (() => {});
    this.onCanvasClick = callbacks.onCanvasClick || (() => {});
    this.reducedMotion =
      window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Layout (logical pixels, top-left origin = root's top-left).
    this.layout = new Map();   // name → { x, y, ring, idx, baseR }
    this.canvasW = 0;
    this.canvasH = 0;
    this.dpr = window.devicePixelRatio || 1;

    // Live model.
    this.roster = [];          // last seen array of role objects
    this.rosterByName = new Map();
    this.nodeRuntime = new Map();  // name → { phase0, flashUntil, haloUntil, lastSeenActive }
    this.tokens = [];          // in-flight tokens (one per pair-direction)
    this.pending = new Map();  // (from,to) → queued tokens awaiting launch
    this.traces = [];          // decaying traces
    this.seenMsgIds = new Set();
    this.selectedRole = null;
    this.lastTokenLandedAt = 0;
    // Heartbeat: last time a (from,to) edge launched a token (real or synth).
    this.edgeLastEmit = new Map();
    // U7: open-question records keyed by `${from}->${to}`, FIFO list per
    // pair. Each entry: { msgId, prefix, from, to, bornAt, fadeOutAt? }.
    // Cleared on matching `answer:` from receiver → sender or on role retirement.
    this.openQuestions = new Map();
    // U7: hover-popover state. `popoverTarget` is the token / question
    // record currently dwelt on; `popoverShownAt` is when the popover
    // became visible; `popoverHideAfter` lets the cursor briefly leave
    // the canvas and return without flicker.
    this.popoverTarget    = null;
    this.popoverDwellFrom = 0;
    this.popoverEl        = null;
    this._messagesById    = new Map();   // id → last-seen /state.json message rec
    // Re-clear the image cache on theme change so canvas redraws pull
    // the new theme's PNGs on the next animation frame.
    this._unsubTheme = onThemeChange(() => clearImageCache());

    // DOM scaffolding.
    this._buildScaffold();
    // Initial layout: ResizeObserver's first callback fires after the next
    // animation frame, but the first /state.json poll can resolve sooner.
    // Synchronously sizing the canvas now means message ingestion on the
    // first poll already has a populated layout to look node positions up in.
    this._resize();

    // Run the loop forever; the cost is one rAF per frame.
    this._tickBound = () => this._tick();
    requestAnimationFrame(this._tickBound);

    // Sync on resize.
    if (window.ResizeObserver) {
      this._ro = new ResizeObserver(() => this._resize());
      this._ro.observe(this.root);
    } else {
      window.addEventListener('resize', () => this._resize());
    }

    this._mqlReducedMotion =
      window.matchMedia('(prefers-reduced-motion: reduce)');
    this._mqlReducedMotion.addEventListener?.('change', (e) => {
      this.reducedMotion = e.matches;
    });
  }

  // ------------------------------------------------------------------ scaffold

  _buildScaffold() {
    this.root.classList.add('graph-host');
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'graph-canvas';
    this.root.appendChild(this.canvas);
    this.ctx = this.canvas.getContext('2d');

    this.overlay = document.createElement('div');
    this.overlay.className = 'graph-overlay';
    this.root.appendChild(this.overlay);

    // Empty-canvas click (clicks that miss every role button bubble here).
    this.canvas.addEventListener('click', () => this.onCanvasClick());
    this.overlay.addEventListener('click', (e) => {
      if (e.target === this.overlay) this.onCanvasClick();
    });
  }

  // ------------------------------------------------------------------ layout

  _resize() {
    const rect = this.root.getBoundingClientRect();
    const w = Math.max(1, Math.round(rect.width));
    const h = Math.max(1, Math.round(rect.height));
    this.dpr = window.devicePixelRatio || 1;
    this.canvasW = w;
    this.canvasH = h;
    this.canvas.width = w * this.dpr;
    this.canvas.height = h * this.dpr;
    this.canvas.style.width = w + 'px';
    this.canvas.style.height = h + 'px';
    this.ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    this._recomputeLayout();
    this._syncOverlayPositions();
  }

  _recomputeLayout() {
    this.layout.clear();
    if (!this.roster.length || this.canvasW === 0) return;

    const cx = this.canvasW / 2;
    const cy = this.canvasH / 2;
    const orch = this.roster.find(r => r.is_orchestrator);
    const peers = this.roster
      .filter(r => !r.is_orchestrator)
      .slice()
      .sort((a, b) => a.name.localeCompare(b.name));

    const baseNodeR = parseInt(cssVar('--node-size'), 10) || 44;
    const peerR = baseNodeR;
    const orchR = Math.round(baseNodeR * 1.25);

    // Squeeze ring radius so the largest node + its label clears the edges.
    const ringR = Math.max(80,
      Math.min(cx, cy) - peerR - 64);

    if (orch) {
      this.layout.set(orch.name,
        { x: cx, y: cy, ring: 0, idx: 0, baseR: orchR });
    }

    const N = peers.length;
    const twoRing = N >= 10;
    if (!twoRing) {
      peers.forEach((r, i) => {
        const angle = -Math.PI / 2 + (2 * Math.PI * i) / Math.max(1, N);
        this.layout.set(r.name, {
          x: cx + ringR * Math.cos(angle),
          y: cy + ringR * Math.sin(angle),
          ring: 1, idx: i, baseR: peerR,
        });
      });
    } else {
      // Two rings: even idx on ring 1, odd on ring 2 (offset by half-step).
      const r1 = ringR;
      const r2 = Math.max(60, ringR * 0.62);
      let i1 = 0, i2 = 0;
      const n1 = Math.ceil(N / 2);
      const n2 = N - n1;
      peers.forEach((r, i) => {
        const onR1 = (i % 2 === 0);
        if (onR1) {
          const angle = -Math.PI / 2 + (2 * Math.PI * i1) / Math.max(1, n1);
          this.layout.set(r.name, {
            x: cx + r1 * Math.cos(angle), y: cy + r1 * Math.sin(angle),
            ring: 1, idx: i1, baseR: peerR,
          });
          i1++;
        } else {
          const halfStep = Math.PI / Math.max(1, n2);
          const angle = -Math.PI / 2 + halfStep
            + (2 * Math.PI * i2) / Math.max(1, n2);
          this.layout.set(r.name, {
            x: cx + r2 * Math.cos(angle), y: cy + r2 * Math.sin(angle),
            ring: 2, idx: i2, baseR: peerR,
          });
          i2++;
        }
      });
    }
  }

  _syncOverlayPositions() {
    for (const r of this.roster) {
      const pos = this.layout.get(r.name);
      const label = this._labelEl(r.name);
      const button = this._buttonEl(r.name);
      if (!pos || !label || !button) continue;
      // U6: 22 px gap from disc edge to label baseline (was 14 px) gives
      // every role its own vertical lane and stops dense clusters from
      // colliding with the disc above the next ring's labels.
      const labelOffsetY = pos.baseR + 22;
      label.style.left = pos.x + 'px';
      label.style.top  = (pos.y + labelOffsetY) + 'px';
      const hitSize = (pos.baseR * 2) + 14;
      button.style.left = (pos.x - hitSize / 2) + 'px';
      button.style.top  = (pos.y - hitSize / 2) + 'px';
      button.style.width  = hitSize + 'px';
      button.style.height = hitSize + 'px';
      // u32-f2: subagent pill is a DOM overlay (top: -6 / right: -6 from the
      // node bounding box per design/u24-delegating-visual.md §2). The bbox
      // is the role-disc circle inscribed in `hitSize`; its top-right corner
      // in overlay coords sits at (pos.x + baseR, pos.y - baseR). The pill
      // anchors there with the spec's -6 px offset on each axis.
      const pill = this._pillEl(r.name);
      if (pill) {
        pill.style.left = (pos.x + pos.baseR + 6) + 'px';
        pill.style.top  = (pos.y - pos.baseR - 6) + 'px';
      }
    }
  }

  _labelEl(name) {
    return this.overlay.querySelector(`[data-role-label="${cssEsc(name)}"]`);
  }

  _buttonEl(name) {
    return this.overlay.querySelector(`button[data-role="${cssEsc(name)}"]`);
  }

  _pillEl(name) {
    return this.overlay.querySelector(`[data-role-pill="${cssEsc(name)}"]`);
  }

  // ------------------------------------------------------------------ snapshot

  update(snap, lastSnapshotRecvAt) {
    const now = performance.now();
    const roster = (snap.roster || []).slice();
    // Stable order: orchestrator first, then alphabetical peers.
    roster.sort((a, b) => {
      if (a.is_orchestrator && !b.is_orchestrator) return -1;
      if (!a.is_orchestrator && b.is_orchestrator) return 1;
      return a.name.localeCompare(b.name);
    });
    this.roster = roster;
    this.rosterByName = new Map(roster.map(r => [r.name, r]));

    // Sync DOM children: add/remove role label + button + pill (u32-f2).
    const wanted = new Set(roster.map(r => r.name));
    for (const child of [...this.overlay.children]) {
      const name = child.dataset.role
                || child.dataset.roleLabel
                || child.dataset.rolePill;
      if (name && !wanted.has(name)) {
        child.remove();
        this.nodeRuntime.delete(name);
        if (this.selectedRole === name) this.selectedRole = null;
      }
    }
    for (const r of roster) {
      if (!this._buttonEl(r.name)) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'role-hit';
        btn.dataset.role = r.name;
        btn.setAttribute('aria-label', `open ${r.name} feed`);
        btn.addEventListener('click', (e) => {
          e.stopPropagation();
          this.onNodeClick(r.name);
        });
        this.overlay.appendChild(btn);
      }
      if (!this._labelEl(r.name)) {
        const lbl = document.createElement('div');
        lbl.className = 'role-label';
        lbl.dataset.roleLabel = r.name;
        lbl.textContent = r.name;
        this.overlay.appendChild(lbl);
      }
      this._labelEl(r.name).dataset.roleState = r.state;
      const btn = this._buttonEl(r.name);
      btn.dataset.roleState = r.state;
      const act = activityFor(r);
      if (act) btn.dataset.activity = act;
      else delete btn.dataset.activity;
      const seenAt = this.nodeRuntime.get(r.name)?.lastSeenActive || 0;
      btn.title = roleTooltip(r, now, seenAt);
      btn.setAttribute('aria-label', btn.title);
      if (this.selectedRole === r.name) btn.dataset.selected = 'true';
      else delete btn.dataset.selected;

      // u32-f2: subagent-count pill is a DOM overlay (was a canvas circle).
      // The rounded-rect honours --radius-pill and expands past 18 px for
      // multi-digit labels; spec recipe in design/u24-delegating-visual.md §2.
      const pillLabel = (act === 'delegating') ? subagentBadge(r) : null;
      let pill = this._pillEl(r.name);
      if (pillLabel) {
        if (!pill) {
          pill = document.createElement('div');
          pill.className = 'role-pill';
          pill.dataset.rolePill = r.name;
          pill.setAttribute('aria-hidden', 'true');
          this.overlay.appendChild(pill);
        }
        pill.textContent = pillLabel;
      } else if (pill) {
        pill.remove();
      }

      // Spawn runtime entry for new nodes; preserve phase if already there.
      const isDeleg = act === 'delegating';
      if (!this.nodeRuntime.has(r.name)) {
        this.nodeRuntime.set(r.name, {
          phase0: Math.random() * Math.PI * 2,
          flashUntil: 0,
          flashScale: 1.0,
          haloUntil: 0,
          lastSeenActive: r.state === 'active' ? now : 0,
          // u32-f1 orbit fade: track the most recent delegating ↔ not-deleg
          // flip so _drawNodes can interpolate alpha across ORBIT_FADE_MS.
          // A node that joins already-delegating skips the tween (its first
          // frame snaps to target so we don't fake a fade for state we never
          // observed entering).
          orbitTarget:  isDeleg ? 1.0 : 0.0,
          orbitFromAlpha: isDeleg ? 1.0 : 0.0,
          orbitChangeAt: -ORBIT_FADE_MS,
        });
      } else {
        const rt = this.nodeRuntime.get(r.name);
        if (r.state === 'active') rt.lastSeenActive = now;
        const target = isDeleg ? 1.0 : 0.0;
        if (target !== rt.orbitTarget) {
          // Use the in-flight alpha at the moment of the flip as the new
          // tween's start point. This keeps a mid-fade-out → fade-in (or vice
          // versa) continuous instead of snapping to the other endpoint.
          rt.orbitFromAlpha = this._currentOrbitAlpha(rt, now);
          rt.orbitTarget = target;
          rt.orbitChangeAt = now;
        }
      }
    }

    // Recompute layout if topology changed (size or set differs).
    this._recomputeLayout();
    this._syncOverlayPositions();

    // Ingest new messages → spawn tokens. Broadcasts halo the sender;
    // direct messages enter the per-edge queue (one in-flight per dir).
    for (const m of (snap.messages || [])) {
      if (!m || !m.id || this.seenMsgIds.has(m.id)) continue;
      this.seenMsgIds.add(m.id);
      this._messagesById.set(m.id, m);
      if (m.kind === 'broadcast') {
        this._kickHalo(m.from, now);
        continue;
      }
      if (!m.from || !m.to) continue;
      if (!this.layout.has(m.from) || !this.layout.has(m.to)) continue;
      // A real message keeps both endpoints "recently active" so the
      // heartbeat keeps the edge alive between polls.
      const fromRt = this.nodeRuntime.get(m.from);
      const toRt   = this.nodeRuntime.get(m.to);
      if (fromRt) fromRt.lastSeenActive = now;
      if (toRt)   toRt.lastSeenActive   = now;
      this._spawnToken(m.from, m.to, m.prefix || 'other', now,
                       /*synthetic*/ false, m.id, m.body_length);
      // U7: question trail bookkeeping. A `question:` from A→B opens an
      // entry on the (A→B) pair; an `answer:` from B→A pops the oldest
      // open entry on the (A→B) pair and starts an 800 ms fade-out.
      this._trackOpenQuestion(m, now);
    }
    this._reapClosedQuestions(now);
    // U7: prune the message cache so it does not grow unbounded.
    if (this._messagesById.size > SEEN_MSG_LIMIT) {
      const live = [...this._messagesById.entries()].slice(-Math.floor(SEEN_MSG_LIMIT / 2));
      this._messagesById = new Map(live);
    }
    if (this.seenMsgIds.size > SEEN_MSG_LIMIT) {
      const trimmed = [...this.seenMsgIds].slice(-Math.floor(SEEN_MSG_LIMIT / 2));
      this.seenMsgIds = new Set(trimmed);
    }
  }

  setSelected(name) {
    if (this.selectedRole === name) return;
    if (this.selectedRole) {
      const prev = this._buttonEl(this.selectedRole);
      if (prev) delete prev.dataset.selected;
    }
    this.selectedRole = name;
    if (name) {
      const btn = this._buttonEl(name);
      if (btn) btn.dataset.selected = 'true';
    }
  }

  // ------------------------------------------------------------------ U7 question trail

  _trackOpenQuestion(m, now) {
    if (!m || !m.prefix) return;
    if (m.prefix === 'question') {
      const key = this._dirKey(m.from, m.to);
      let q = this.openQuestions.get(key);
      if (!q) { q = []; this.openQuestions.set(key, q); }
      q.push({ msgId: m.id, from: m.from, to: m.to, bornAt: now });
      return;
    }
    if (m.prefix === 'answer') {
      // FIFO match against the reverse-direction open-question queue.
      const reverseKey = this._dirKey(m.to, m.from);
      const q = this.openQuestions.get(reverseKey);
      if (!q || !q.length) return;
      const closing = q.shift();
      closing.fadeOutAt = now;
      // Park the closing entry on a separate fade-queue so the draw loop
      // still renders it through the 800 ms fade window.
      let fq = this.openQuestions.get(reverseKey + ':fade');
      if (!fq) { fq = []; this.openQuestions.set(reverseKey + ':fade', fq); }
      fq.push(closing);
      if (!q.length) this.openQuestions.delete(reverseKey);
    }
  }

  _reapClosedQuestions(now) {
    // Drop fade-out entries past their 800 ms window. Also drop entries
    // whose endpoints no longer resolve (a role retired with an open
    // question — silent fade per spec §2 "pair matching").
    for (const [key, list] of [...this.openQuestions.entries()]) {
      const isFade = key.endsWith(':fade');
      const keep = list.filter((q) => {
        if (isFade) return (now - q.fadeOutAt) < QUESTION_FADE_MS;
        if (!this.layout.has(q.from) || !this.layout.has(q.to)) {
          // Endpoint gone: convert to a fade-out so the trail vanishes
          // gracefully instead of popping.
          q.fadeOutAt = now;
          const dst = key + ':fade';
          let fq = this.openQuestions.get(dst);
          if (!fq) { fq = []; this.openQuestions.set(dst, fq); }
          fq.push(q);
          return false;
        }
        return true;
      });
      if (keep.length === 0) this.openQuestions.delete(key);
      else this.openQuestions.set(key, keep);
    }
  }

  // U8: per-role count of LIVE (unanswered) open questions addressed to that
  // role. Sources the same openQuestions Map the U7 trail uses, so the badge
  // count and the on-edge ? chips never disagree. ':fade' (just-answered)
  // keys are excluded so the count drops the instant an answer lands.
  _openQuestionCounts() {
    const counts = new Map();
    for (const [key, list] of this.openQuestions) {
      if (key.endsWith(':fade')) continue;
      for (const q of list) counts.set(q.to, (counts.get(q.to) || 0) + 1);
    }
    return counts;
  }

  // ------------------------------------------------------------------ tokens

  // v2 (master spec section 6 "Message-token rhythm"): one token in flight
  // per (from→to) at a time. New traffic on the same edge queues; a queue
  // tail beyond QUEUE_VISIBLE_CAP coalesces into a single `×N` badge.
  _spawnToken(from, to, prefix, now, synthetic = false, msgId = null, bodyLen = null) {
    if (!this.layout.has(from) || !this.layout.has(to)) return;
    const key = this._dirKey(from, to);
    const inFlight = this.tokens.find(
      t => t.from === from && t.to === to);
    if (!inFlight) {
      this._launchToken(from, to, prefix, now, synthetic, msgId, bodyLen);
      return;
    }
    // Queue behind the in-flight token.
    let q = this.pending.get(key);
    if (!q) { q = []; this.pending.set(key, q); }
    if (q.length >= QUEUE_VISIBLE_CAP) {
      const tail = q[q.length - 1];
      tail.count = (tail.count || 1) + 1;
      return;
    }
    q.push({ from, to, prefix, count: 1, synthetic, msgId, bodyLen });
  }

  _launchToken(from, to, prefix, now, synthetic, msgId = null, bodyLen = null) {
    const A = this.layout.get(from);
    const B = this.layout.get(to);
    if (!A || !B) return;
    const laneSign = (from < to) ? 1 : -1;
    const d = Math.hypot(B.x - A.x, B.y - A.y);
    const tau = Math.min(1, d / 720);
    const dur = TOKEN_DUR_MIN_MS + (TOKEN_DUR_MAX_MS - TOKEN_DUR_MIN_MS) * tau;
    this.tokens.push({
      from, to, prefix,
      spawn: now,
      dur,
      laneSign,
      count: 1,
      synthetic,
      msgId,
      bodyLen,
    });
    this.edgeLastEmit.set(this._dirKey(from, to), now);
    this._kickHalo(from, now);
    this._kickHalo(to, now);
  }

  _kickHalo(name, now) {
    const rt = this.nodeRuntime.get(name);
    if (!rt) return;
    rt.haloUntil = Math.max(rt.haloUntil, now + TOKEN_DUR_MAX_MS + HALO_LINGER_MS);
  }

  // u32-f1: resolve the current orbit alpha for a role. Linear interpolation
  // from `orbitFromAlpha` (the value at the moment of the last flip) toward
  // `orbitTarget` (1.0 or 0.0) across ORBIT_FADE_MS. Reduced-motion path
  // snaps without tween. A missing runtime entry (defensive default in
  // _drawNodes) reads as 0 so we never draw a ghost orbit.
  _currentOrbitAlpha(rt, now) {
    if (!rt || rt.orbitTarget == null) return 0;
    if (this.reducedMotion) return rt.orbitTarget;
    const dt = now - (rt.orbitChangeAt || 0);
    if (dt >= ORBIT_FADE_MS) return rt.orbitTarget;
    const k = Math.max(0, Math.min(1, dt / ORBIT_FADE_MS));
    const from = (rt.orbitFromAlpha == null) ? 0 : rt.orbitFromAlpha;
    return from + (rt.orbitTarget - from) * k;
  }

  _dirKey(a, b) { return `${a}->${b}`; }

  // Synthetic heartbeat: when no token is in flight for an edge whose
  // endpoints have recent activity, emit a low-weight `status:` ping so
  // the swarm always looks alive during real activity. Section 6 aliveness
  // floor: ≤ one synthetic token / 4 s / edge.
  _emitHeartbeats(now) {
    if (this.reducedMotion) return;       // master spec section 8 suppresses
    const orch = this.roster.find(r => r.is_orchestrator);
    if (!orch) return;
    for (const r of this.roster) {
      if (r.is_orchestrator) continue;
      const peer = r.name;
      const rt = this.nodeRuntime.get(peer);
      if (!rt) continue;
      const recentActive =
        rt.lastSeenActive && (now - rt.lastSeenActive) < HEARTBEAT_RECENT_MS;
      if (!recentActive) continue;
      const key = this._dirKey(orch.name, peer);
      const last = this.edgeLastEmit.get(key) || 0;
      if (now - last < HEARTBEAT_GAP_MS) continue;
      // Emit a synthetic status ping orchestrator → peer.
      this._spawnToken(orch.name, peer, 'status', now, /*synthetic*/ true);
    }
  }

  // ------------------------------------------------------------------ render

  _tick() {
    const now = performance.now();
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.canvasW, this.canvasH);

    this._emitHeartbeats(now);
    this._drawEdges(now);
    this._drawTraces(now);
    this._drawQuestionTrails(now);   // U7: persistent dashed line for open Qs
    this._drawNodes(now);
    this._drawTokens(now);
    this._drawRestingMascot(now);

    this._updatePopover(now);

    requestAnimationFrame(this._tickBound);
  }

  _pairKey(a, b) { return a < b ? `${a}::${b}` : `${b}::${a}`; }

  _drawEdges(now) {
    if (this.roster.length < 2) return;
    const ctx = this.ctx;
    const lit = new Set();
    for (const t of this.tokens) lit.add(this._pairKey(t.from, t.to));
    for (const tr of this.traces) lit.add(this._pairKey(tr.from, tr.to));

    // All dormant edges: faint wiring between every pair. To keep this cheap
    // and visually calm, we draw a single "spoke" from orchestrator to each
    // peer plus, only if traffic exists, the one-off pair edge.
    const orch = this.roster.find(r => r.is_orchestrator);
    const dormant = withAlpha(cssVar('--ink-tertiary'), 0.18);
    ctx.lineWidth = 1.2;
    ctx.strokeStyle = dormant;
    if (orch) {
      const A = this.layout.get(orch.name);
      if (A) {
        for (const r of this.roster) {
          if (r.is_orchestrator) continue;
          const B = this.layout.get(r.name);
          if (!B) continue;
          if (lit.has(this._pairKey(orch.name, r.name))) continue;
          ctx.beginPath();
          ctx.moveTo(A.x, A.y);
          ctx.lineTo(B.x, B.y);
          ctx.stroke();
        }
      }
    }
  }

  _drawTraces(now) {
    const ctx = this.ctx;
    const live = [];
    for (const tr of this.traces) {
      const age = now - tr.t0;
      if (age >= TRACE_DECAY_MS) continue;
      live.push(tr);
      const A = this.layout.get(tr.from);
      const B = this.layout.get(tr.to);
      if (!A || !B) continue;
      const lifeT = 1 - (age / TRACE_DECAY_MS);
      const tint = cssVar(prefixInfo(tr.prefix).colorVar);
      ctx.strokeStyle = withAlpha(tint, 0.55 * lifeT);
      ctx.lineWidth = 2.2;
      const lane = tr.laneSign * TOKEN_LANE_PX;
      const [ax, ay, bx, by] = laneEndpoints(A, B, lane);
      ctx.beginPath();
      ctx.moveTo(ax, ay);
      ctx.lineTo(bx, by);
      ctx.stroke();
    }
    this.traces = live;
  }

  _drawNodes(now) {
    const ctx = this.ctx;
    const qCounts = this._openQuestionCounts();   // U8: per-role open-Q counts
    for (const r of this.roster) {
      const pos = this.layout.get(r.name);
      if (!pos) continue;
      const rt = this.nodeRuntime.get(r.name) || { phase0: 0 };

      const state = r.state || 'idle';
      const stateColor = cssVar(STATE_COLOR_VAR[state] || STATE_COLOR_VAR.idle);

      // Compute motion-driven transforms.
      let scale = 1.0;
      let opacity = 1.0;
      let yShift = 0;
      let haloRadiusBoost = 0;
      let haloOpacity = 0;

      if (!this.reducedMotion) {
        switch (state) {
          case 'active': {
            const t = phase(now, 1600, rt.phase0);
            scale = 1.0 + 0.06 * (0.5 - 0.5 * Math.cos(t * 2 * Math.PI));
            break;
          }
          case 'paused': {
            const t = phase(now, 3000, rt.phase0);
            opacity = 0.7 + 0.3 * (0.5 - 0.5 * Math.cos(t * 2 * Math.PI));
            break;
          }
          case 'question': {
            const t = phase(now, 1000, rt.phase0);
            yShift = 3 * Math.sin(t * 2 * Math.PI);
            break;
          }
          case 'stalled-api': {
            const t = phase(now, 800, rt.phase0);
            opacity = (t < 0.5) ? 0.6 : 1.0;
            break;
          }
          case 'give-up': {
            const t = phase(now, 3000, rt.phase0);
            // halo: radius grows 1.0→1.45, opacity 0.5→0.0
            const k = (0.5 - 0.5 * Math.cos(t * 2 * Math.PI));
            haloRadiusBoost = 0.45 * k * pos.baseR;
            haloOpacity = 0.5 * (1 - k);
            break;
          }
          case 'dead':
          case 'idle':
          default:
            break;
        }
      }

      // Receive-flash overlay (token landed within FLASH_DUR_MS).
      if (rt.flashUntil && now < rt.flashUntil) {
        const t = (rt.flashUntil - now) / FLASH_DUR_MS;
        const k = 1 - t;     // 0..1 over the flash duration
        const peak = rt.flashScale || 1.08;
        // Cosine bump: 0 -> peak -> 1.
        const bump = 1 + (peak - 1) * Math.sin(k * Math.PI);
        scale *= bump;
      }

      // Halo while sending/receiving.
      const drawHalo = rt.haloUntil && now < rt.haloUntil;

      ctx.save();
      ctx.translate(pos.x, pos.y + yShift);
      ctx.globalAlpha = opacity;

      const R = pos.baseR * scale;
      // 1) Outer give-up halo (extra ring outside the state ring).
      if (state === 'give-up' && haloOpacity > 0.01 && !this.reducedMotion) {
        ctx.beginPath();
        ctx.arc(0, 0, R + haloRadiusBoost + 6, 0, 2 * Math.PI);
        ctx.strokeStyle = withAlpha(stateColor, haloOpacity);
        ctx.lineWidth = 4;
        ctx.stroke();
      }
      // 2) Activity halo (token in/out of this node).
      if (drawHalo) {
        ctx.beginPath();
        ctx.arc(0, 0, R + 6, 0, 2 * Math.PI);
        ctx.strokeStyle = cssVar('--node-halo');
        ctx.lineWidth = 2;
        ctx.stroke();
      }
      // 3) Drop shadow under disc (one-time blur for "lift").
      ctx.save();
      ctx.shadowColor = 'rgba(0,0,0,0.45)';
      ctx.shadowBlur = 14;
      ctx.shadowOffsetY = 4;
      ctx.fillStyle = cssVar('--surface-2');
      ctx.beginPath();
      ctx.arc(0, 0, R, 0, 2 * Math.PI);
      ctx.fill();
      ctx.restore();

      // 4) Role glyph image (60% of disc). URL is theme-aware via themes.js.
      const imgUrl = glyphForRole(r.name);
      const img = loadImage(imgUrl);
      if (img.complete && img.naturalWidth > 0) {
        const gR = R * 0.6;
        ctx.save();
        if (state === 'dead') {
          // grayscale-ish via low alpha overlay; canvas has no filter API
          // everywhere, so we just dim it.
          ctx.globalAlpha = opacity * 0.55;
        }
        ctx.drawImage(img, -gR, -gR, gR * 2, gR * 2);
        ctx.restore();
      }

      // 5) State ring.
      drawStateRing(ctx, R, state, stateColor);

      // 6) State badge (top-right corner) — non-empty for paused / question /
      //    stalled-api / give-up. Always drawn so reduced-motion still reads.
      const badge = STATE_BADGE[state];
      if (badge) {
        const bx = R * 0.78, by = -R * 0.78;
        ctx.fillStyle = stateColor;
        ctx.beginPath();
        ctx.arc(bx, by, R * 0.32, 0, 2 * Math.PI);
        ctx.fill();
        ctx.fillStyle = cssVar('--bg');
        ctx.font = `700 ${Math.round(R * 0.42)}px ${cssVar('--font-sans')}`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(badge, bx, by + 1);
      }

      // 6a) U8 open-question count badge (top-LEFT corner; mirror of the
      //     state badge). Counts unanswered questions addressed TO this role
      //     (openQuestions Map, addressee side). Question-colour disc +
      //     --bg numeral, capped 9+, hidden at 0, static (no pulse) in every
      //     motion mode — design/phase-e-design-confirm-addendum.md §1.
      //     Convention: top-right = "what I am", top-left = "what's owed to
      //     me". This is the filled-disc recipe (legible on every theme,
      //     ghibli included), NOT the U7 thin-trail/edge-chip recipe.
      const qCount = qCounts.get(r.name) || 0;
      if (qCount > 0) {
        const qx = -R * 0.78, qy = -R * 0.78;
        ctx.fillStyle = cssVar('--state-question-color')
                     || cssVar('--edge-question') || '#F5C46A';
        ctx.beginPath();
        ctx.arc(qx, qy, R * 0.32, 0, 2 * Math.PI);
        ctx.fill();
        const qLabel = qCount > 9 ? '9+' : String(qCount);
        // Single digit at the state-badge size; shrink "9+" so two glyphs
        // stay inside the disc without growing it (addendum: cap 9+, do not
        // grow the disc).
        const qFs = Math.round(R * (qLabel.length > 1 ? 0.34 : 0.42));
        ctx.fillStyle = cssVar('--bg');
        ctx.font = `700 ${qFs}px ${cssVar('--font-sans')}`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(qLabel, qx, qy + 1);
      }

      // 6b) Delegating: one orbiting satellite disc + a top-right N pill
      //     per design/u24-delegating-visual.md §1–§2. Reads as the second
      //     non-colour channel for "busy but waiting on a subagent",
      //     additive to the existing state colour + breathe. Theme-safe via
      //     --state-active-color (or --node-active) / --surface-2 /
      //     --token-ink — no hardcoded hex.
      const activity = activityFor(r);
      // u32-f1: orbit visibility tweens over ORBIT_FADE_MS on every
      // delegating ↔ not-delegating flip; outside the tween window the alpha
      // sits at its target (1.0 while delegating, 0.0 otherwise). When both
      // alpha and target are zero, skip the draw entirely so a non-delegating
      // node costs nothing extra.
      const orbitAlpha = this._currentOrbitAlpha(rt, now);
      if (orbitAlpha > 0.001) {
        const orbitR = R + ORBIT_GAP_PX;
        const roleIdx = this.roster.indexOf(r);
        // Phase: role-index offset desyncs N concurrent orbits so the canvas
        // never throbs in lockstep. Reduced-motion snaps to angle -π/2 (top
        // of node) so the satellite remains visible as a static channel.
        let a;
        if (this.reducedMotion) {
          a = -Math.PI / 2;
        } else {
          const offset = ((roleIdx * ORBIT_PHASE_STEP_MS) % ORBIT_PERIOD_MS)
                       / ORBIT_PERIOD_MS;
          // Linear angular velocity → clockwise (screen Y flipped, so +a is CW).
          a = ((now / ORBIT_PERIOD_MS) + offset) * 2 * Math.PI - Math.PI / 2;
        }
        const dx = orbitR * Math.cos(a);
        const dy = orbitR * Math.sin(a);
        const activeCol = cssVar('--state-active-color')
                       || cssVar('--node-active') || stateColor;
        const inkCol = cssVar('--token-ink') || '#1A1730';
        ctx.beginPath();
        ctx.arc(dx, dy, ORBIT_DOT_R_PX, 0, 2 * Math.PI);
        ctx.fillStyle = withAlpha(activeCol, 0.85 * orbitAlpha);
        ctx.fill();
        ctx.lineWidth = 1;
        ctx.strokeStyle = withAlpha(inkCol, 0.55 * orbitAlpha);
        ctx.stroke();
      }
      // u32-f2: the pill render moved out of the canvas into a DOM overlay
      // managed in update() + _syncOverlayPositions. The canvas-circle drew
      // a fixed-radius disc that cramped two-digit labels; the DOM rounded-
      // rect expands past 18 px for multi-digit counts per spec §2.

      // 7) Selection cue: 3 px solid offset ring outside the state ring,
      //    coloured per-theme via --selection-cue. The cue is NEVER in any
      //    channel the seven role-states use, so an active question-state
      //    selected node reads as dashed-yellow + cream offset ring
      //    (master spec section 7).
      if (this.selectedRole === r.name) {
        const cueR = R + SELECT_RING_GAP_PX + SELECT_RING_PX;
        const cueCol = cssVar('--selection-cue') || cssVar('--text') || '#EDEAD8';
        ctx.beginPath();
        ctx.arc(0, 0, cueR, 0, 2 * Math.PI);
        ctx.strokeStyle = withAlpha(cueCol, 0.92);
        ctx.lineWidth = SELECT_RING_PX;
        ctx.stroke();
      }

      ctx.restore();
    }
  }

  _drawTokens(now) {
    const ctx = this.ctx;
    const survivors = [];
    const justLanded = [];
    for (const tk of this.tokens) {
      if (now < tk.spawn) { survivors.push(tk); continue; }
      const age = now - tk.spawn;
      if (age >= tk.dur) {
        // Token landed: convert to a trace, flash receiver, kick halo.
        // Synthetic heartbeat tokens skip the trace (kept understated).
        if (!tk.synthetic) {
          this.traces.push({
            from: tk.from, to: tk.to, prefix: tk.prefix,
            t0: now, laneSign: tk.laneSign,
          });
        }
        const rxRt = this.nodeRuntime.get(tk.to);
        if (rxRt) {
          rxRt.flashUntil = now + FLASH_DUR_MS;
          rxRt.flashScale = (tk.to === 'orchestrator') ? 1.12 : 1.08;
          rxRt.haloUntil = Math.max(rxRt.haloUntil, now + HALO_LINGER_MS);
        }
        this.lastTokenLandedAt = now;
        justLanded.push(tk);
        continue;
      }
      survivors.push(tk);
      if (this.reducedMotion) continue;   // no traveling disc

      const t = age / tk.dur;
      // Ease curve: cubic-bezier(0.5,0,0.5,1) ≈ smoothstep.
      const e = t * t * (3 - 2 * t);
      const A = this.layout.get(tk.from);
      const B = this.layout.get(tk.to);
      if (!A || !B) continue;
      const lane = tk.laneSign * TOKEN_LANE_PX;
      const [ax, ay, bx, by] = laneEndpoints(A, B, lane);
      const x = ax + (bx - ax) * e;
      const y = ay + (by - ay) * e;

      // Leading-edge lit trace behind the token.
      const tint = cssVar(prefixInfo(tk.prefix).colorVar);
      ctx.strokeStyle = withAlpha(tint, 0.85);
      ctx.lineWidth = 2.4;
      ctx.beginPath();
      const trailStart = Math.max(0, e - 0.30);
      const sx = ax + (bx - ax) * trailStart;
      const sy = ay + (by - ay) * trailStart;
      ctx.moveTo(sx, sy);
      ctx.lineTo(x, y);
      ctx.stroke();

      // U7: body-length halo around the disc (spec §1). Radius scales
      // piecewise with token bodyLen so a ping reads small and a long-form
      // file pointer reads large; radial gradient draws once per frame per
      // visible token, which the spec's FPS budget covers.
      tk._haloR = (tk.bodyLen != null) ? haloRadiusFor(tk.bodyLen)
                                       : (tk.synthetic ? 0 : 4);
      if (tk._haloR > 0) {
        const haloAlpha = parseFloat(cssVar('--token-halo-alpha')) || 0.5;
        const inner = TOKEN_RADIUS_PX;
        const outer = TOKEN_RADIUS_PX + tk._haloR;
        const grad = ctx.createRadialGradient(x, y, inner, x, y, outer);
        grad.addColorStop(0, withAlpha(tint, haloAlpha));
        grad.addColorStop(1, withAlpha(tint, 0));
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.arc(x, y, outer, 0, 2 * Math.PI);
        ctx.fill();
      }

      // Stash the resolved screen-space coords so the hover hit-test in
      // _hoverAt() does not recompute the easing curve per pointer move.
      tk._x = x;
      tk._y = y;

      // Token disc.
      ctx.save();
      ctx.shadowColor = cssVar('--token-glow') || 'rgba(255,255,255,0.55)';
      ctx.shadowBlur = 8;
      ctx.fillStyle = cssVar('--token-fill') || '#FFF5DD';
      ctx.strokeStyle = cssVar('--token-stroke') || '#1A1730';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(x, y, TOKEN_RADIUS_PX, 0, 2 * Math.PI);
      ctx.fill();
      ctx.stroke();
      ctx.restore();

      // Glyph centred on disc. --token-ink is themed (dark by default;
      // per-theme tokens.css overrides it so light themes can still
      // hit the cream disc with a dark glyph).
      const pi = prefixInfo(tk.prefix);
      ctx.fillStyle = cssVar('--token-ink') || '#1A1730';
      ctx.font = `700 11px ${cssVar('--font-sans')}`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(pi.glyph, x, y + 1);

      // Coalesce badge (e.g. "x3") if the token represents >1.
      if (tk.count > 1) {
        ctx.fillStyle = tint;
        ctx.font = `700 10px ${cssVar('--font-sans')}`;
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
        ctx.fillText('×' + tk.count, x + TOKEN_RADIUS_PX + 2, y);
      }

      // Arrowhead at the leading edge for a paused-screenshot direction cue.
      const angle = Math.atan2(by - ay, bx - ax);
      const hx = x + Math.cos(angle) * (TOKEN_RADIUS_PX + 4);
      const hy = y + Math.sin(angle) * (TOKEN_RADIUS_PX + 4);
      ctx.fillStyle = withAlpha(tint, 0.95);
      ctx.beginPath();
      ctx.moveTo(hx, hy);
      ctx.lineTo(hx - 5 * Math.cos(angle - 0.4),
                 hy - 5 * Math.sin(angle - 0.4));
      ctx.lineTo(hx - 5 * Math.cos(angle + 0.4),
                 hy - 5 * Math.sin(angle + 0.4));
      ctx.closePath();
      ctx.fill();
    }
    this.tokens = survivors;

    // Drain pending queues: for every (from→to) edge whose in-flight slot
    // just freed (no surviving token), launch the next queued token. This
    // produces the steady "stream" the master spec asks for instead of a
    // simultaneous burst.
    if (justLanded.length && this.pending.size) {
      const liveKeys = new Set();
      for (const tk of survivors) liveKeys.add(this._dirKey(tk.from, tk.to));
      for (const tk of justLanded) {
        const key = this._dirKey(tk.from, tk.to);
        if (liveKeys.has(key)) continue;
        const q = this.pending.get(key);
        if (!q || !q.length) continue;
        const head = q.shift();
        if (!q.length) this.pending.delete(key);
        this._launchToken(head.from, head.to, head.prefix, now,
                          head.synthetic, head.msgId, head.bodyLen);
        // Carry the queued ×N badge onto the freshly launched token.
        const justSpawned = this.tokens[this.tokens.length - 1];
        if (justSpawned && head.count > 1) justSpawned.count = head.count;
      }
    }
  }

  // ------------------------------------------------------------------ U7 question trails

  _drawQuestionTrails(now) {
    const ctx = this.ctx;
    const dashStr = (cssVar('--question-trail-dash') || '6 4').trim();
    const dash = dashStr.split(/[\s,]+/).map((s) => parseFloat(s) || 0)
                        .filter((n) => n > 0);
    if (!dash.length) dash.push(6, 4);
    const baseAlpha = parseFloat(cssVar('--question-trail-alpha')) || 0.25;
    const chipAlpha = parseFloat(cssVar('--question-chip-alpha')) || 0.6;
    const ink = cssVar('--token-ink') || '#1A1730';
    // U7-f2 (design/u7-token-info-layer.md §4.c): the trail and chip read
    // dedicated colour tokens, falling back to --edge-question on the dark
    // themes that don't override them, plus an optional silhouette stroke.
    // The stroke tokens are transparent / 0-width on the 8 dark themes, so
    // the silhouette pass is skipped there and the trail renders exactly as
    // before; ghibli-watercolor enables a 1px --text outline for WCAG-AA.
    // asHex guards against browsers that leave var() unresolved on a custom
    // property (an unresolved "var(--x)" string is invalid as a canvas style).
    const edgeQ = cssVar('--edge-question') || '#F5C46A';
    const textInk = cssVar('--text') || '#EDEAD8';
    const asHex = (v, fb) => (v && v.charAt(0) === '#') ? v : fb;
    const trailColor   = asHex(cssVar('--question-trail-color'), edgeQ);
    const chipColor    = asHex(cssVar('--question-chip-color'), edgeQ);
    const trailStroke  = asHex(cssVar('--question-trail-stroke'), textInk);
    const trailStrokeW = parseFloat(cssVar('--question-trail-stroke-width')) || 0;
    const chipStroke   = asHex(cssVar('--question-chip-stroke'), textInk);
    const chipStrokeW  = parseFloat(cssVar('--question-chip-stroke-width')) || 0;

    const drawOne = (q, alphaScale, pair, idxInPair, count) => {
      const A = this.layout.get(q.from);
      const B = this.layout.get(q.to);
      if (!A || !B) return;
      const laneSign = (q.from < q.to) ? 1 : -1;
      const lane = laneSign * (QUESTION_LANE_PX + idxInPair * QUESTION_LANE_PX);
      const [ax, ay, bx, by] = laneEndpoints(A, B, lane);
      ctx.save();
      if (this.reducedMotion) {
        ctx.setLineDash([]);                  // solid line
      } else {
        ctx.setLineDash(dash);
      }
      // Silhouette pass underneath (ghibli only; trailStrokeW is 0 on the
      // dark themes, so this block is skipped and they render unchanged).
      // Drawn opaque (alphaScale only, no baseAlpha) even though the fill
      // keeps the 0.55 trail alpha — the silhouette is the load-bearing
      // WCAG-AA contrast layer per design §4.c.
      if (trailStrokeW > 0) {
        ctx.strokeStyle = withAlpha(trailStroke, alphaScale);
        ctx.lineWidth = trailStrokeW;             // 1px --text outline
        ctx.beginPath();
        ctx.moveTo(ax, ay);
        ctx.lineTo(bx, by);
        ctx.stroke();
      }
      // Fill pass, centred on top: a thin ochre core (half the silhouette
      // width, i.e. 0.5px) when a silhouette is present, otherwise the
      // original 1.5px solid trail used by the 8 dark themes.
      ctx.strokeStyle = withAlpha(trailColor, baseAlpha * alphaScale);
      ctx.lineWidth = trailStrokeW > 0 ? trailStrokeW * 0.5 : 1.5;
      ctx.beginPath();
      ctx.moveTo(ax, ay);
      ctx.lineTo(bx, by);
      ctx.stroke();
      ctx.restore();

      // ? chip near the receiver. Stacks N visible chips; the 4th and
      // later aggregate as ?×N on the topmost chip.
      if (idxInPair < QUESTION_VISIBLE_PER_PAIR) {
        const chipR = 9;
        const ratio = 0.92;
        const cx = ax + (bx - ax) * ratio;
        const cy = ay + (by - ay) * ratio;
        ctx.save();
        ctx.beginPath();
        ctx.arc(cx, cy, chipR, 0, 2 * Math.PI);
        ctx.fillStyle = withAlpha(chipColor, chipAlpha * alphaScale);
        ctx.fill();
        // Chip border silhouette (ghibli only; chipStrokeW is 0 on dark).
        if (chipStrokeW > 0) {
          ctx.lineWidth = chipStrokeW;
          ctx.strokeStyle = withAlpha(chipStroke, alphaScale);
          ctx.stroke();
        }
        ctx.fillStyle = withAlpha(ink, alphaScale);
        ctx.font = `800 12px ${cssVar('--font-sans')}`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        const label = (count > QUESTION_VISIBLE_PER_PAIR && idxInPair === 0)
          ? `?×${count}` : '?';
        ctx.fillText(label, cx, cy + 1);
        ctx.restore();
      }
    };

    // Live open questions: solid alphaScale = 1.
    for (const [key, list] of this.openQuestions) {
      if (key.endsWith(':fade')) continue;
      for (let i = 0; i < list.length; i++) {
        drawOne(list[i], 1.0, key, i, list.length);
      }
    }
    // Fade-out queue: alphaScale linearly drops 1 → 0 across QUESTION_FADE_MS.
    for (const [key, list] of this.openQuestions) {
      if (!key.endsWith(':fade')) continue;
      for (let i = 0; i < list.length; i++) {
        const age = now - list[i].fadeOutAt;
        if (age >= QUESTION_FADE_MS) continue;
        const k = 1 - (age / QUESTION_FADE_MS);
        drawOne(list[i], this.reducedMotion ? (age < 200 ? k : 0) : k,
                key, i, list.length);
      }
    }
  }

  // ------------------------------------------------------------------ U7 hover popover

  _updatePopover(now) {
    const el = this._popoverElement();
    if (!el) return;
    const target = this._hoverAt(this._lastPointer);
    // u7-f3: compare the STABLE underlying token, not the wrapper. _hoverAt
    // returns a fresh `{kind,token}` object every frame, so the old
    // wrapper-reference comparison was always true while hovering one token,
    // restarting the dwell timer each frame and never reaching
    // POPOVER_DWELL_MS. The token object reference is stable across frames.
    if (target && target.token !== this.popoverTarget?.token) {
      this.popoverTarget = target;
      this.popoverDwellFrom = now;
      el.hidden = true;
      return;
    }
    if (!target) {
      // Grace period so the cursor can slip momentarily off the disc.
      if (this.popoverTarget &&
          (now - (this.popoverHideAfter || 0)) > POPOVER_HIT_GRACE_MS) {
        this.popoverTarget = null;
        this._hidePopover();
      }
      return;
    }
    this.popoverHideAfter = now;
    if ((now - this.popoverDwellFrom) >= POPOVER_DWELL_MS) {
      this._showPopover(target);
    }
  }

  _popoverElement() {
    if (!this.popoverEl) {
      this.popoverEl = document.getElementById('token-popover');
      if (this.popoverEl) {
        // Hide on click outside; Esc dismisses too.
        document.addEventListener('keydown', (e) => {
          if (e.key === 'Escape' && this.popoverTarget) {
            e.preventDefault();
            this.popoverTarget = null;
            this._hidePopover();
          }
        });
        // Cache the pointer in canvas-space coords for hit-testing.
        this._lastPointer = null;
        const captureMove = (e) => {
          const rect = this.canvas.getBoundingClientRect();
          this._lastPointer = {
            x: e.clientX - rect.left,
            y: e.clientY - rect.top,
            client: { x: e.clientX, y: e.clientY },
          };
        };
        const clearPointer = () => { this._lastPointer = null; };
        this.canvas.addEventListener('mousemove', captureMove);
        this.overlay.addEventListener('mousemove', captureMove);
        this.canvas.addEventListener('mouseleave', clearPointer);
      }
    }
    return this.popoverEl;
  }

  _hoverAt(pt) {
    if (!pt) return null;
    // Token hit: nearest in-flight token within TOKEN_RADIUS_PX + halo.
    for (const tk of this.tokens) {
      if (tk._x == null) continue;
      const r = TOKEN_RADIUS_PX + (tk._haloR || 0) + 2;
      if (Math.hypot(pt.x - tk._x, pt.y - tk._y) <= r) return { kind: 'token', token: tk };
    }
    return null;
  }

  _showPopover(target) {
    const el = this.popoverEl;
    if (!el) return;
    const pt = this._lastPointer;
    if (!pt) return;
    const tk = target.token;
    const pi = prefixInfo(tk.prefix);
    const setT = (id, v) => { const e = document.getElementById(id); if (e) e.textContent = v; };
    setT('token-popover-prefix', pi.glyph);
    setT('token-popover-pair',   `${tk.from} → ${tk.to}`);
    // Times: render the relative age if we know the spawn frame; the
    // absolute ts is not in the canvas record, so the spec's second-level
    // tooltip is a follow-up (logged in u7-f1 if surfacing is wanted).
    const ageMs = performance.now() - tk.spawn;
    setT('token-popover-ts', `${(ageMs / 1000).toFixed(1)}s ago`);
    const body = document.getElementById('token-popover-body');
    if (body) {
      const m = tk.msgId ? this._messagesById.get(tk.msgId) : null;
      const text = (m && (m.body_preview || m.body)) || '(message body not in payload; open the role feed for full text)';
      body.textContent = String(text).slice(0, 800);
    }
    el.style.left = (pt.client.x + 12) + 'px';
    el.style.top  = (pt.client.y +  8) + 'px';
    el.removeAttribute('hidden');
    el.setAttribute('aria-hidden', 'false');
    // Viewport clamp.
    const r = el.getBoundingClientRect();
    if (r.right > window.innerWidth - 8) {
      el.style.left = (window.innerWidth - r.width - 8) + 'px';
    }
    if (r.bottom > window.innerHeight - 8) {
      el.style.top = (window.innerHeight - r.height - 8) + 'px';
    }
  }

  _hidePopover() {
    if (!this.popoverEl) return;
    this.popoverEl.setAttribute('hidden', '');
    this.popoverEl.setAttribute('aria-hidden', 'true');
  }

  // Resting-state mascot: when no token has landed for REST_MASCOT_AFTER_MS
  // and the roster is non-empty, fade the active theme's mascot in behind
  // the swarm at 20 % opacity ("the swarm is resting"). Hidden as soon as
  // traffic resumes.
  _drawRestingMascot(now) {
    if (!this.roster.length) return;
    if (this.tokens.length || this.traces.length) return;
    if (now - this.lastTokenLandedAt < REST_MASCOT_AFTER_MS) return;
    const theme = activeTheme();
    if (!theme) return;
    const url = `/static/themes/${encodeURIComponent(theme)}/mascot.png`;
    const img = loadImage(url);
    if (!img.complete || !img.naturalWidth) return;
    const ctx = this.ctx;
    const cx = this.canvasW / 2;
    const cy = this.canvasH / 2;
    const size = Math.min(220, Math.min(this.canvasW, this.canvasH) * 0.32);
    ctx.save();
    ctx.globalAlpha = 0.20;
    ctx.drawImage(img, cx - size / 2, cy - size / 2, size, size);
    ctx.restore();
  }
}

// Compute lane-shifted endpoints: shifts the straight (from→to) segment by
// laneOffset perpendicular pixels, and also pulls back from each node's edge
// so the token doesn't draw inside the disc.
function laneEndpoints(A, B, laneOffset) {
  const dx = B.x - A.x;
  const dy = B.y - A.y;
  const len = Math.hypot(dx, dy) || 1;
  const ux = dx / len;
  const uy = dy / len;
  // Perpendicular (rotate +90°).
  const px = -uy;
  const py = ux;
  // Pull back from each disc edge.
  const ax = A.x + ux * A.baseR + px * laneOffset;
  const ay = A.y + uy * A.baseR + py * laneOffset;
  const bx = B.x - ux * B.baseR + px * laneOffset;
  const by = B.y - uy * B.baseR + py * laneOffset;
  return [ax, ay, bx, by];
}

function drawStateRing(ctx, R, state, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = RING_THICK_PX;
  switch (state) {
    case 'idle':
      ctx.globalAlpha *= 0.6;
      ctx.setLineDash([]);
      break;
    case 'question':
      ctx.setLineDash([8, 6]);
      break;
    case 'stalled-api':
      // outer dashed thin ring + inner solid
      ctx.setLineDash([]);
      ctx.beginPath();
      ctx.arc(0, 0, R, 0, 2 * Math.PI);
      ctx.stroke();
      ctx.setLineDash([3, 3]);
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(0, 0, R + 5, 0, 2 * Math.PI);
      ctx.stroke();
      ctx.setLineDash([]);
      return;
    case 'give-up':
      ctx.lineWidth = RING_THICK_PX + 2;
      ctx.setLineDash([]);
      break;
    case 'dead':
      ctx.globalAlpha *= 0.4;
      ctx.setLineDash([2, 4]);
      break;
    case 'paused':
    case 'active':
    default:
      ctx.setLineDash([]);
      break;
  }
  ctx.beginPath();
  ctx.arc(0, 0, R, 0, 2 * Math.PI);
  ctx.stroke();
  ctx.setLineDash([]);
}

function phase(now, periodMs, offsetRad) {
  return ((now / periodMs) + offsetRad / (2 * Math.PI)) % 1;
}

// CSS-attribute-selector-safe role name escaping. Role names are constrained
// by ROLE_NAME_RE (^[a-z0-9][a-z0-9-]{0,39}$) so a plain pass is safe, but
// CSS.escape protects against unexpected widening of the validator.
function cssEsc(s) {
  if (window.CSS && CSS.escape) return CSS.escape(s);
  return String(s).replace(/[^a-z0-9\-]/gi, '_');
}
