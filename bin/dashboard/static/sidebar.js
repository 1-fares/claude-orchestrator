// Sidebar renderer: roster table, units bar, timeline.
import { glyphForRole, STATE_COLOR_VAR, cssVar, withAlpha } from './glyphs.js';

const UNIT_STATUS_COLORS = {
  todo:         '--text-dim',
  assigned:     '--node-idle',
  acked:        '--node-idle',
  'in-progress':'--node-active',
  blocked:      '--node-give-up',
  review:       '--node-question',
  integrating:  '--node-question',
  done:         '--node-active',
  deferred:     '--text-dim',
};

const UNIT_ORDER = ['todo','assigned','acked','in-progress','blocked','review','integrating','done','deferred'];

function fmtDuration(seconds) {
  if (!seconds || seconds < 0) return '00:00:00';
  const s = Math.floor(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return `${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:${String(sec).padStart(2,'0')}`;
}

function fmtTimelineTs(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  const h = String(d.getHours()).padStart(2,'0');
  const m = String(d.getMinutes()).padStart(2,'0');
  return `${h}:${m}`;
}

export class Sidebar {
  constructor(rootEl) {
    this.root = rootEl;
    this.root.innerHTML = `
      <section class="panel" id="roster-panel">
        <h2>Roster</h2>
        <div class="roster-list" id="roster-list"></div>
      </section>
      <section class="panel" id="units-panel">
        <h2>Units</h2>
        <div class="units-bar" id="units-bar"></div>
        <div class="units-legend" id="units-legend"></div>
      </section>
      <section class="panel" id="timeline-panel">
        <h2>Timeline</h2>
        <div class="timeline-list" id="timeline-list"></div>
      </section>
    `;
    this.rosterEl = this.root.querySelector('#roster-list');
    this.unitsBarEl = this.root.querySelector('#units-bar');
    this.unitsLegendEl = this.root.querySelector('#units-legend');
    this.timelineEl = this.root.querySelector('#timeline-list');
  }

  update(state) {
    this._renderRoster(state.roster || []);
    this._renderUnits((state.units && state.units.counts) || {});
    this._renderTimeline(state.timeline || []);
  }

  _renderRoster(roster) {
    // Stable order: orchestrator first, then alphabetical.
    const sorted = roster.slice().sort((a, b) => {
      if (a.is_orchestrator && !b.is_orchestrator) return -1;
      if (b.is_orchestrator && !a.is_orchestrator) return 1;
      return a.name.localeCompare(b.name);
    });
    const existing = new Map();
    for (const child of this.rosterEl.children) existing.set(child.dataset.name, child);
    const wantNames = new Set(sorted.map(r => r.name));

    // Remove gone
    for (const [name, el] of existing) {
      if (!wantNames.has(name)) el.remove();
    }

    // Add / update
    for (const r of sorted) {
      let row = existing.get(r.name);
      if (!row) {
        row = document.createElement('div');
        row.className = 'roster-row';
        row.dataset.name = r.name;
        row.innerHTML = `
          <span class="glyph"></span>
          <span class="name"></span>
          <span class="state-badge"></span>
          <span class="counts"></span>
        `;
        this.rosterEl.appendChild(row);
      }
      const colorVar = STATE_COLOR_VAR[r.state] || STATE_COLOR_VAR.idle;
      const color = cssVar(colorVar);
      row.querySelector('.glyph').textContent = glyphForRole(r.name);
      row.querySelector('.glyph').style.color = color;
      row.querySelector('.name').textContent = r.name;
      const badge = row.querySelector('.state-badge');
      badge.textContent = r.state;
      badge.style.color = color;
      badge.style.background = withAlpha(color, 0.14);
      const counts = r.counts || {};
      row.querySelector('.counts').innerHTML =
        `<span>↑${counts.sent_total ?? 0}</span><span class="sep">·</span>` +
        `<span>↓${counts.recv_total ?? 0}</span>`;
    }
  }

  _renderUnits(counts) {
    const total = UNIT_ORDER.reduce((acc, k) => acc + (counts[k] || 0), 0);
    // Stacked bar
    this.unitsBarEl.innerHTML = '';
    for (const k of UNIT_ORDER) {
      const c = counts[k] || 0;
      if (c === 0) continue;
      const seg = document.createElement('div');
      seg.className = 'seg';
      seg.style.width = (total ? (100 * c / total) : 0) + '%';
      seg.style.background = cssVar(UNIT_STATUS_COLORS[k] || '--text-dim');
      seg.title = `${k}: ${c}`;
      this.unitsBarEl.appendChild(seg);
    }
    // Legend
    this.unitsLegendEl.innerHTML = '';
    for (const k of UNIT_ORDER) {
      const c = counts[k] || 0;
      if (c === 0 && k !== 'todo' && k !== 'in-progress' && k !== 'done') continue;
      const item = document.createElement('div');
      item.className = 'item';
      const sw = document.createElement('span');
      sw.className = 'swatch';
      sw.style.background = cssVar(UNIT_STATUS_COLORS[k] || '--text-dim');
      item.appendChild(sw);
      const lbl = document.createElement('span');
      lbl.className = 'label';
      lbl.textContent = k;
      item.appendChild(lbl);
      const num = document.createElement('span');
      num.className = 'num';
      num.textContent = c;
      item.appendChild(num);
      this.unitsLegendEl.appendChild(item);
    }
  }

  _renderTimeline(timeline) {
    this.timelineEl.innerHTML = '';
    if (!timeline.length) {
      const empty = document.createElement('div');
      empty.className = 'timeline-row';
      empty.innerHTML = `<span class="ts"></span><span class="kind">—</span><span class="role" style="color:var(--text-dim)">no events yet</span>`;
      this.timelineEl.appendChild(empty);
      return;
    }
    for (const ev of timeline.slice(0, 8)) {
      const row = document.createElement('div');
      row.className = `timeline-row ${ev.kind === 'retire' ? 'retire' : 'add'}`;
      const kindGlyph = ev.kind === 'retire' ? '−' : '+';
      row.innerHTML = `
        <span class="ts">${fmtTimelineTs(ev.ts)}</span>
        <span class="kind">${kindGlyph}</span>
        <span class="role">${ev.role || ''}</span>
      `;
      this.timelineEl.appendChild(row);
    }
  }
}

export { fmtDuration };
