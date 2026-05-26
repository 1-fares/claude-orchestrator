// Graph rendering on top of vasturiano/force-graph (UMD global `ForceGraph`).
//
// Responsibilities:
//   - Maintain a stable node set keyed by role name; new nodes ease in, removed
//     nodes ease out.
//   - Maintain an edge ring driven from server-emitted messages, each with
//     spawned-at time. Edges fade and drop after EDGE_LIFETIME_MS.
//   - Draw nodes with state color, halo, pulse/blink, role glyph and label
//     using direct canvas hooks so we match the u3 spec.
//
// The module exposes a singleton GraphView with `update(state, now)` and
// `tooltipFor(node)` for the app layer.

import {
  glyphForRole, STATE_COLOR_VAR, EDGE_COLOR_VAR, PREFIX_SHORT,
  cssVar, withAlpha,
} from './glyphs.js';

const EDGE_LIFETIME_MS = 6000;
const EDGE_HOLD_MS     = 1500;     // full opacity window
const NODE_BASE_R      = 14;
const NODE_ORCH_R      = 20;
const MAX_EDGES        = 40;

export class GraphView {
  constructor(container, onNodeHover, onNodeOut) {
    this.container = container;
    this.onNodeHover = onNodeHover;
    this.onNodeOut = onNodeOut;
    this.nodes = new Map();   // name → node obj (mutable, force-graph references stable)
    this.edgeRing = [];       // {id, from, to, prefix, t0, source, target}
    this.seenMsgIds = new Set();
    this.lastSnapshotNowTs = 0;
    this.lastSnapshotRecvAt = performance.now();
    this.broadcastSeen = new Set();
    this._initGraph();
    this._animLoop();
  }

  _initGraph() {
    const g = ForceGraph()(this.container)
      .backgroundColor('rgba(0,0,0,0)')
      .nodeId('id')
      .nodeRelSize(1)
      .nodeVal(n => (n.is_orch ? NODE_ORCH_R * NODE_ORCH_R
                                : (n.radius * n.radius)))
      .nodeLabel(() => '')   // we use custom tooltip
      .linkSource('source')
      .linkTarget('target')
      .linkDirectionalArrowLength(7)
      .linkDirectionalArrowRelPos(0.92)
      .linkDirectionalArrowColor(l => this._edgeColor(l, this._edgeAlpha(l)))
      .linkColor(l => this._edgeColor(l, this._edgeAlpha(l)))
      .linkCurvature(l => l.curvature || 0)
      .linkWidth(l => this._edgeWidth(l))
      .linkCanvasObjectMode(() => 'after')
      .linkCanvasObject((l, ctx, scale) => this._drawEdgeLabel(l, ctx, scale))
      .nodeCanvasObject((n, ctx, scale) => this._drawNode(n, ctx, scale))
      .nodePointerAreaPaint((n, color, ctx) => {
        const r = (n.is_orch ? NODE_ORCH_R : n.radius) + 4;
        ctx.fillStyle = color;
        ctx.beginPath();
        ctx.arc(n.x, n.y, r, 0, 2 * Math.PI);
        ctx.fill();
      })
      .onNodeHover(n => {
        this.container.style.cursor = 'default';
        if (n) this.onNodeHover(n);
        else   this.onNodeOut();
      })
      .enableNodeDrag(false)
      .enableZoomInteraction(true)
      .enablePanInteraction(true)
      .onEngineStop(() => {
        if (!this._fittedOnce) {
          this.fg.zoomToFit(400, 40);
          this._fittedOnce = true;
        }
      })
      .cooldownTime(15000)
      .d3VelocityDecay(0.35)
      .warmupTicks(20);

    // Slightly looser repulsion + a centering force pinning the orchestrator.
    g.d3Force('charge').strength(-340);
    g.d3Force('link').distance(110);
    g.d3Force('center', null);  // we pin orchestrator instead

    this.fg = g;
    this._resize();
    window.addEventListener('resize', () => this._resize());
  }

  _resize() {
    const rect = this.container.getBoundingClientRect();
    this.fg.width(rect.width).height(rect.height);
    if (this._fittedOnce) {
      this.fg.zoomToFit(200, 40);
    }
  }

  _edgeAlpha(l) {
    const now = performance.now();
    const age = now - l.t0;
    if (age <= EDGE_HOLD_MS) return 0.95;
    if (age >= EDGE_LIFETIME_MS) return 0;
    const t = (age - EDGE_HOLD_MS) / (EDGE_LIFETIME_MS - EDGE_HOLD_MS);
    return 0.95 * (1 - t);
  }

