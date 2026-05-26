// u13-frontend-themes: state + prefix vocabulary AND theme loader.
//
// CSS color custom-property names match the master-spec section-1 contract
// (--node-active, --edge-status, etc.).  The theme loader manages the
// dynamic theme registry, the active stylesheet swap, and the role-image
// fallback chain. The two halves live in one module because the server's
// /static allowlist accepts the existing six basenames; folding lets us
// ship without a server-side allowlist change (the brief allows folding
// the theme helpers into glyphs.js verbatim).

// ---------------------------------------------------------- state vocabulary

// The seven role states, ordered by precedence (highest first), per master
// spec section 6 "node never shows two states at once".
export const ROLE_STATES = [
  'dead', 'give-up', 'stalled-api', 'paused', 'question', 'active', 'idle',
];

// Per-state glyph badge (third non-colour channel) — empty when none.
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

// State → CSS custom property holding its colour. Names follow the
// master-spec section-1 contract; per-theme tokens.css provides the value.
export const STATE_COLOR_VAR = {
  active:        '--node-active',
  idle:          '--node-idle',
  paused:        '--node-paused',
  question:      '--node-question',
  'stalled-api': '--node-stalled',
  'give-up':     '--node-give-up',
  dead:          '--node-dead',
};

// Bus prefix → glyph (single char), short code, and CSS color var.
// `pause`, `resume`, `stop` fall back to --edge-default in themes that
// don't carry a dedicated tint (the master contract only requires
// status/done/question/answer/priority/default).
export const PREFIX_INFO = {
  status:   { glyph: '•', code: 's', colorVar: '--edge-status'   },
  done:     { glyph: '✓', code: 'd', colorVar: '--edge-done'     },
  question: { glyph: '?', code: 'q', colorVar: '--edge-question' },
  answer:   { glyph: '↵', code: 'a', colorVar: '--edge-answer'   },
  priority: { glyph: '★', code: 'p', colorVar: '--edge-priority' },
  pause:    { glyph: '⏸', code: '⏸', colorVar: '--edge-default'  },
  resume:   { glyph: '▶', code: '▶', colorVar: '--edge-default'  },
  stop:     { glyph: '■', code: '■', colorVar: '--alert'         },
  other:    { glyph: '•', code: '•', colorVar: '--edge-default'  },
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
// non-hex (already-rgba) inputs; safe fallback for null/empty.
export function withAlpha(hex, alpha) {
  if (!hex) return `rgba(185,176,224,${alpha})`;
  const m = String(hex).trim().match(/^#?([0-9a-fA-F]{6})$/);
  if (!m) return hex;
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 0xff;
  const g = (n >> 8)  & 0xff;
  const b =  n        & 0xff;
  return `rgba(${r},${g},${b},${alpha})`;
}

// ---------------------------------------------------------- theme loader

const STORAGE_KEY = 'b11.theme';
// Default theme picked by the operator. paper-puppet-stage remains
// selectable; an existing localStorage 'b11.theme' still wins (u12e).
export const DEFAULT_THEME = 'warm-hive';

// Tiny 1x1 transparent PNG, used as the final image fallback so the
// onerror handler does not loop forever.
const BLANK_PNG_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAA' +
  'C0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

// Ordered substring → asset stem (master spec section 2). First match wins.
const ROLE_RULES = [
  { sub: 'orchestrator', stem: 'role-orchestrator' },
  { sub: 'research',     stem: 'role-researcher'   },
  { sub: 'design',       stem: 'role-designer'     },
  { sub: 'implement',    stem: 'role-implementer'  },
  { sub: 'test',         stem: 'role-tester'       },
  { sub: 'review',       stem: 'role-reviewer'     },
  { sub: 'integrat',     stem: 'role-integrator'   },
];
const GENERIC_STEM = 'role-generic';

function resolveStem(name) {
  if (!name) return GENERIC_STEM;
  const lc = String(name).toLowerCase();
  for (const r of ROLE_RULES) if (lc.includes(r.sub)) return r.stem;
  return GENERIC_STEM;
}

const themeState = {
  registry: [],
  registryByName: new Map(),
  active: null,
  changeListeners: new Set(),
};

export function getActive() { return themeState.active; }
export function getRegistry() { return themeState.registry.slice(); }
export function getTheme(name) { return themeState.registryByName.get(name) || null; }
export function onChange(fn) {
  themeState.changeListeners.add(fn);
  return () => themeState.changeListeners.delete(fn);
}

// /themes returns { themes: [...], schema_version }.
export async function fetchThemes() {
  try {
    const r = await fetch('/themes', { cache: 'no-store' });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const d = await r.json();
    const list = Array.isArray(d?.themes) ? d.themes : [];
    themeState.registry = list;
    themeState.registryByName = new Map(list.map(t => [t.name, t]));
    return list;
  } catch (err) {
    console.warn('fetchThemes failed:', err);
    return [];
  }
}

// Pick the boot theme: localStorage value if present in registry, else
// the default. Returns the picked name.
export function initialTheme() {
  let stored = null;
  try { stored = localStorage.getItem(STORAGE_KEY); } catch {}
  if (stored && themeState.registryByName.has(stored)) return stored;
  if (stored) {
    // Stale entry from a removed theme; clear it so the picker does not
    // resurrect a missing theme on the next reload.
    try { localStorage.removeItem(STORAGE_KEY); } catch {}
  }
  return themeState.registryByName.has(DEFAULT_THEME)
    ? DEFAULT_THEME
    : (themeState.registry[0]?.name || DEFAULT_THEME);
}

// Set the active theme: swap the stylesheet, update <html data-theme>,
// refresh every [data-themed-image] src, and persist.
export function applyTheme(name, opts = {}) {
  const persist = opts.persist !== false;
  if (!themeState.registryByName.has(name)) {
    console.warn(`applyTheme: unknown theme "${name}"; ignoring`);
    return false;
  }
  themeState.active = name;
  document.documentElement.dataset.theme = name;
  // Swap the theme stylesheet. Brand-new <link> if not present.
  let link = document.getElementById('theme-tokens');
  const href = `/static/themes/${encodeURIComponent(name)}/tokens.css`;
  if (!link) {
    link = document.createElement('link');
    link.id = 'theme-tokens';
    link.rel = 'stylesheet';
    document.head.appendChild(link);
  }
  if (link.getAttribute('href') !== href) link.setAttribute('href', href);
  // Refresh every themed image element.
  for (const img of document.querySelectorAll('[data-themed-image]')) {
    refreshImage(img);
  }
  if (persist) {
    try { localStorage.setItem(STORAGE_KEY, name); } catch {}
  }
  // Notify subscribers (e.g. graph renderer drops its image cache).
  for (const fn of themeState.changeListeners) {
    try { fn(name); } catch (e) { console.warn(e); }
  }
  return true;
}

// Resolve a role-name to a URL under the current theme. The DOM-level
// fallback chain runs via the onerror handler in onImageError.
export function glyphForRole(roleName, themeName) {
  const theme = themeName || themeState.active || DEFAULT_THEME;
  const stem = resolveStem(roleName);
  return `/static/themes/${encodeURIComponent(theme)}/${stem}.png`;
}

export function mascotUrl(themeName) {
  const theme = themeName || themeState.active || DEFAULT_THEME;
  return `/static/themes/${encodeURIComponent(theme)}/mascot.png`;
}

// Attach an <img> to a role with the resolver + fallback chain. Idempotent;
// re-runnable on theme change.
export function bindRoleImage(imgEl, roleName) {
  imgEl.dataset.themedImage = 'role';
  imgEl.dataset.roleName = roleName;
  imgEl.alt = '';
  imgEl.addEventListener('error', onImageError);
  refreshImage(imgEl);
}

export function bindMascotImage(imgEl) {
  imgEl.dataset.themedImage = 'mascot';
  imgEl.alt = '';
  imgEl.addEventListener('error', onImageError);
  refreshImage(imgEl);
}

// Read [data-themed-image] and set the right src for the current theme.
function refreshImage(imgEl) {
  const kind = imgEl.dataset.themedImage;
  imgEl.dataset.fallbackStep = '0';
  if (kind === 'mascot') {
    imgEl.src = mascotUrl();
  } else if (kind === 'role') {
    imgEl.src = glyphForRole(imgEl.dataset.roleName);
  }
}

// Walk the fallback chain on image error:
//   0 → theme role asset (initial)
//   1 → current theme's role-generic.png
//   2 → legacy v1 asset under /static/img/role-<stem>.png
//   3 → /static/img/role-generic.png
//   4 → blank 1x1 transparent (terminal)
function onImageError(e) {
  const img = e.currentTarget;
  const kind = img.dataset.themedImage;
  const step = parseInt(img.dataset.fallbackStep || '0', 10);
  img.dataset.fallbackStep = String(step + 1);
  if (kind === 'mascot') {
    if (step === 0) { img.src = `/static/img/mascot.png`; return; }
    if (step === 1) { img.src = BLANK_PNG_URL; return; }
    return;
  }
  const stem = resolveStem(img.dataset.roleName);
  const theme = themeState.active || DEFAULT_THEME;
  if (step === 0) {
    img.src = `/static/themes/${encodeURIComponent(theme)}/${GENERIC_STEM}.png`;
    return;
  }
  if (step === 1) { img.src = `/static/img/${stem}.png`; return; }
  if (step === 2) { img.src = `/static/img/${GENERIC_STEM}.png`; return; }
  if (step === 3) { img.src = BLANK_PNG_URL; return; }
}
