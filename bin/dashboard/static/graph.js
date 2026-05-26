// u5-frontend: fixed-radial swarm renderer.
// Vanilla canvas + requestAnimationFrame, with absolutely-positioned DOM
// labels and per-role transparent button overlays. State and motion
// vocabulary lives in glyphs.js; the values in tokens.css. Layout follows
// visual-spec.md section 4 (radial, deterministic from sorted roster).

import {
  assetForRole, prefixInfo,
  STATE_COLOR_VAR, STATE_BADGE,
  cssVar, withAlpha,
} from './glyphs.js';

const TOKEN_RADIUS_PX     = 9;        // half of --token-size 14 + extra for glyph
const TOKEN_LANE_PX       = 6;        // --lane-offset
const TOKEN_DUR_MIN_MS    = 600;
const TOKEN_DUR_MAX_MS    = 900;
const TRACE_DECAY_MS      = 6000;     // --motion-trace-decay
const COALESCE_CAP        = 5;        // max simultaneous tokens per pair-dir
const FLASH_DUR_MS        = 200;
const HALO_LINGER_MS      = 200;      // halo lingers briefly after token lands
const RING_THICK_PX       = 3;
const SELECT_RING_PX      = 3;
const SEEN_MSG_LIMIT      = 2000;

// Image cache: name → HTMLImageElement (loaded async, drawn when ready).
const imageCache = new Map();
function loadImage(url) {
  if (imageCache.has(url)) return imageCache.get(url);
  const img = new Image();
  img.src = url;
  imageCache.set(url, img);
  return img;
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
    this.nodeRuntime = new Map();  // name → { phase0, lastFlashAt, lastTokenLandAt }
    this.tokens = [];          // in-flight tokens
    this.traces = [];          // decaying traces
    this.seenMsgIds = new Set();
    this.selectedRole = null;

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
      const labelOffsetY = pos.baseR + 14;
      label.style.left = pos.x + 'px';
      label.style.top  = (pos.y + labelOffsetY) + 'px';
      const hitSize = (pos.baseR * 2) + 14;
      button.style.left = (pos.x - hitSize / 2) + 'px';
      button.style.top  = (pos.y - hitSize / 2) + 'px';
      button.style.width  = hitSize + 'px';
      button.style.height = hitSize + 'px';
    }
  }

  _labelEl(name) {
    return this.overlay.querySelector(`[data-role-label="${cssEsc(name)}"]`);
  }

  _buttonEl(name) {
    return this.overlay.querySelector(`button[data-role="${cssEsc(name)}"]`);
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

    // Sync DOM children: add/remove role label + button.
    const wanted = new Set(roster.map(r => r.name));
    for (const child of [...this.overlay.children]) {
      const name = child.dataset.role || child.dataset.roleLabel;
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
      if (this.selectedRole === r.name) btn.dataset.selected = 'true';
      else delete btn.dataset.selected;

      // Spawn runtime entry for new nodes; preserve phase if already there.
      if (!this.nodeRuntime.has(r.name)) {
        this.nodeRuntime.set(r.name, {
          phase0: Math.random() * Math.PI * 2,
          flashUntil: 0,
          flashScale: 1.0,
          haloUntil: 0,
        });
      }
    }

    // Recompute layout if topology changed (size or set differs).
    this._recomputeLayout();
    this._syncOverlayPositions();

    // Ingest new messages → spawn tokens.
    for (const m of (snap.messages || [])) {
      if (!m || !m.id || this.seenMsgIds.has(m.id)) continue;
      this.seenMsgIds.add(m.id);
      if (m.kind === 'broadcast') {
        // Don't crowd the canvas with N tokens; sender flashes its halo.
        this._kickHalo(m.from, now);
        continue;
      }
      if (!m.from || !m.to) continue;
      if (!this.layout.has(m.from) || !this.layout.has(m.to)) continue;
      this._spawnToken(m.from, m.to, m.prefix || 'other', now);
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

  // ------------------------------------------------------------------ tokens

  _spawnToken(from, to, prefix, now) {
    // Lane offset: A→B uses +1, B→A uses -1, deterministic from name compare.
    const laneSign = (from < to) ? 1 : -1;
    // Coalesce: count in-flight tokens for this exact (from,to) pair.
    const inflight = this.tokens.filter(
      t => t.from === from && t.to === to);
    if (inflight.length >= COALESCE_CAP) {
      const last = inflight[inflight.length - 1];
      last.count += 1;
      return;
    }
    // Stagger 120 ms behind the most recent on the same pair.
    let stagger = 0;
    if (inflight.length) {
      const lastSpawn = inflight[inflight.length - 1].spawn;
      stagger = Math.max(0, (lastSpawn + 120) - now);
    }
    // Edge length determines duration (linearly between MIN and MAX).
    const A = this.layout.get(from);
    const B = this.layout.get(to);
    const d = Math.hypot(B.x - A.x, B.y - A.y);
    const tau = Math.min(1, d / 720);
    const dur = TOKEN_DUR_MIN_MS + (TOKEN_DUR_MAX_MS - TOKEN_DUR_MIN_MS) * tau;
    this.tokens.push({
      from, to, prefix,
      spawn: now + stagger,
      dur,
      laneSign,
      count: 1,
    });
    this._kickHalo(from, now);
    this._kickHalo(to, now);
  }

  _kickHalo(name, now) {
    const rt = this.nodeRuntime.get(name);
    if (!rt) return;
    rt.haloUntil = Math.max(rt.haloUntil, now + TOKEN_DUR_MAX_MS + HALO_LINGER_MS);
  }

  // ------------------------------------------------------------------ render

  _tick() {
    const now = performance.now();
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.canvasW, this.canvasH);

    // Background grid? Spec doesn't call for one; skip.
    this._drawEdges(now);
    this._drawTraces(now);
    this._drawNodes(now);
    this._drawTokens(now);

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

      // 4) Role glyph image (60% of disc).
      const imgUrl = assetForRole(r.name);
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

      // 7) Selection ring.
      if (this.selectedRole === r.name) {
        ctx.beginPath();
        ctx.arc(0, 0, R + 7, 0, 2 * Math.PI);
        const ringCol = cssVar('--select-ring') || '#FFF5DD';
        const ringA = parseFloat(cssVar('--select-ring-opacity') || '0.85');
        ctx.strokeStyle = withAlpha(ringCol, ringA);
        ctx.lineWidth = SELECT_RING_PX;
        ctx.stroke();
      }

      ctx.restore();
    }
  }

  _drawTokens(now) {
    const ctx = this.ctx;
    const survivors = [];
    for (const tk of this.tokens) {
      if (now < tk.spawn) { survivors.push(tk); continue; }
      const age = now - tk.spawn;
      if (age >= tk.dur) {
        // Token landed: convert to a trace, flash receiver, kick halo.
        this.traces.push({
          from: tk.from, to: tk.to, prefix: tk.prefix,
          t0: now, laneSign: tk.laneSign,
        });
        const rxRt = this.nodeRuntime.get(tk.to);
        if (rxRt) {
          rxRt.flashUntil = now + FLASH_DUR_MS;
          rxRt.flashScale = (tk.to === 'orchestrator') ? 1.12 : 1.08;
          rxRt.haloUntil = Math.max(rxRt.haloUntil, now + HALO_LINGER_MS);
        }
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

      // Glyph centred on disc.
      const pi = prefixInfo(tk.prefix);
      ctx.fillStyle = '#1A1730';
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
