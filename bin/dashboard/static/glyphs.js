// u5-frontend: role-to-image resolver and state/prefix vocabulary.
// State + prefix names match ux-spec.md section 5 verbatim. Image asset
// mapping uses the ordered substring table from visual-spec.md section 6.

// Ordered substring match (case-insensitive). First match wins.
const ROLE_ASSET_RULES = [
  { sub: 'orchestrator', img: '/static/img/role-orchestrator.png' },
  { sub: 'research',     img: '/static/img/role-researcher.png'   },
  { sub: 'design',       img: '/static/img/role-designer.png'     },
  { sub: 'implement',    img: '/static/img/role-implementer.png'  },
  { sub: 'test',         img: '/static/img/role-tester.png'       },
  { sub: 'review',       img: '/static/img/role-reviewer.png'     },
  { sub: 'integrat',     img: '/static/img/role-integrator.png'   },
];
const ROLE_GENERIC = '/static/img/role-generic.png';
export const MASCOT_URL = '/static/img/mascot.png';

export function assetForRole(name) {
  if (!name) return ROLE_GENERIC;
  const lc = String(name).toLowerCase();
  for (const r of ROLE_ASSET_RULES) {
    if (lc.includes(r.sub)) return r.img;
  }
  return ROLE_GENERIC;
}

// The seven role states. Ordered by precedence (highest first), per
// ux-spec section 1 "node never shows two states at once".
export const ROLE_STATES = [
  'dead', 'give-up', 'stalled-api', 'paused', 'question', 'active', 'idle',
];

// Per-state glyph badge (third non-colour channel) — empty string when none.
export const STATE_BADGE = {
  active:        '',
  idle:          '',
  paused:        '⏸',
  question:      '?',
  'stalled-api': '⟳',
  'give-up':     '✕',
  dead:          '',
};

// Per-state short label for chips.
export const STATE_LABEL = {
  active:        'active',
  idle:          'idle',
  paused:        'paused',
  question:      'question',
  'stalled-api': 'stalled-api',
  'give-up':     'give-up',
  dead:          'dead',
};

// Map state → CSS custom property holding its colour.
export const STATE_COLOR_VAR = {
  active:        '--state-active-color',
  idle:          '--state-idle-color',
  paused:        '--state-paused-color',
  question:      '--state-question-color',
  'stalled-api': '--state-stalled-api-color',
  'give-up':     '--state-give-up-color',
  dead:          '--state-dead-color',
};

// Bus prefix → glyph (single char), short code (one letter), and colour var.
// Both glyph and short-code travel on a token so a paused screenshot still
// reads the message kind. Tints colour the edge / trace, never the disc fill.
export const PREFIX_INFO = {
  status:   { glyph: '•', code: 's', colorVar: '--prefix-status-color'   },
  done:     { glyph: '✓', code: 'd', colorVar: '--prefix-done-color'     },
  question: { glyph: '?', code: 'q', colorVar: '--prefix-question-color' },
  answer:   { glyph: '↵', code: 'a', colorVar: '--prefix-answer-color'   },
  priority: { glyph: '★', code: 'p', colorVar: '--prefix-priority-color' },
  pause:    { glyph: '⏸', code: '⏸', colorVar: '--prefix-pause-color'    },
  resume:   { glyph: '▶', code: '▶', colorVar: '--prefix-resume-color'   },
  stop:     { glyph: '■', code: '■', colorVar: '--prefix-stop-color'     },
  other:    { glyph: '•', code: '•', colorVar: '--prefix-other-color'    },
};

export function prefixInfo(p) {
  return PREFIX_INFO[p] || PREFIX_INFO.other;
}

// Resolve a CSS custom property against :root.
export function cssVar(name) {
  return getComputedStyle(document.documentElement)
    .getPropertyValue(name).trim();
}

// "#rrggbb" + alpha → "rgba(r,g,b,a)" for canvas. Pass-through for
// non-hex (e.g. an already-rgba() var); returns a sensible fallback on null.
export function withAlpha(hex, alpha) {
  if (!hex) return `rgba(185,176,224,${alpha})`;
  const m = hex.match(/^#?([0-9a-fA-F]{6})$/);
  if (!m) return hex;
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 0xff;
  const g = (n >> 8)  & 0xff;
  const b =  n        & 0xff;
  return `rgba(${r},${g},${b},${alpha})`;
}