  _edgeColor(l, alpha) {
    const cssName = EDGE_COLOR_VAR[l.prefix] || EDGE_COLOR_VAR.other;
    const hex = cssVar(cssName);
    return withAlpha(hex, alpha);
  }

  _edgeWidth(l) {
    if (l.prefix === 'priority') return 2.5;
    if (l.prefix === 'done' || l.prefix === 'question') return 1.75;
    return 1.25;
  }

  _drawEdgeLabel(l, ctx, scale) {
    const alpha = this._edgeAlpha(l);
    if (alpha < 0.05) return;
    const tag = PREFIX_SHORT[l.prefix] || '';
    if (!tag) return;
    if (typeof l.source !== 'object' || typeof l.target !== 'object') return;
    const mx = (l.source.x + l.target.x) / 2;
    const my = (l.source.y + l.target.y) / 2;
    ctx.font = `500 ${11 / scale}px ui-monospace, SF Mono, Menlo, monospace`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.lineWidth = 3 / scale;
    ctx.strokeStyle = cssVar('--bg');
    ctx.strokeText(tag, mx, my);
    ctx.fillStyle = withAlpha(cssVar(EDGE_COLOR_VAR[l.prefix] || EDGE_COLOR_VAR.other), Math.min(1, alpha + 0.1));
    ctx.fillText(tag, mx, my);
  }

  _drawNode(n, ctx, scale) {
    const r = (n.is_orch ? NODE_ORCH_R : n.radius);
    const color = cssVar(STATE_COLOR_VAR[n.state] || STATE_COLOR_VAR.idle);

    const now = performance.now();
    // appear/disappear easing
    const appearT = Math.min(1, (now - n.t_appear) / 400);
    const aliveScale = n.dying
      ? Math.max(0, 1 - (now - n.t_die) / 400)
      : appearT;
    const drawR = r * (0.4 + 0.6 * aliveScale);
    const baseAlpha = aliveScale * (n.state === 'paused' ? 0.7 : 1.0);

    // Pulse / blink modifiers
    let haloAlpha = 0.35;
    let haloR = drawR + 4;
    if (n.state === 'active') {
      const phase = (now % 1400) / 1400;
      const t = 0.5 - 0.5 * Math.cos(phase * 2 * Math.PI);
      haloAlpha = 0.25 + 0.45 * t;
      haloR = drawR + 4 + 2 * t;
    } else if (n.state === 'give-up') {
      const phase = (now % 2000) / 2000;
      const t = 0.5 - 0.5 * Math.cos(phase * 2 * Math.PI);
      ctx.globalAlpha = (0.55 + 0.45 * t) * baseAlpha;
    } else if (n.state === 'stalled-api') {
      haloAlpha = 0.6;
    } else if (n.state === 'orchestrator') {
      haloAlpha = 0.35;
      haloR = drawR + 6;
    }

    // Halo (drawn first, underneath)
    ctx.beginPath();
    ctx.arc(n.x, n.y, haloR, 0, 2 * Math.PI);
    ctx.strokeStyle = withAlpha(color, haloAlpha * baseAlpha);
    ctx.lineWidth = (n.is_orch ? 3 : 2);
    if (n.state === 'paused') ctx.setLineDash([4, 3]);
    else if (n.state === 'stalled-api') ctx.setLineDash([3, 4]);
    else ctx.setLineDash([]);
    ctx.stroke();
    ctx.setLineDash([]);

    // Fill (skip for plain idle — render hollow ring)
    if (n.state === 'idle' || n.state === 'paused') {
      ctx.beginPath();
      ctx.arc(n.x, n.y, drawR, 0, 2 * Math.PI);
      ctx.strokeStyle = withAlpha(color, baseAlpha);
      ctx.lineWidth = 2;
      if (n.state === 'paused') ctx.setLineDash([4, 3]);
      ctx.stroke();
      ctx.setLineDash([]);
    } else {
      ctx.beginPath();
      ctx.arc(n.x, n.y, drawR, 0, 2 * Math.PI);
      ctx.fillStyle = withAlpha(color, baseAlpha);
      ctx.fill();
    }

    // Glyph badges for question / give-up
    if (n.state === 'question') {
      ctx.font = `700 ${drawR * 1.1}px ${cssVar('--font-mono') || 'monospace'}`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = cssVar('--bg');
      ctx.fillText('?', n.x, n.y + 1);
    } else if (n.state === 'give-up') {
      ctx.strokeStyle = cssVar('--bg');
      ctx.lineWidth = 2.5;
      ctx.beginPath();
      ctx.moveTo(n.x - drawR * 0.55, n.y - drawR * 0.55);
      ctx.lineTo(n.x + drawR * 0.55, n.y + drawR * 0.55);
      ctx.moveTo(n.x + drawR * 0.55, n.y - drawR * 0.55);
      ctx.lineTo(n.x - drawR * 0.55, n.y + drawR * 0.55);
      ctx.stroke();
    } else if (n.is_orch) {
      ctx.font = `600 ${drawR * 1.0}px ${cssVar('--font-mono') || 'monospace'}`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = cssVar('--bg');
      ctx.fillText('◆', n.x, n.y + 1);
    } else if (drawR >= 13) {
      // small role glyph inside
      ctx.font = `500 ${drawR * 0.9}px ui-monospace, monospace`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = withAlpha(cssVar('--bg'), 0.85 * baseAlpha);
      if (n.state === 'idle' || n.state === 'paused') {
        ctx.fillStyle = withAlpha(color, baseAlpha);
      }
      ctx.fillText(glyphForRole(n.id), n.x, n.y + 1);
    }

    // Label
    ctx.globalAlpha = baseAlpha;
    ctx.font = `500 11px ui-monospace, monospace`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.lineWidth = 3;
    ctx.strokeStyle = cssVar('--bg');
    ctx.strokeText(n.id, n.x, n.y + drawR + 6);
    ctx.fillStyle = cssVar('--text');
    ctx.fillText(n.id, n.x, n.y + drawR + 6);
    ctx.globalAlpha = 1;
  }

