// u29-gui-chat: operator-side chat panel for the communicator role.
// Polls GET /chat?since=<cursor>, GET /chat/open-question at the dashboard
// cadence; POSTs operator turns to /chat. Surfaces unread count as a header
// badge + favicon overlay, fires a toast and (opt-in) browser notification
// on operator-addressed turns. Theme-aware: composes from existing CSS
// custom properties + the u12g additions (--surface-2, --token-ink) +
// per-prefix --prefix-*-color tokens.
//
// Activity awareness (u24): the panel header surfaces the communicator
// role's `activity` and `subagent_count` from /state.json so the operator
// knows whether to expect a fast reply.

import { cssVar, withAlpha, PREFIX_INFO } from './glyphs.js';

const CHAT_POLL_MS_DEFAULT  = 2000;
const TOAST_DWELL_MS        = 6000;
const TOAST_STACK_CAP       = 3;
const TRANSCRIPT_AUTOSCROLL_PX = 60;
const NOTIF_OPT_IN_KEY      = 'chat-notifications-opt-in';
const FAVICON_BADGE_FILL    = '#FF5C75';
const FAVICON_BADGE_INK     = '#FFF5DD';
const PUSH_PREFIXES         = new Set(['question', 'priority']);

const AUTHOR_GLYPH = {
  operator:      '☻',
  communicator:  '◐',
  orchestrator:  '◯',
  role:          '●',
  system:        '⋯',
};

// Bucketed `author_type` → CSS-token name for the bar/chip tint. Roles
// `role:<name>` collapse to `role`; that family reads via --state-active-color
// so the chip matches the canvas role-ring colour.
function authorBucket(t) {
  if (!t) return 'system';
  if (t === 'operator' || t === 'communicator'
      || t === 'orchestrator' || t === 'system') return t;
  if (t.startsWith('role:')) return 'role';
  return 'system';
}

function authorTintVar(bucket) {
  switch (bucket) {
    case 'operator':     return '--accent';
    case 'communicator': return '--node-orchestrator';
    case 'orchestrator': return '--node-orchestrator';
    case 'role':         return '--state-active-color';
    default:             return '--ink-tertiary';
  }
}

function prefixTintVar(p) {
  if (!p) return null;
  return `--prefix-${p}-color`;
}

function parseIso(ts) {
  if (typeof ts !== 'string') return null;
  const t = Date.parse(ts);
  return Number.isFinite(t) ? t / 1000 : null;
}

function relTime(ageSec) {
  if (!Number.isFinite(ageSec) || ageSec < 0) return '';
  if (ageSec < 60)       return `${Math.max(1, Math.round(ageSec))}s ago`;
  if (ageSec < 3600)     return `${Math.round(ageSec / 60)}m ago`;
  if (ageSec < 86400)    return `${Math.round(ageSec / 3600)}h ago`;
  return `${Math.round(ageSec / 86400)}d ago`;
}

function el(id) { return document.getElementById(id); }

function mkEl(tag, opts = {}, children = []) {
  const node = document.createElement(tag);
  if (opts.cls) node.className = opts.cls;
  if (opts.text != null) node.textContent = opts.text;
  if (opts.data) for (const k in opts.data) node.dataset[k] = opts.data[k];
  if (opts.attrs) for (const k in opts.attrs) node.setAttribute(k, opts.attrs[k]);
  for (const c of children) if (c) node.appendChild(c);
  return node;
}

