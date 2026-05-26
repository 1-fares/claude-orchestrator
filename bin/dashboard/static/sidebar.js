// u5-frontend: sidebar — roster, units, timeline.
// Night Honey theme. Reuses STATE_COLOR_VAR + STATE_LABEL from glyphs.js so
// the vocabulary stays single-sourced with the canvas renderer.
//
// DOM is built with createElement+textContent (no innerHTML) so values from
// /state.json are never interpreted as markup.

import {
  assetForRole,
  STATE_COLOR_VAR, STATE_LABEL, STATE_BADGE,
  cssVar, withAlpha,
} from './glyphs.js';

const UNIT_STATUS_COLORS = {
  todo:           '--ink-tertiary',
  assigned:       '--state-idle-color',
  acked:          '--state-idle-color',
  'in-progress':  '--state-active-color',
  blocked:        '--state-give-up-color',
  review:         '--state-question-color',
  integrating:    '--state-question-color',
  done:           '--prefix-done-color',
  deferred:       '--ink-tertiary',
};

const UNIT_ORDER = [
  'todo', 'assigned', 'acked', 'in-progress', 'blocked',
  'review', 'integrating', 'done', 'deferred',
];

function pad2(n) { return String(n).padStart(2, '0'); }

function fmtDuration(seconds) {
  if (!seconds || seconds < 0) return '00:00:00';
  const s = Math.floor(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return `${pad2(h)}:${pad2(m)}:${pad2(sec)}`;
}

function fmtTimelineTs(ev) {
  const tsReal = ev.ts_real || ev.ts;
  if (!tsReal) return ev.date || '';
  const d = new Date(tsReal * 1000);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

function mkEl(tag, opts = {}, children = []) {
  const el = document.createElement(tag);
  if (opts.cls) el.className = opts.cls;
  if (opts.id)  el.id = opts.id;
  if (opts.text != null) el.textContent = opts.text;
  if (opts.data) for (const k in opts.data) el.dataset[k] = opts.data[k];
  if (opts.attrs) for (const k in opts.attrs) el.setAttribute(k, opts.attrs[k]);
  for (const c of children) if (c) el.appendChild(c);
  return el;
}

export class Sidebar {
  constructor(rootEl) {
    this.root = rootEl;
    this.root.replaceChildren(
      mkEl('section', { cls: 'panel', id: 'roster-panel' }, [
        mkEl('h2', { cls: 'panel-title', text: 'Roster' }),
        (this.rosterEl = mkEl('div', { cls: 'roster-list', id: 'roster-list' })),
      ]),
      mkEl('section', { cls: 'panel', id: 'units-panel' }, [
        mkEl('h2', { cls: 'panel-title', text: 'Units' }),
        (this.unitsSumEl = mkEl('div', { cls: 'units-summary', id: 'units-summary' })),
        (this.unitsBarEl = mkEl('div', { cls: 'units-bar', id: 'units-bar' })),
        (this.unitsLegEl = mkEl('div', { cls: 'units-legend', id: 'units-legend' })),
      ]),
      mkEl('section', { cls: 'panel', id: 'timeline-panel' }, [
        mkEl('h2', { cls: 'panel-title', text: 'Timeline' }),
        (this.timelineEl = mkEl('div', { cls: 'timeline-list', id: 'timeline-list' })),
      ]),
    );
  }

  update(snap) {
    this._renderRoster(snap.roster || []);
    const counts = (snap.units && snap.units.counts) || {};
    this._renderUnits(counts);
    this._renderTimeline(snap.timeline || []);
  }

  _renderRoster(roster) {
    const sorted = roster.slice().sort((a, b) => {
      if (a.is_orchestrator && !b.is_orchestrator) return -1;
      if (b.is_orchestrator && !a.is_orchestrator) return 1;
      return a.name.localeCompare(b.name);
    });
    const existing = new Map();
    for (const child of this.rosterEl.children) {
      existing.set(child.dataset.name, child);
    }
    const wanted = new Set(sorted.map(r => r.name));
    for (const [name, el] of existing) {
      if (!wanted.has(name)) el.remove();
    }
    for (const r of sorted) {
      let row = existing.get(r.name);
      if (!row) {
        row = mkEl('div', { cls: 'roster-row', data: { name: r.name } }, [
          mkEl('img', { cls: 'role-thumb', attrs: { alt: '' } }),
          mkEl('div', { cls: 'role-text' }, [
            mkEl('div', { cls: 'role-name' }),
            mkEl('div', { cls: 'role-state-row' }, [
              mkEl('span', { cls: 'state-chip' }),
              mkEl('span', { cls: 'counts' }),
            ]),
          ]),
        ]);
        this.rosterEl.appendChild(row);
      }
      const state = r.state || 'idle';
      const colorVar = STATE_COLOR_VAR[state] || STATE_COLOR_VAR.idle;
      const color = cssVar(colorVar);
      row.dataset.roleState = state;

      const img = row.querySelector('.role-thumb');
      const url = assetForRole(r.name);
      if (img.dataset.src !== url) {
        img.src = url;
        img.dataset.src = url;
      }

      row.querySelector('.role-name').textContent = r.name;

      const chip = row.querySelector('.state-chip');
      const badge = STATE_BADGE[state];
      chip.textContent = (badge ? badge + ' ' : '') + (STATE_LABEL[state] || state);
      chip.style.color = color;
      chip.style.background = withAlpha(color, 0.16);

      const counts = r.counts || {};
      const countsEl = row.querySelector('.counts');
      countsEl.replaceChildren(
        mkEl('span', { cls: 'up', text: `↑${counts.sent_total ?? 0}` }),
        mkEl('span', { cls: 'sep', text: '·' }),
        mkEl('span', { cls: 'dn', text: `↓${counts.recv_total ?? 0}` }),
      );
    }
  }

  _renderUnits(counts) {
    const total = UNIT_ORDER.reduce((acc, k) => acc + (counts[k] || 0), 0);
    const done = counts.done || 0;
    this.unitsSumEl.replaceChildren(
      mkEl('div', { cls: 'units-summary-row' }, [
        mkEl('span', { cls: 'big-num', text: total ? String(done) : '0' }),
        mkEl('span', { cls: 'big-of',  text: `/ ${total || 0}` }),
        mkEl('span', { cls: 'big-label', text: total ? 'done' : 'units' }),
      ]),
    );

    this.unitsBarEl.replaceChildren();
    for (const k of UNIT_ORDER) {
      const c = counts[k] || 0;
      if (c === 0) continue;
      const seg = mkEl('div', { cls: 'seg', attrs: { title: `${k}: ${c}` } });
      seg.style.width = (total ? (100 * c / total) : 0) + '%';
      seg.style.background = cssVar(UNIT_STATUS_COLORS[k] || '--ink-tertiary');
      this.unitsBarEl.appendChild(seg);
    }

    this.unitsLegEl.replaceChildren();
    for (const k of UNIT_ORDER) {
      const c = counts[k] || 0;
      const must = (k === 'todo' || k === 'in-progress' || k === 'done');
      if (c === 0 && !must) continue;
      const sw = mkEl('span', { cls: 'swatch' });
      sw.style.background = cssVar(UNIT_STATUS_COLORS[k] || '--ink-tertiary');
      this.unitsLegEl.appendChild(
        mkEl('div', { cls: 'legend-item' }, [
          sw,
          mkEl('span', { cls: 'label', text: k }),
          mkEl('span', { cls: 'num',   text: String(c) }),
        ]),
      );
    }
  }

  _renderTimeline(timeline) {
    this.timelineEl.replaceChildren();
    if (!timeline.length) {
      this.timelineEl.appendChild(
        mkEl('div', { cls: 'timeline-row empty', text: 'no events yet' }),
      );
      return;
    }
    for (const ev of timeline.slice(0, 8)) {
      const kindGlyph = ev.kind === 'retire' ? '−' : '+';
      this.timelineEl.appendChild(
        mkEl('div', { cls: `timeline-row ${ev.kind === 'retire' ? 'retire' : 'add'}` }, [
          mkEl('span', { cls: 'ts',   text: fmtTimelineTs(ev) }),
          mkEl('span', { cls: 'kind', text: kindGlyph }),
          mkEl('span', { cls: 'role', text: ev.role || '' }),
        ]),
      );
    }
  }
}

export { fmtDuration };
