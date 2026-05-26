// Role-base → unicode glyph (u3 §5)
const ROLE_GLYPHS = {
  orchestrator:     '◆',
  architect:        '△',
  researcher:       '⌕',
  implementer:      '▣',
  frontend:         '◧',
  backend:          '◨',
  tester:           '✓',
  reviewer:         '◎',
  devops:           '⚙',
  'ux-designer':    '◐',
  'graphic-designer': '◑',
};

export function glyphForRole(name) {
  if (!name) return '●';
  // Strip trailing digits, then look up.
  const base = name.replace(/\d+$/, '');
  return ROLE_GLYPHS[base] || '●';
}

// Map state → CSS variable token (resolved by getComputedStyle).
export const STATE_COLOR_VAR = {
  orchestrator: '--node-orchestrator',
  active:       '--node-active',
  idle:         '--node-idle',
  paused:       '--node-paused',
  question:     '--node-question',
  'stalled-api': '--node-stalled-api',
  'give-up':    '--node-give-up',
};

// Map message prefix → edge color CSS variable.
export const EDGE_COLOR_VAR = {
  status:   '--edge-status',
  done:     '--edge-done',
  question: '--edge-question',
  answer:   '--edge-answer',
  priority: '--edge-priority',
  pause:    '--edge-pause',
  resume:   '--edge-resume',
  other:    '--edge-default',
};

// Resolve a CSS custom property at runtime against the document root.
export function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

// Convert "#rrggbb" + alpha (0..1) → "rgba(r,g,b,a)" for canvas drawing.
export function withAlpha(hex, alpha) {
  if (!hex) return `rgba(110,118,129,${alpha})`;
  const m = hex.match(/^#?([0-9a-f]{6})$/i);
  if (!m) return hex;
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 0xff;
  const g = (n >> 8)  & 0xff;
  const b =  n        & 0xff;
  return `rgba(${r},${g},${b},${alpha})`;
}

// Short tag shown on edges.
export const PREFIX_SHORT = {
  status:   'status',
  done:     'done',
  question: 'q',
  answer:   'a',
  priority: 'prio',
  pause:    'pause',
  resume:   'resume',
  other:    '',
};