export class ChatPanel {
  constructor(opts = {}) {
    this.poll_ms        = opts.poll_ms || CHAT_POLL_MS_DEFAULT;
    this.entries        = [];
    this.seenIds        = new Set();   // msg_id|ts:body fingerprints
    this.cursor         = '';          // last `ts` we asked for (RFC3339 UTC)
    this.openQuestion   = null;
    this.unread         = 0;
    this.activeToasts   = [];
    this.open           = false;
    this.lastOpener     = null;        // focus restoration target
    this.commActivity   = null;        // last communicator role record
    this.lastSnap       = null;        // last /state.json snapshot
    this.faviconBaseUrl = null;
    this.faviconImg     = null;
    this.reducedMotion  = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.notifPref      = (window.localStorage?.getItem(NOTIF_OPT_IN_KEY)) || '';

    this.dom = {
      btn:        el('chat-button'),
      badge:      el('chat-unread-badge'),
      panel:      el('chat-panel'),
      close:      el('chat-close'),
      transcript: el('chat-transcript'),
      banner:     el('chat-banner'),
      bannerQ:    el('chat-banner-question'),
      bannerMeta: el('chat-banner-meta'),
      input:      el('chat-input'),
      sendBtn:    el('chat-send'),
      form:       el('chat-input-row'),
      activityDot:   el('chat-activity-dot'),
      activityLabel: el('chat-activity-label'),
      activityPill:  el('chat-activity-pill'),
      subtitle:   el('chat-subtitle'),
      toastStack: el('toast-stack'),
      roleSugg:   el('chat-role-suggestions'),
      jumpNew:    el('chat-jump-new'),
      jumpNewBtn: el('chat-jump-new-btn'),
      jumpNewCt:  el('chat-jump-new-count'),
    };

    this._bindUI();
    this._captureFavicon();
  }

  // ----------------------------------------------------------------- ui wiring