  _animLoop() {
    const tick = () => {
      // Drop expired edges and any over the cap (oldest first).
      const now = performance.now();
      const live = this.edgeRing.filter(e => (now - e.t0) < EDGE_LIFETIME_MS);
      if (live.length !== this.edgeRing.length || this._needsLinkSync) {
        this.edgeRing = live.slice(-MAX_EDGES);
        this._needsLinkSync = false;
        this.fg.graphData({
          nodes: Array.from(this.nodes.values()),
          links: this.edgeRing,
        });
      }
      // Drop nodes whose death animation finished.
      let removedAny = false;
      for (const [name, n] of this.nodes) {
        if (n.dying && (now - n.t_die) > 450) {
          this.nodes.delete(name);
          removedAny = true;
        }
      }
      if (removedAny) {
        this.fg.graphData({
          nodes: Array.from(this.nodes.values()),
          links: this.edgeRing,
        });
      }
      // Force a redraw each frame so pulses / fades animate.
      this.fg.refresh && this.fg.refresh();
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  /**
   * Apply a new state snapshot. The graph reconciles in place.
   */
  update(state, snapshotRecvAt) {
    this.lastSnapshotNowTs = state.now_ts;
    this.lastSnapshotRecvAt = snapshotRecvAt;

    const wantNames = new Set();
    const orchPresent = state.roster.some(r => r.is_orchestrator);

    // Ensure orchestrator is always at the centre even if server didn't.
    // (server.py already synthesises it, but be defensive)
    const roster = state.roster.slice();
    if (!orchPresent && roster.length > 0) {
      roster.push({
        name: 'orchestrator', role_base: 'orchestrator',
        is_orchestrator: true, state: 'orchestrator',
        counts: { sent_1m: 0, recv_1m: 0, sent_total: 0, recv_total: 0 },
        health: null,
      });
    }

    let topoChanged = false;
    const t = performance.now();

    for (const r of roster) {
      wantNames.add(r.name);
      let n = this.nodes.get(r.name);
      if (!n) {
        n = {
          id: r.name,
          is_orch: !!r.is_orchestrator,
          state: r.state,
          radius: NODE_BASE_R,
          role_base: r.role_base,
          health: r.health,
          counts: r.counts,
          last_msg_ts: r.last_msg_ts,
          last_msg_prefix: r.last_msg_prefix,
          state_source: r.state_source,
          state_age_sec: r.state_age_sec,
          open_question_ids: r.open_question_ids || [],
          t_appear: t,
        };
        if (n.is_orch) {
          n.fx = 0;
          n.fy = 0;
        }
        this.nodes.set(r.name, n);
        topoChanged = true;
      } else {
        // Update in place to preserve x/y/vx/vy (no relayout jitter).
        n.state = r.state;
        n.health = r.health;
        n.counts = r.counts;
        n.last_msg_ts = r.last_msg_ts;
        n.last_msg_prefix = r.last_msg_prefix;
        n.state_source = r.state_source;
        n.state_age_sec = r.state_age_sec;
        n.open_question_ids = r.open_question_ids || [];
        n.dying = false;
      }
    }

    // Mark missing nodes for death animation (drop after 450ms).
    for (const [name, n] of this.nodes) {
      if (!wantNames.has(name) && !n.dying) {
        n.dying = true;
        n.t_die = t;
        topoChanged = true;
      }
    }

    // Scale node radii inversely with team size so large teams still fit.
    const liveCount = Math.max(1, [...this.nodes.values()].filter(n => !n.dying).length);
    const scale = Math.min(1.0, 6 / Math.max(4, liveCount));
    for (const n of this.nodes.values()) {
      n.radius = NODE_BASE_R * (0.85 + 0.5 * scale);
    }

    // Ingest new messages → edges.
    let newEdges = false;
    const broadcastCounts = new Map();
    for (const m of (state.messages || [])) {
      if (!m.from) continue;
      if (m.kind === 'broadcast') {
        // Render as short stubs to each fanout target; cap by edge ring policy.
        const key = m.id;
        if (this.broadcastSeen.has(key)) continue;
        this.broadcastSeen.add(key);
        const targets = m.broadcast_fanout || [];
        broadcastCounts.set(key, targets.length);
        for (const tgt of targets) {
          if (!this.nodes.has(tgt) || tgt === m.from) continue;
          this._addEdge({
            id: `${m.id}-${tgt}`,
            from: m.from, to: tgt,
            prefix: m.prefix || 'other',
            t0: performance.now(),
            broadcast: true,
          });
          newEdges = true;
        }
        continue;
      }
      if (!m.to) continue;
      if (this.seenMsgIds.has(m.id)) continue;
      this.seenMsgIds.add(m.id);
      this._addEdge({
        id: m.id, from: m.from, to: m.to,
        prefix: m.prefix || 'other',
        t0: performance.now(),
      });
      newEdges = true;
    }
    // Bound the seen-id set so we don't leak.
    if (this.seenMsgIds.size > 2000) {
      const arr = [...this.seenMsgIds];
      this.seenMsgIds = new Set(arr.slice(-1000));
    }
    if (this.broadcastSeen.size > 1000) {
      const arr = [...this.broadcastSeen];
      this.broadcastSeen = new Set(arr.slice(-500));
    }

    if (topoChanged) {
      // Re-arm zoomToFit so the engine-stop after the new layout refits.
      this._fittedOnce = false;
    }

    if (newEdges || topoChanged) {
      // Cap edges
      this.edgeRing = this.edgeRing.slice(-MAX_EDGES);
      // Compute curvature for parallel edges.
      this._assignCurvature();
      // Resolve string endpoints to node refs.
      const links = this.edgeRing.map(e => ({
        ...e,
        source: e.from,
        target: e.to,
      }));
      this.fg.graphData({
        nodes: Array.from(this.nodes.values()),
        links,
      });
      this.edgeRing = links;
      this._needsLinkSync = false;
    }
  }

  _addEdge(e) {
    // Only add if endpoints currently exist as nodes (so force-graph doesn't
    // synthesise ghost nodes from string ids).
    if (!this.nodes.has(e.from) || !this.nodes.has(e.to)) return;
    this.edgeRing.push(e);
    if (this.edgeRing.length > MAX_EDGES) this.edgeRing.shift();
  }

  _assignCurvature() {
    // For pairs of nodes with multiple edges in either direction, alternate
    // curvature so they don't overlap.
    const buckets = new Map();
    for (const e of this.edgeRing) {
      const key = [e.from, e.to].sort().join('::');
      if (!buckets.has(key)) buckets.set(key, []);
      buckets.get(key).push(e);
    }
    for (const [, group] of buckets) {
      if (group.length === 1) {
        group[0].curvature = 0;
        continue;
      }
      group.forEach((e, i) => {
        // Alternate sign per direction so A→B and B→A bow opposite ways.
        const dirSign = e.from < e.to ? 1 : -1;
        e.curvature = dirSign * 0.12 * (1 + Math.floor(i / 2));
      });
    }
  }

  pinOrchestrator() {
    // Re-center the orchestrator on resize / load.
    for (const n of this.nodes.values()) {
      if (n.is_orch) {
        n.fx = 0;
        n.fy = 0;
      }
    }
  }
}