  _bindUI() {
    const d = this.dom;
    d.btn.addEventListener('click', () => this.toggle(d.btn));
    d.close.addEventListener('click', () => this.close());
    d.form.addEventListener('submit', (e) => {
      e.preventDefault();
      this._submit();
    });
    d.input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        this._submit();
      } else if (e.key === '@') {
        // datalist activates on `@` input naturally; nothing to do
      } else if (e.key === 'ArrowUp' && d.input.value === '') {
        const lastOp = [...this.entries].reverse().find(
          (m) => m.author_type === 'operator');
        if (lastOp) {
          e.preventDefault();
          d.input.value = lastOp.body || '';
        }
      }
    });
    d.input.addEventListener('input', () => this._autoresize());
    document.addEventListener('keydown', (e) => {
      // Cmd/Ctrl + / → toggle
      if ((e.metaKey || e.ctrlKey) && e.key === '/') {
        e.preventDefault();
        this.toggle(document.activeElement);
        return;
      }
      if (e.key === 'Escape' && this.open) {
        e.preventDefault();
        this.close();
      }
    });
    document.addEventListener('mousedown', (e) => {
      if (!this.open) return;
      if (window.innerWidth < 720) return;   // bottom-sheet: outside click ignored
      const within = d.panel.contains(e.target)
                  || d.btn.contains(e.target)
                  || (d.toastStack && d.toastStack.contains(e.target));
      if (!within) this.close();
    });
    if (d.jumpNewBtn) {
      d.jumpNewBtn.addEventListener('click', () => this._scrollToBottom(true));
    }
    const mql = window.matchMedia('(prefers-reduced-motion: reduce)');
    mql.addEventListener?.('change', (e) => { this.reducedMotion = e.matches; });
  }

  _autoresize() {
    const t = this.dom.input;
    t.style.height = 'auto';
    const max = 4 * parseFloat(getComputedStyle(t).lineHeight || '20');
    t.style.height = Math.min(t.scrollHeight, max) + 'px';
  }

  // ----------------------------------------------------------------- open/close

  toggle(opener) {
    this.open ? this.close() : this.open_(opener);
  }

  open_(opener) {
    this.open = true;
    this.lastOpener = opener || this.dom.btn;
    this.dom.panel.dataset.open = 'true';
    this.dom.panel.setAttribute('aria-hidden', 'false');
    this.dom.btn.setAttribute('aria-expanded', 'true');
    document.body.dataset.chat = 'open';
    this._clearUnread();
    queueMicrotask(() => {
      this.dom.input.focus();
      this._scrollToBottom(true);
    });
  }

  close() {
    if (!this.open) return;
    this.open = false;
    delete this.dom.panel.dataset.open;
    this.dom.panel.setAttribute('aria-hidden', 'true');
    this.dom.btn.setAttribute('aria-expanded', 'false');
    delete document.body.dataset.chat;
    const focusTarget = (this.lastOpener && this.lastOpener.focus)
      ? this.lastOpener : this.dom.btn;
    queueMicrotask(() => focusTarget.focus());
  }

  // ----------------------------------------------------------------- polling

  async tick() {
    await Promise.all([this._pullEntries(), this._pullOpenQuestion()]);
  }

  applySnapshot(snap) {
    this.lastSnap = snap;
    const roster = (snap?.roster) || [];
    const comm = roster.find((r) => r.name === 'communicator') || null;
    this.commActivity = comm;
    this._renderHeader();
    this._populateRoleSuggestions(roster);
  }

  async _pullEntries() {
    const url = '/chat' + (this.cursor ? `?since=${encodeURIComponent(this.cursor)}` : '');
    let data;
    try {
      const r = await fetch(url, { cache: 'no-store' });
      if (!r.ok) return;
      data = await r.json();
    } catch (_) {
      return;
    }
    const fresh = Array.isArray(data?.entries) ? data.entries : [];
    if (!fresh.length) return;
    for (const e of fresh) {
      const fp = this._fingerprint(e);
      if (this.seenIds.has(fp)) continue;
      this.seenIds.add(fp);
      this.entries.push(e);
      if (e.ts) this.cursor = e.ts;
      // Skip operator's own echo from a push; the entry is already in the DOM
      // because we appended optimistically on submit. The fingerprint dedupe
      // catches it because we use the same `ts` server-stamped on POST.
      this._onNewEntry(e);
    }
    this._renderTranscript();
  }

  async _pullOpenQuestion() {
    let data;
    try {
      const r = await fetch('/chat/open-question', { cache: 'no-store' });
      if (!r.ok) return;
      data = await r.json();
    } catch (_) {
      return;
    }
    const empty = !data || !Object.keys(data).length;
    if (empty) {
      if (this.openQuestion) {
        this.openQuestion = null;
        this._renderBanner();
      }
      return;
    }
    const sameQid = this.openQuestion && this.openQuestion.qid === data.qid;
    this.openQuestion = data;
    this._renderBanner();
    // First time we see this qid: fire a question push.
    if (!sameQid) {
      this._push({
        author_type: data.asker_type || 'system',
        author_name: data.asker_name || 'system',
        prefix: 'question',
        addressed_to: 'operator',
        body: data.question || '',
        unit: data.unit || null,
        ts: data.asked_at || null,
        _qid: data.qid,
      });
    }
  }

  _fingerprint(e) {
    if (e.msg_id) return 'm:' + e.msg_id;
    return 't:' + (e.ts || '') + ':' + (e.author_type || '') + ':' + (e.body || '').slice(0, 64);
  }

  // ----------------------------------------------------------------- send

  async _submit() {
    const text = (this.dom.input.value || '').trim();
    if (!text) return;
    const { addressed_to, body } = this._parseAddressing(text);
    this.dom.input.value = '';
    this._autoresize();
    const optimistic = {
      ts: null,
      author_type: 'operator',
      author_name: 'operator',
      addressed_to,
      body,
      _optimistic: true,
    };
    this.entries.push(optimistic);
    this._renderTranscript();
    this._scrollToBottom(true);
    try {
      const r = await fetch('/chat', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          author_name: 'operator',
          body,
          addressed_to,
        }),
      });
      if (!r.ok && r.status !== 202) {
        optimistic._failed = true;
        this._renderTranscript();
      }
    } catch (_) {
      optimistic._failed = true;
      this._renderTranscript();
    }
  }

  _parseAddressing(text) {
    const m = text.match(/^\s*@(role:[a-z0-9][a-z0-9-]*|[a-z0-9][a-z0-9-]*)\s+([\s\S]+)$/);
    if (!m) return { addressed_to: 'communicator', body: text };
    const tok = m[1];
    const body = m[2];
    if (tok === 'orchestrator' || tok === 'operator' || tok === 'communicator') {
      return { addressed_to: tok, body };
    }
    if (tok.startsWith('role:')) return { addressed_to: tok, body };
    return { addressed_to: `role:${tok}`, body };
  }

  _populateRoleSuggestions(roster) {
    const sugg = this.dom.roleSugg;
    if (!sugg) return;
    const names = roster.map((r) => r.name).filter(Boolean).sort();
    const items = ['@communicator', '@orchestrator', ...names.map((n) => `@${n}`)];
    sugg.replaceChildren(...items.map((s) => {
      const o = document.createElement('option');
      o.value = s;
      return o;
    }));
    this.dom.input.setAttribute('list', sugg.id);
  }

  // ----------------------------------------------------------------- render

  _renderHeader() {
    const dot = this.dom.activityDot;
    const label = this.dom.activityLabel;
    const pill = this.dom.activityPill;
    const sub = this.dom.subtitle;
    const r = this.commActivity;
    if (!r) {
      dot.style.background = cssVar('--ink-tertiary');
      label.textContent = 'offline';
      pill.hidden = true;
      sub.hidden = true;
      return;
    }
    const activity = r.activity || (r.state === 'active' ? 'working'
                                   : r.state === 'stalled-api' ? 'stalled-api'
                                   : r.state === 'give-up' ? 'give-up' : 'idle');
    const isActive = activity === 'working' || activity === 'delegating';
    dot.style.background = isActive
      ? cssVar('--state-active-color') || cssVar('--node-active')
      : cssVar('--ink-tertiary');
    if (activity === 'delegating') {
      const n = Number.isFinite(r.subagent_count) ? Math.floor(r.subagent_count) : null;
      label.textContent = n != null ? `delegating ${n}` : 'delegating';
      pill.hidden = false;
      pill.textContent = n != null ? String(n) : '⚙';
    } else if (activity === 'stalled-api') {
      label.textContent = 'stalled (API)';
      pill.hidden = true;
    } else if (activity === 'give-up') {
      label.textContent = 'give-up';
      pill.hidden = true;
    } else if (activity === 'idle') {
      label.textContent = 'idle';
      pill.hidden = true;
    } else {
      label.textContent = 'working';
      pill.hidden = true;
    }
    if (r.subtitle && typeof r.subtitle === 'string') {
      sub.hidden = false;
      sub.textContent = r.subtitle;
    } else {
      sub.hidden = true;
    }
    // Disable input if stalled
    this.dom.input.disabled = activity === 'stalled-api';
    this.dom.sendBtn.disabled = activity === 'stalled-api';
  }

  _renderBanner() {
    const b = this.dom.banner;
    const q = this.openQuestion;
    if (!q) {
      b.hidden = true;
      return;
    }
    b.hidden = false;
    this.dom.bannerQ.textContent = q.question || '';
    const meta = [];
    if (q.asker_name) meta.push(`asked by ${q.asker_name}`);
    if (q.unit) meta.push(`unit: ${q.unit}`);
    if (q.asked_at) {
      const age = (Date.now() / 1000) - (parseIso(q.asked_at) || 0);
      meta.push(relTime(age));
    }
    this.dom.bannerMeta.textContent = meta.join(' · ');
  }

  _renderTranscript() {
    const root = this.dom.transcript;
    const nearBottom = (root.scrollHeight - root.clientHeight - root.scrollTop) < TRANSCRIPT_AUTOSCROLL_PX;
    root.replaceChildren(...this.entries.map((e) => this._renderEntry(e)));
    if (nearBottom || this._wasJustSent()) this._scrollToBottom(false);
    this._updateJumpNewBadge();
  }

  _wasJustSent() {
    const tail = this.entries[this.entries.length - 1];
    return tail && tail.author_type === 'operator' && tail._optimistic;
  }

  _renderEntry(e) {
    const bucket = authorBucket(e.author_type);
    const tintVar = authorTintVar(bucket);
    const tint = cssVar(tintVar) || cssVar('--ink-tertiary');
    const row = mkEl('div', {
      cls: 'chat-row',
      data: {
        authorType: bucket,
        authorName: e.author_name || '',
        prefix: e.prefix || '',
        ...(e._optimistic ? { optimistic: 'true' } : {}),
        ...(e._failed ? { failed: 'true' } : {}),
      },
    });
    row.style.setProperty('--chat-row-tint', tint);

    const bar = mkEl('div', { cls: 'chat-row-bar' });
    bar.style.background = tint;
    row.appendChild(bar);

    const body = mkEl('div', { cls: 'chat-row-body' });

    const head = mkEl('div', { cls: 'chat-row-head' });
    const chip = mkEl('div', { cls: 'chat-row-chip' });
    chip.style.background = tint;
    chip.style.color = cssVar('--token-ink') || '#1A1730';
    chip.textContent = AUTHOR_GLYPH[bucket] || '·';
    head.appendChild(chip);

    const name = mkEl('div', { cls: 'chat-row-name', text: e.author_name || bucket });
    head.appendChild(name);

    const age = (parseIso(e.ts) != null && this.lastSnap?.now_ts)
      ? Math.max(0, this.lastSnap.now_ts - parseIso(e.ts))
      : null;
    if (age != null) {
      head.appendChild(mkEl('div', { cls: 'chat-row-ts', text: relTime(age) }));
    } else if (e._optimistic) {
      head.appendChild(mkEl('div', { cls: 'chat-row-ts', text: e._failed ? 'failed' : 'sending…' }));
    }

    if (e.prefix && PREFIX_INFO[e.prefix]) {
      const tag = mkEl('div', { cls: 'chat-prefix-tag', text: e.prefix.toUpperCase() });
      const col = cssVar(prefixTintVar(e.prefix)) || cssVar('--ink-tertiary');
      tag.style.color = col;
      tag.style.background = withAlpha(col, 0.18);
      tag.style.borderColor = withAlpha(col, 0.7);
      head.appendChild(tag);
    }
    body.appendChild(head);

    const text = mkEl('div', { cls: 'chat-row-text' });
    text.textContent = e.body || '';
    body.appendChild(text);

    if (e.unit) {
      body.appendChild(mkEl('div', {
        cls: 'chat-row-unit', text: `↪ ${e.unit}`,
      }));
    }

    row.appendChild(body);
    return row;
  }

  _scrollToBottom(force) {
    const root = this.dom.transcript;
    root.scrollTop = root.scrollHeight;
    if (force && this.dom.jumpNew) this.dom.jumpNew.hidden = true;
    this._updateJumpNewBadge();
  }

  _updateJumpNewBadge() {
    const root = this.dom.transcript;
    const j = this.dom.jumpNew;
    if (!j) return;
    const offBottom = (root.scrollHeight - root.clientHeight - root.scrollTop) > TRANSCRIPT_AUTOSCROLL_PX;
    if (offBottom && this.unread > 0) {
      j.hidden = false;
      this.dom.jumpNewCt.textContent = String(this.unread);
    } else {
      j.hidden = true;
    }
  }

  // ----------------------------------------------------------------- push

  _onNewEntry(e) {
    if (e._optimistic || e.author_type === 'operator') return;
    if (e.addressed_to === 'operator') this._push(e);
  }

  _push(e) {
    this.unread += 1;
    this._renderUnread();
    this._updateFavicon();
    this._showToast(e);
    if (e.prefix && PUSH_PREFIXES.has(e.prefix)) {
      this._maybeFireNotification(e);
    }
  }

  _clearUnread() {
    if (this.unread === 0) return;
    this.unread = 0;
    this._renderUnread();
    this._updateFavicon();
  }

  _renderUnread() {
    const b = this.dom.badge;
    if (!b) return;
    if (this.unread <= 0) {
      b.hidden = true;
      b.textContent = '0';
    } else {
      b.hidden = false;
      b.textContent = this.unread > 99 ? '99+' : String(this.unread);
    }
    this.dom.btn.setAttribute('aria-label', `Open chat, ${this.unread} unread`);
  }

  _showToast(e) {
    const stack = this.dom.toastStack;
    if (!stack) return;
    const bucket = authorBucket(e.author_type);
    const tint = cssVar(authorTintVar(bucket)) || cssVar('--accent');
    const isQ = e.prefix && PUSH_PREFIXES.has(e.prefix);
    const border = isQ
      ? (cssVar(prefixTintVar(e.prefix)) || tint)
      : tint;
    const toast = mkEl('div', {
      cls: 'chat-toast',
      attrs: { role: isQ ? 'alert' : 'status', 'aria-live': isQ ? 'assertive' : 'polite' },
      data: { reducedMotion: this.reducedMotion ? 'true' : 'false' },
    });
    toast.style.borderLeftColor = border;
    const head = mkEl('div', { cls: 'chat-toast-head' });
    head.appendChild(mkEl('div', { cls: 'chat-toast-author', text: e.author_name || bucket }));
    if (e.prefix) {
      head.appendChild(mkEl('div', { cls: 'chat-toast-prefix', text: e.prefix }));
    }
    toast.appendChild(head);
    toast.appendChild(mkEl('div', { cls: 'chat-toast-body', text: e.body || '' }));
    toast.addEventListener('click', () => {
      this.open_(this.dom.btn);
      this._dismissToast(toast);
    });

    // Newest at bottom; cap to TOAST_STACK_CAP.
    stack.appendChild(toast);
    this.activeToasts.push(toast);
    while (this.activeToasts.length > TOAST_STACK_CAP) {
      this._dismissToast(this.activeToasts.shift());
    }
    let timeLeft = TOAST_DWELL_MS;
    let started  = Date.now();
    let timer = null;
    const start = () => {
      started = Date.now();
      timer = setTimeout(() => this._dismissToast(toast), timeLeft);
    };
    const stop = () => {
      if (timer) { clearTimeout(timer); timer = null; }
      timeLeft -= Date.now() - started;
    };
    toast.addEventListener('mouseenter', stop);
    toast.addEventListener('mouseleave', start);
    start();
  }

  _dismissToast(toast) {
    if (!toast || !toast.parentNode) return;
    toast.parentNode.removeChild(toast);
    this.activeToasts = this.activeToasts.filter((t) => t !== toast);
  }

  _maybeFireNotification(e) {
    if (typeof Notification === 'undefined') return;
    if (this.notifPref === 'never') return;
    if (Notification.permission === 'granted') {
      this._fireNotification(e);
      return;
    }
    if (Notification.permission === 'default' && this.notifPref !== 'opt-out') {
      Notification.requestPermission().then((perm) => {
        try { window.localStorage?.setItem(NOTIF_OPT_IN_KEY, perm); } catch (_) {}
        this.notifPref = perm;
        if (perm === 'granted') this._fireNotification(e);
      }).catch(() => {});
    }
  }

  _fireNotification(e) {
    try {
      const n = new Notification(`${e.author_name || 'communicator'}: ${e.prefix || ''}`, {
        body: e.body || '',
        tag: e._qid || e.msg_id || (e.ts || '') + ':' + (e.body || '').slice(0, 32),
      });
      n.onclick = () => { window.focus(); this.open_(this.dom.btn); n.close(); };
    } catch (_) {
      // platforms without permission or with rate limiting throw; swallow
    }
  }

  // ----------------------------------------------------------------- favicon

  _captureFavicon() {
    const link = document.querySelector('link[rel="icon"]');
    this.faviconBaseUrl = link ? link.href : null;
    if (!this.faviconBaseUrl) return;
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => { this.faviconImg = img; this._updateFavicon(); };
    img.src = this.faviconBaseUrl;
  }

  _updateFavicon() {
    if (!this.faviconImg) return;
    const link = document.querySelector('link[rel="icon"]');
    if (!link) return;
    const w = 64, h = 64;
    let canvas;
    try {
      canvas = (typeof OffscreenCanvas !== 'undefined')
        ? new OffscreenCanvas(w, h)
        : Object.assign(document.createElement('canvas'), { width: w, height: h });
    } catch (_) {
      canvas = Object.assign(document.createElement('canvas'), { width: w, height: h });
    }
    const ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, w, h);
    ctx.drawImage(this.faviconImg, 0, 0, w, h);
    if (this.unread > 0) {
      const r = 18;
      const cx = w - r, cy = r;
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, 2 * Math.PI);
      ctx.fillStyle = FAVICON_BADGE_FILL;
      ctx.fill();
      ctx.fillStyle = FAVICON_BADGE_INK;
      ctx.font = 'bold 22px sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      const txt = this.unread > 9 ? '9+' : String(this.unread);
      ctx.fillText(txt, cx, cy + 1);
    }
    const setHref = (url) => { link.href = url; };
    if (canvas.convertToBlob) {
      canvas.convertToBlob({ type: 'image/png' }).then((blob) => {
        setHref(URL.createObjectURL(blob));
      }).catch(() => {});
    } else if (canvas.toDataURL) {
      setHref(canvas.toDataURL('image/png'));
    }
  }
}
