/* ANNOT — page overlay.
   Injected into the active Chrome tab by the Mac app (AppleScript `execute javascript`).
   No network requests, no innerHTML, styles isolated in a closed shadow root (OV-11, OV-12).
   Bridge API: window.__annot.{drain, busy, setComments, startCapture, stopCapture, stats} */
(function () {
  'use strict';
  if (window.__annot && window.__annot.alive) return 'alive'; // OV-1
  const stale = document.querySelector('annot-overlay');
  if (stale) stale.remove();
  if (window.__klx) window.__klx.setComments([]); // the overlay from before the rename (Klixpert Comments): clear its pins

  const PIN = 32;
  const AGENT = '#9747FF';
  const COLORS = ['#0D99FF', '#F24822', '#14AE5C', '#FF7A00', '#FF24BD', '#00B5CE', '#5B6BFF'];

  let me = '';
  let projects = []; // [{key, name, people: [{handle, name, agent}]}] where comments can go; empty: no picker
  let project = null; // the pick for this page; null keeps comments on this Mac
  let why = ''; // why it's this project ("matches acme.com"); '' for the default
  let closeMentions = null; // set while an @ list is open
  let queue = [];
  let mode = 'idle'; // idle | capture | compose | thread
  let draft = null; // { el, anchor, pin, px, py }
  let card = null; // the open composer or thread card
  let thread = null; // { head, msgs } of the open thread card
  let openId = null;
  let hoverEl = null;
  let lastHref = location.href;
  const mouse = { x: -1, y: -1 };
  const entries = new Map(); // comment id -> { c, el, status, node, x, y, visible, born }
  const stats = { searches: 0, layouts: 0, pinsCreated: 0 };

  const emit = (type, data) => queue.push(Object.assign({ type, url: location.href, ts: Date.now() }, data));

  // ---------- small helpers ----------
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const attrText = (el) => el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || el.getAttribute('placeholder'));
  const textOf = (el) => (norm(el.textContent) || norm(attrText(el))).slice(0, 160);
  const pageKey = (u) => { try { const x = new URL(u, location.href); if (!/^#[!/]/.test(x.hash)) x.hash = ''; return x.href; } catch (e) { return u; } };
  const r4 = (n) => Math.round(n * 1e4) / 1e4;
  const clamp = (n, a, b) => Math.min(b, Math.max(a, n));
  const docW = () => Math.max(document.documentElement.scrollWidth, innerWidth);
  const docH = () => Math.max(document.documentElement.scrollHeight, innerHeight);
  const isAgent = (a) => /^agent:/.test(a || '');
  const displayName = (a) => (a || 'someone').replace(/^agent:/, '');
  const initials = (a) => { const p = displayName(a).split(/[\s._-]+/).filter(Boolean); return ((p[0] || '?')[0] + (p[1] ? p[1][0] : '')).toUpperCase(); };
  const colorFor = (a) => { if (isAgent(a)) return AGENT; let x = 0; for (const ch of a || '') x = (x * 31 + ch.charCodeAt(0)) | 0; return COLORS[Math.abs(x) % COLORS.length]; };
  const ago = (iso) => { const s = (Date.now() - Date.parse(iso)) / 1000; if (!(s >= 45)) return 'now'; if (s < 3600) return Math.round(s / 60) + 'm'; if (s < 86400) return Math.round(s / 3600) + 'h'; return Math.round(s / 86400) + 'd'; };

  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    for (const k in props || {}) {
      const v = props[k];
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.slice(0, 2) === 'on') el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid);
    return el;
  }

  const ICONS = {
    send: 'M12 19V5M5.5 11.5L12 5l6.5 6.5',
    check: 'M5 12.5l4.5 4.5L19 7.5',
    close: 'M6 6l12 12M18 6L6 18',
    comment: 'M3 21V11a8 8 0 0 1 8-8h2a8 8 0 0 1 0 16H6z',
    target: 'M12 3v4M12 17v4M3 12h4M17 12h4M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8',
    pen: 'M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4',
  };
  function icon(name, size) {
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg');
    const set = { viewBox: '0 0 24 24', width: size || 16, height: size || 16, fill: 'none', stroke: 'currentColor', 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' };
    for (const k in set) svg.setAttribute(k, set[k]);
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', ICONS[name]);
    svg.append(p);
    return svg;
  }

  // replaceChildren() without the `cond && el` leftovers (false/undefined would render as text)
  const fill = (el, ...kids) => el.replaceChildren(...kids.flat().filter((k) => k != null && k !== false));

  function avatar(name) {
    const a = h('div', { class: 'av' + (isAgent(name) ? ' agent' : ''), text: isAgent(name) ? '✦' : initials(name) });
    a.style.setProperty('--c', colorFor(name));
    return a;
  }

  // ---------- styles ----------
  const cursorSvg = "<svg xmlns='http://www.w3.org/2000/svg' width='26' height='26' viewBox='0 0 24 24'><path d='M3 21V11a8 8 0 0 1 8-8h2a8 8 0 0 1 0 16H6z' fill='white' stroke='black' stroke-width='1.4' stroke-linejoin='round'/><path d='M12 7.5v7M8.5 11h7' stroke='black' stroke-width='1.4' stroke-linecap='round'/></svg>";
  const CURSOR = 'url("data:image/svg+xml,' + encodeURIComponent(cursorSvg) + '") 3 22, crosshair';
  const STYLES = `
.annot{position:absolute;top:0;left:0;font:13px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text","Inter","Segoe UI",system-ui,sans-serif;color:#1e1e1e;-webkit-font-smoothing:antialiased;text-align:left}
.annot *{box-sizing:border-box}
[hidden]{display:none!important}
button{font:inherit}
.shield{position:fixed;inset:0;z-index:1;pointer-events:auto;cursor:${CURSOR}}
.hl{position:fixed;top:0;left:0;z-index:2;pointer-events:none;border:1.5px solid #0D99FF;background:rgba(13,153,255,.07);border-radius:3px}
.hl-label{position:absolute;left:-1.5px;bottom:calc(100% + 4px);background:#0D99FF;color:#fff;font-size:11px;font-weight:500;line-height:16px;padding:1px 6px;border-radius:4px;white-space:nowrap;max-width:360px;overflow:hidden;text-overflow:ellipsis}
.hl.inside .hl-label{bottom:auto;top:4px;left:4px}
.hl.frozen .hl-label{display:none}
.pins{position:absolute;top:0;left:0;z-index:3}
.pin{position:absolute;top:0;left:0;width:${PIN}px;height:${PIN}px;pointer-events:auto;cursor:pointer;will-change:transform}
.pin-b{width:${PIN}px;height:${PIN}px;border-radius:16px 16px 16px 3px;background:var(--c,#0D99FF);border:2px solid #fff;box-shadow:0 1px 3px rgba(0,0,0,.2),0 4px 12px rgba(0,0,0,.14);color:#fff;font-size:12px;font-weight:600;display:flex;align-items:center;justify-content:center;transform-origin:0 100%;transition:scale .12s ease,box-shadow .12s ease;user-select:none}
.pin:hover .pin-b{scale:1.1}
.pin.active .pin-b{box-shadow:0 0 0 2px #0D99FF,0 4px 12px rgba(0,0,0,.2)}
.pin.pending .pin-b{animation:annot-pulse 1.1s ease-in-out infinite}
.pin.draft{pointer-events:none;animation:annot-drop .18s cubic-bezier(.2,1.4,.5,1)}
.pin.s-detached .pin-b{background:#a3a3a3;border-style:dashed}
.badge{position:absolute;right:-3px;top:-3px;width:11px;height:11px;border-radius:50%;border:2px solid #fff;display:none}
.pin.s-moved .badge{display:block;background:#FFA629}
.pin.s-changed .badge{display:block;background:#F24822}
.card,.preview{position:absolute;top:0;left:0;background:#fff;border-radius:12px;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 6px rgba(0,0,0,.06),0 12px 32px rgba(0,0,0,.16)}
.card{z-index:5;width:300px;pointer-events:auto;overflow:hidden;animation:annot-pop .14s ease-out}
.card.shake{animation:annot-shake .3s}
.row{display:flex;align-items:flex-start;gap:8px;padding:10px 10px 10px 12px}
.av{flex:none;width:24px;height:24px;border-radius:50%;background:var(--c);color:#fff;font-size:10px;font-weight:600;display:flex;align-items:center;justify-content:center;letter-spacing:.02em}
.av.agent{border-radius:7px;font-size:12px}
textarea{flex:1;min-width:0;border:0;outline:0;resize:none;background:transparent;font:inherit;color:inherit;padding:3px 0;margin:0;height:24px;max-height:160px;overflow-y:auto;box-shadow:none}
textarea::placeholder{color:#a3a3a3}
.send{flex:none;width:26px;height:26px;border-radius:50%;border:0;background:#0D99FF;color:#fff;display:flex;align-items:center;justify-content:center;cursor:pointer;padding:0;transition:background .12s}
.send:disabled{background:#efefef;color:#b8b8b8;cursor:default}
.send:not(:disabled):hover{background:#0a86df}
.head{display:flex;align-items:center;gap:6px;padding:8px 8px 8px 14px;border-bottom:1px solid #f0f0f0}
.title{font-weight:600}
.chip{font-size:11px;font-weight:500;padding:1px 7px;border-radius:10px;background:#fff3dc;color:#9a5a00;white-space:nowrap}
.chip.s-changed{background:#ffe8e1;color:#c4320a}
.chip.s-detached{background:#f0f0f0;color:#666}
.sp{flex:1}
.dest{display:flex;align-items:center;gap:6px;padding:7px 10px 8px 44px;border-top:1px solid #f0f0f0;font-size:11px;color:#8a8a8a}
.mentions{border-top:1px solid #f0f0f0;padding:4px 0;max-height:196px;overflow-y:auto}
.mention{display:flex;align-items:center;gap:8px;padding:4px 12px;cursor:pointer;min-width:0}
.mention .av{width:20px;height:20px;font-size:9px}
.mention.on{background:#e8f4ff}
.mention .handle{color:#8a8a8a;font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mention .name{font-size:13px;font-weight:500;white-space:nowrap}
.thread .mentions{border-top:0;border-bottom:1px solid #f0f0f0}
.proj{font:inherit;font-size:11px;color:#1e1e1e;border:1px solid #e3e3e3;border-radius:6px;padding:2px 4px;background:#fff;max-width:210px;cursor:pointer}
.why{min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#a8a8a8}
.row .ib{width:26px;height:26px}
.ib{width:28px;height:28px;border-radius:6px;border:0;background:transparent;color:#5c5c5c;display:flex;align-items:center;justify-content:center;cursor:pointer;padding:0}
.ib:hover{background:#f2f2f2;color:#1e1e1e}
.ib.ok:hover{color:#14AE5C}
.msgs{max-height:340px;overflow-y:auto;padding:4px 0}
.msg{display:flex;gap:8px;padding:8px 14px}
.msg.pending{opacity:.5}
.body{min-width:0;flex:1}
.meta{display:flex;gap:6px;align-items:center}
.name{font-weight:600;font-size:12px}
.tag{font-size:10px;font-weight:600;color:${AGENT};background:#f3ebff;border-radius:4px;padding:0 5px}
.time{font-size:11px;color:#9b9b9b}
.txt{white-space:pre-wrap;overflow-wrap:anywhere;margin-top:1px}
.target{display:flex;align-items:center;gap:5px;font-size:11px;color:#8c8c8c;margin-top:6px;min-width:0}
.target span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.details{white-space:pre-wrap;overflow-wrap:anywhere;margin-top:6px;padding:6px 8px;border-radius:6px;background:#f5f5f5;color:#444;font-size:12px;max-height:160px;overflow-y:auto}
.assignee{display:inline-block;margin-top:6px;font-size:11px;font-weight:500;color:${AGENT};background:#f6f0ff;border-radius:6px;padding:1px 7px}
.foot{border-top:1px solid #f0f0f0}
.preview{z-index:4;width:260px;padding:10px 12px;pointer-events:none;animation:annot-pop .12s ease-out}
.preview .av{width:20px;height:20px;font-size:9px}
.pv-txt{margin-top:4px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.pv-more{font-size:11px;color:#0D99FF;margin-top:4px;font-weight:500}
.pv-warn{font-size:11px;color:#9a5a00;margin-top:4px}
.pill,.toast{position:fixed;left:50%;bottom:24px;translate:-50% 0;z-index:6;display:flex;align-items:center;gap:8px;background:#1e1e1e;color:#fff;padding:8px 12px 8px 12px;border-radius:999px;font-size:12px;font-weight:500;box-shadow:0 8px 24px rgba(0,0,0,.25);pointer-events:none;white-space:nowrap;animation:annot-pop .16s ease-out}
.pill kbd{font:inherit;font-size:11px;background:rgba(255,255,255,.16);border-radius:5px;padding:1px 6px;color:#e6e6e6;margin-left:2px}
.toast svg{color:#3ddc84}
@keyframes annot-pop{from{opacity:0;scale:.96}to{opacity:1;scale:1}}
@keyframes annot-drop{from{opacity:0;scale:.4}to{opacity:1;scale:1}}
@keyframes annot-pulse{50%{opacity:.45}}
@keyframes annot-shake{25%{translate:-5px 0}75%{translate:5px 0}}
`;

  // ---------- DOM skeleton ----------
  const host = document.createElement('annot-overlay');
  host.style.cssText = 'all:initial;position:absolute;top:0;left:0;width:0;height:0;z-index:2147483647;pointer-events:none;';
  const root = host.attachShadow({ mode: 'closed' });
  try { const sheet = new CSSStyleSheet(); sheet.replaceSync(STYLES); root.adoptedStyleSheets = [sheet]; }
  catch (e) { root.append(h('style', { text: STYLES })); }

  const ui = h('div', { class: 'annot' });
  const shield = h('div', { class: 'shield', hidden: true });
  const hlLabel = h('div', { class: 'hl-label' });
  const hl = h('div', { class: 'hl', hidden: true }, hlLabel);
  const pins = h('div', { class: 'pins' });
  const preview = h('div', { class: 'preview', hidden: true });
  const pill = h('div', { class: 'pill', hidden: true }, icon('comment', 14), h('span', { text: 'Click any element to comment' }), h('kbd', { text: 'Esc' }));
  const toastEl = h('div', { class: 'toast', hidden: true });
  ui.append(shield, hl, pins, preview, pill, toastEl);
  root.append(ui);
  document.documentElement.appendChild(host);

  // Keep our clicks and keystrokes away from the page's own handlers (OV-5).
  for (const t of ['mousedown', 'mouseup', 'click', 'dblclick', 'pointerdown', 'pointerup', 'contextmenu', 'keydown', 'keyup', 'keypress', 'input', 'touchstart'])
    ui.addEventListener(t, (ev) => ev.stopPropagation());

  // ---------- anchors (OV-4) ----------
  function selectorFor(el) {
    const parts = [];
    for (let cur = el; cur && cur.nodeType === 1 && cur !== document.documentElement; cur = cur.parentElement) {
      if (cur === document.body) { parts.unshift('body'); break; }
      if (cur.id && /^[A-Za-z][\w-]{0,48}$/.test(cur.id) && !/\d{4,}/.test(cur.id) && document.querySelectorAll('#' + CSS.escape(cur.id)).length === 1) {
        parts.unshift('#' + CSS.escape(cur.id));
        break;
      }
      let part = cur.localName;
      const cls = [...cur.classList].filter((c) => /^[A-Za-z][\w-]{1,32}$/.test(c) && !/\d{3,}|^(is-|has-|js-)|active|hover|focus|open|selected|^css-|^sc-|^jsx-/.test(c)).slice(0, 2);
      if (cls.length) part += '.' + cls.map((c) => CSS.escape(c)).join('.');
      const parent = cur.parentElement;
      if (parent) {
        const same = [...parent.children].filter((s) => s.localName === cur.localName);
        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(cur) + 1) + ')';
      }
      parts.unshift(part);
    }
    return parts.join(' > ');
  }

  // ---------- element details for developers (anchor.dom) ----------
  const KEEP_ATTR = /^(id|name|type|role|href|src|alt|title|placeholder|for|action|method|value|aria-.+|data-.+)$/;
  const VOID = /^(area|base|br|col|embed|hr|img|input|link|meta|source|track|wbr)$/;
  const cut = (s, n) => (s.length > n ? s.slice(0, n) + '…' : s);
  const short = (el) => el.localName + (el.id ? '#' + el.id : el.classList.length ? '.' + [...el.classList].slice(0, 2).join('.') : '');

  // `<button class="btn" data-testid="buy">Buy now</button>`: opening tag with all attributes, text cut short.
  function snippet(el) {
    let s = '<' + el.localName;
    for (const a of el.attributes) if (a.name !== 'style') s += a.value === '' ? ' ' + a.name : ' ' + a.name + '="' + cut(a.value, 80).replace(/"/g, '&quot;') + '"';
    s = cut(s, 400) + '>';
    if (VOID.test(el.localName)) return s;
    const t = textOf(el);
    return s + (t ? cut(t, 80) : el.children.length ? '…' : '') + '</' + el.localName + '>';
  }

  function elementInfo(el) {
    const attributes = {};
    for (const a of el.attributes) if (KEEP_ATTR.test(a.name)) attributes[a.name] = cut(a.value, 200);
    const path = [];
    for (let cur = el; cur && cur.nodeType === 1 && cur !== document.documentElement && path.length < 8; cur = cur.parentElement) path.unshift(short(cur));
    const cs = getComputedStyle(el), r = el.getBoundingClientRect();
    return {
      id: el.id || undefined,
      classes: [...el.classList],
      attributes,
      html: snippet(el),
      path: path.join(' > '),
      size: { w: Math.round(r.width), h: Math.round(r.height) },
      style: { color: cs.color, background: cs.backgroundColor, font: cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily.split(',')[0].replace(/["']/g, '').trim() },
      page_title: document.title,
    };
  }

  // Finds the element by its text: walk text nodes (cheap) and climb to an ancestor with the same tag + text.
  function textSearch(a) {
    const want = a.text;
    if (!want || !document.body) return null;
    stats.searches++;
    const tag = (a.tag || '').toLowerCase();
    const head = want.slice(0, 24);
    const seen = new Set();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const p = n.parentElement;
      if (!p || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(p.tagName)) continue;
      const t = norm(n.nodeValue);
      if (t.length < Math.min(3, want.length)) continue;
      const probe = t.slice(0, 24);
      if (!head.startsWith(probe) && !probe.startsWith(head)) continue;
      for (let el = p, i = 0; el && i < 8; el = el.parentElement, i++) {
        if (seen.has(el)) break;
        seen.add(el);
        if (tag && el.tagName.toLowerCase() !== tag) continue;
        if (textOf(el) === want) return el;
      }
    }
    return null;
  }

  function resolve(e) {
    const a = e.c.anchor || {};
    let sel = null;
    try { sel = a.selector ? document.querySelector(a.selector) : null; } catch (err) { sel = null; }
    if (sel && host.contains(sel)) sel = null;
    let el = null, status = 'detached';
    if (sel && (!a.text || textOf(sel) === a.text)) { el = sel; status = 'exact'; }
    else if ((el = textSearch(a))) status = 'moved';
    else if (sel) { el = sel; status = 'changed'; }
    e.el = el;
    e.status = status;
  }

  // PERF-2: only re-resolve when the cached element is gone.
  function resolveAll() {
    for (const e of entries.values()) if (!e.el || !e.el.isConnected) resolve(e);
  }

  // ---------- pins (OV-3, PERF-3) ----------
  function ensureNode(e) {
    if (e.node) return e.node;
    const n = h('div', { class: 'pin', hidden: true }, h('div', { class: 'pin-b' }), h('i', { class: 'badge' }));
    n.addEventListener('mousedown', (ev) => { ev.preventDefault(); });
    n.addEventListener('click', () => openThread(e.c.id));
    n.addEventListener('mouseenter', () => showPreview(e));
    n.addEventListener('mouseleave', hidePreview);
    pins.append(n);
    e.node = n;
    e.x = e.y = NaN;
    e.visible = false;
    stats.pinsCreated++;
    return n;
  }

  function paint(e) {
    const n = ensureNode(e), c = e.c;
    n.className = 'pin s-' + e.status + (c.pending ? ' pending' : '') + (openId === c.id ? ' active' : '');
    n.style.setProperty('--c', colorFor(c.author));
    n.firstChild.textContent = c.pending ? initials(c.author) : String(c._n || '');
  }

  function pinPos(e) {
    const a = e.c.anchor || {};
    if (e.el) {
      const r = e.el.getBoundingClientRect();
      if (!r.width && !r.height) return null;
      const o = a.offset || { x: 0.5, y: 0.5 };
      return { x: Math.round(r.left + scrollX + clamp(o.x, 0, 1) * r.width), y: Math.round(r.top + scrollY + clamp(o.y, 0, 1) * r.height) };
    }
    const p = a.page_pct || { x: 0.5, y: 0.1 };
    return { x: Math.round(p.x * docW()), y: Math.round(p.y * docH()) };
  }

  let rafLayout = 0;
  const scheduleLayout = () => { if (!rafLayout) rafLayout = requestAnimationFrame(layout); };

  // OV-10: pins follow their element. Writes only when a position actually changed.
  function layout() {
    rafLayout = 0;
    stats.layouts++;
    for (const e of entries.values()) {
      if (!e.node) continue;
      const p = pinPos(e);
      if (!!p !== e.visible) { e.visible = !!p; e.node.hidden = !p; }
      if (p && (p.x !== e.x || p.y !== e.y)) {
        e.x = p.x; e.y = p.y;
        e.node.style.transform = 'translate(' + p.x + 'px,' + (p.y - PIN) + 'px)';
      }
    }
    if (draft) placeDraft();
    if (mode === 'thread' && card) { const e = entries.get(openId); if (e && e.visible) placeCard(card, e.x, e.y); }
    if ((mode === 'capture' || mode === 'compose') && hoverEl) drawHighlight(hoverEl);
  }

  function placeCard(el, px, py) {
    const w = el.offsetWidth, ht = el.offsetHeight, m = 12;
    const minX = scrollX + m, maxX = Math.max(minX, scrollX + innerWidth - w - m);
    const minY = scrollY + m, maxY = Math.max(minY, scrollY + innerHeight - ht - m);
    let x = px + PIN + 10;
    if (x > maxX) x = px - w - 10;
    el.style.transform = 'translate(' + Math.round(clamp(x, minX, maxX)) + 'px,' + Math.round(clamp(py - PIN, minY, maxY)) + 'px)';
  }

  // ---------- hover preview ----------
  const STATUS_TEXT = { moved: 'Element moved', changed: 'Element changed', detached: 'Element not found' };
  function showPreview(e) {
    if (openId === e.c.id || mode === 'compose') return;
    const c = e.c, n = (c.replies || []).length;
    fill(preview, 
      h('div', { class: 'meta' }, avatar(c.author), h('span', { class: 'name', text: displayName(c.author) }), h('span', { class: 'time', text: ago(c.created_at) })),
      h('div', { class: 'pv-txt', text: c.text }),
      n > 0 && h('div', { class: 'pv-more', text: n + (n === 1 ? ' reply' : ' replies') }),
      STATUS_TEXT[e.status] && h('div', { class: 'pv-warn', text: STATUS_TEXT[e.status] })
    );
    preview.hidden = false;
    placeCard(preview, e.x, e.y);
  }
  function hidePreview() { preview.hidden = true; }

  // ---------- toast ----------
  let toastTimer = 0;
  function toast(msg) {
    fill(toastEl, icon('check', 14), h('span', { text: msg }));
    toastEl.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toastEl.hidden = true; }, 1800);
  }

  // ---------- capture mode (OV-5, OV-7) ----------
  function targetAt(x, y) {
    for (const el of document.elementsFromPoint(x, y)) {
      if (el === host) continue;
      if (el === document.documentElement) return document.body || el;
      return el.closest('svg') || el;
    }
    return document.body || document.documentElement;
  }

  function describe(el) {
    const s = short(el);
    const t = textOf(el);
    return t ? s + '  ·  ' + (t.length > 42 ? t.slice(0, 42) + '…' : t) : s;
  }

  function drawHighlight(el) {
    if (!el || !el.isConnected) { hl.hidden = true; return; }
    const r = el.getBoundingClientRect();
    hl.hidden = false;
    hl.style.transform = 'translate(' + r.left + 'px,' + r.top + 'px)';
    hl.style.width = r.width + 'px';
    hl.style.height = r.height + 'px';
    hl.classList.toggle('inside', r.top < 24);
    if (hlLabel._el !== el) { hlLabel._el = el; hlLabel.textContent = describe(el); }
  }

  function startCapture(opts) {
    if (opts && opts.author) me = opts.author;
    if (opts) { projects = opts.projects || []; project = opts.project || null; why = opts.why || ''; }
    if (mode === 'capture' || mode === 'compose') { endCapture(true); return 'stopped'; } // hotkey toggles
    closeThread();
    hidePreview();
    mode = 'capture';
    shield.hidden = false;
    pill.hidden = false;
    if (mouse.x >= 0) { hoverEl = targetAt(mouse.x, mouse.y); drawHighlight(hoverEl); }
    return 'ok';
  }

  function endCapture(cancelled) {
    if (draft) { draft.pin.remove(); draft = null; }
    if (card && mode === 'compose') { card.remove(); card = null; }
    shield.hidden = true;
    hl.hidden = true;
    hl.classList.remove('frozen');
    pill.hidden = true;
    hoverEl = null;
    mode = 'idle';
    if (cancelled) emit('capture.cancel');
  }

  let rafHover = 0;
  shield.addEventListener('mousemove', (ev) => {
    mouse.x = ev.clientX; mouse.y = ev.clientY;
    if (mode !== 'capture' || rafHover) return;
    rafHover = requestAnimationFrame(() => { rafHover = 0; hoverEl = targetAt(mouse.x, mouse.y); drawHighlight(hoverEl); }); // PERF-4
  });
  shield.addEventListener('mousedown', (ev) => {
    ev.preventDefault();
    if (ev.button !== 0) return;
    if (mode === 'compose') {
      if (card && card._ta.value.trim()) { card.classList.remove('shake'); void card.offsetWidth; card.classList.add('shake'); return; }
      draft.pin.remove(); draft = null; card.remove(); card = null;
      hl.classList.remove('frozen');
    }
    openComposer(ev.clientX, ev.clientY, ev.screenX, ev.screenY);
  });
  for (const t of ['click', 'mouseup', 'dblclick', 'contextmenu']) shield.addEventListener(t, (ev) => ev.preventDefault());

  // Everyone in any project, for boxes that don't know their project.
  function allPeople() {
    const seen = new Map();
    for (const p of projects) for (const x of p.people || []) if (!seen.has(x.handle)) seen.set(x.handle, x);
    return [...seen.values()];
  }

  // "@ma" right before the caret → the people whose handle or name starts with "ma", handles first.
  function mentionMatches(people, q) {
    q = q.toLowerCase();
    const starts = (s) => (s || '').toLowerCase().split(/[\s._-]+/).some((w) => w.startsWith(q));
    const byHandle = people.filter((p) => p.handle.toLowerCase().startsWith(q));
    return byHandle.concat(people.filter((p) => !byHandle.includes(p) && starts(p.name))).slice(0, 6);
  }

  // `people()` is asked on every keystroke, so a composer can follow its project picker.
  function editor(placeholder, onSend, people) {
    const ta = h('textarea', { rows: 1, placeholder });
    const send = h('button', { class: 'send', type: 'button', disabled: true, title: 'Post  ⏎' }, icon('send', 14));
    const row = h('div', { class: 'row' }, avatar(me), ta, send);
    const menu = h('div', { class: 'mentions', hidden: true });
    let found = [], sel = 0, start = -1; // start: index of the "@" being completed
    const fire = () => { const t = ta.value.trim(); if (t) onSend(t, ta); };
    const close = () => { menu.hidden = true; found = []; if (closeMentions === close) closeMentions = null; scheduleLayout(); };
    const pick = (p) => {
      const end = ta.selectionStart;
      ta.value = ta.value.slice(0, start) + '@' + p.handle + ' ' + ta.value.slice(end);
      const caret = start + p.handle.length + 2;
      ta.setSelectionRange(caret, caret);
      close();
      ta.dispatchEvent(new Event('input'));
      ta.focus({ preventScroll: true });
    };
    const paintMenu = () => fill(menu, found.map((p, i) =>
      h('div', { class: 'mention' + (i === sel ? ' on' : ''), onmousedown: (ev) => { ev.preventDefault(); pick(p); } },
        avatar(p.agent ? 'agent:' + p.name : p.name), h('span', { class: 'name', text: p.name }), h('span', { class: 'handle', text: '@' + p.handle }))));
    const update = () => {
      const m = /(^|\s)@([\w.-]*)$/.exec(ta.value.slice(0, ta.selectionStart));
      found = m && people ? mentionMatches(people(), m[2]) : [];
      if (!found.length) { if (!menu.hidden) close(); return; }
      start = m.index + m[1].length;
      sel = 0;
      paintMenu();
      if (menu.hidden) { menu.hidden = false; closeMentions = close; scheduleLayout(); }
    };
    ta.addEventListener('input', () => {
      send.disabled = !ta.value.trim();
      ta.style.height = 'auto';
      ta.style.height = Math.min(ta.scrollHeight, 160) + 'px';
      update();
      scheduleLayout();
    });
    ta.addEventListener('click', update);
    ta.addEventListener('blur', () => { if (!menu.hidden) close(); });
    ta.addEventListener('keydown', (ev) => {
      if (!menu.hidden && found.length) {
        if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
          ev.preventDefault();
          sel = (sel + (ev.key === 'ArrowDown' ? 1 : found.length - 1)) % found.length;
          paintMenu();
          return;
        }
        if ((ev.key === 'Enter' || ev.key === 'Tab') && !ev.isComposing) { ev.preventDefault(); pick(found[sel]); return; }
      }
      if (ev.key !== 'Enter' || ev.shiftKey || ev.isComposing) return;
      ev.preventDefault();
      const t = ta.value.trim();
      if (t) onSend(t, ta, ev.metaKey); // ⌘⏎: post and draw on the screenshot
    });
    send.addEventListener('click', fire);
    return { row, ta, menu, focus: () => setTimeout(() => ta.focus({ preventScroll: true }), 0) };
  }

  function openComposer(cx, cy, sx, sy) {
    const el = targetAt(cx, cy);
    const r = el.getBoundingClientRect();
    draft = {
      el,
      screen: { x: sx, y: sy }, // the click on screen; with `client` the app finds the viewport on screen
      client: { x: cx, y: cy },
      px: cx + scrollX,
      py: cy + scrollY,
      anchor: {
        kind: 'web',
        url: location.href,
        selector: selectorFor(el),
        tag: el.tagName.toLowerCase(),
        text: textOf(el),
        offset: { x: r4(clamp((cx - r.left) / (r.width || 1), 0, 1)), y: r4(clamp((cy - r.top) / (r.height || 1), 0, 1)) },
        page_pct: { x: r4((cx + scrollX) / docW()), y: r4((cy + scrollY) / docH()) },
        viewport: { w: innerWidth, h: innerHeight },
        dom: elementInfo(el),
      },
    };
    hoverEl = el;
    drawHighlight(el);
    hl.classList.add('frozen');
    mode = 'compose';
    pill.hidden = true;
    draft.pin = h('div', { class: 'pin draft' }, h('div', { class: 'pin-b', text: initials(me) }));
    draft.pin.style.setProperty('--c', colorFor(me));
    pins.append(draft.pin);
    let pick = null;
    const ed = editor('Add a comment', submitDraft, () => {
      const p = projects.find((x) => x.key === (pick ? pick.value : project));
      return p ? p.people || [] : allPeople();
    });
    const draw = h('button', { class: 'ib', type: 'button', title: 'Post and draw on the screenshot  ⌘⏎' }, icon('pen', 15));
    draw.addEventListener('click', () => { const t = ed.ta.value.trim(); if (t) submitDraft(t, ed.ta, true); else ed.ta.focus(); });
    ed.row.insertBefore(draw, ed.row.lastChild);
    let reason = null;
    if (projects.length) { // where it goes: the project for this site, else the last pick here; a pick is remembered
      pick = h('select', { class: 'proj', title: 'Where this comment goes' },
        h('option', { value: '', text: 'Keep on this Mac' }),
        projects.map((p) => h('option', { value: p.key, text: p.name + ' (' + p.key + ')' })));
      pick.value = project || '';
      reason = h('span', { class: 'why', text: why });
      pick.addEventListener('change', () => { reason.hidden = true; ed.ta.focus({ preventScroll: true }); });
    }
    card = h('div', { class: 'card composer' }, ed.row, ed.menu, pick && h('div', { class: 'dest' }, h('span', { text: 'Send to' }), pick, reason));
    card._ta = ed.ta;
    card._pick = pick;
    ui.append(card);
    placeDraft();
    ed.focus();
  }

  function draftPoint() {
    const d = draft;
    if (!d.el.isConnected) return { x: d.px, y: d.py };
    const r = d.el.getBoundingClientRect();
    return { x: Math.round(r.left + scrollX + d.anchor.offset.x * r.width), y: Math.round(r.top + scrollY + d.anchor.offset.y * r.height) };
  }

  function placeDraft() {
    const p = draftPoint();
    draft.pin.style.transform = 'translate(' + p.x + 'px,' + (p.y - PIN) + 'px)';
    if (card) placeCard(card, p.x, p.y);
  }

  // OV-6
  function submitDraft(text, ta, annotate) {
    const d = draft;
    if (!d) return;
    const tempId = 'pending-' + Date.now();
    const r = d.el.getBoundingClientRect();
    const p = draftPoint();
    const chosen = card && card._pick ? card._pick.value || null : undefined; // undefined: no picker shown
    if (chosen !== undefined && chosen !== project) { project = chosen; why = ''; }
    emit('comment.create', {
      tempId, text, anchor: d.anchor, project: chosen,
      rect: { x: r.left, y: r.top, w: r.width, h: r.height },
      click: { x: p.x - scrollX, y: p.y - scrollY },
      screen: d.screen,
      client: d.client,
      vp: { w: innerWidth, h: innerHeight },
      dpr: devicePixelRatio,
      annotate: !!annotate,
    });
    const c = { id: tempId, tempId, text, author: me, status: 'open', created_at: new Date().toISOString(), anchor: d.anchor, replies: [], pending: true };
    const e = { c, el: d.el, status: 'exact', node: null, born: Date.now() };
    entries.set(tempId, e);
    endCapture(false);
    paint(e);
    scheduleLayout();
    toast((chosen ? 'Comment posted · ' + chosen + ' Triage' : 'Comment posted') + (annotate ? ' · opening screenshot…' : ''));
  }

  // ---------- threads (OV-8) ----------
  function openThread(id) {
    if (mode === 'capture' || mode === 'compose') endCapture(true);
    const e = entries.get(id);
    if (!e) return;
    if (mode === 'thread' && openId === id) return closeThread();
    closeThread();
    hidePreview();
    openId = id;
    mode = 'thread';
    const head = h('div', { class: 'head' });
    const msgs = h('div', { class: 'msgs' });
    const ed = editor('Reply', (text, ta) => {
      const cur = entries.get(openId);
      if (!cur || cur.c.pending) return;
      emit('comment.reply', { id: cur.c.id, text });
      (cur.c.replies = cur.c.replies || []).push({ author: me, text, created_at: new Date().toISOString(), pending: true });
      ta.value = '';
      ta.dispatchEvent(new Event('input'));
      fillThread(cur);
      msgs.scrollTop = msgs.scrollHeight;
    }, allPeople);
    thread = { head, msgs };
    card = h('div', { class: 'card thread' }, head, msgs, h('div', { class: 'foot' }, ed.menu, ed.row));
    card._ta = ed.ta;
    ui.append(card);
    fillThread(e);
    paint(e);
    placeCard(card, e.x, e.y);
    msgs.scrollTop = msgs.scrollHeight;
    ed.focus();
  }

  function fillThread(e) {
    const c = e.c, a = c.anchor || {};
    fill(thread.head, 
      h('span', { class: 'title', text: c.pending ? 'Posting…' : 'Comment #' + c._n }),
      STATUS_TEXT[e.status] && h('span', { class: 'chip s-' + e.status, text: STATUS_TEXT[e.status] }),
      h('span', { class: 'sp' }),
      !c.pending && h('button', { class: 'ib ok', type: 'button', title: 'Resolve', onclick: () => resolveComment(e) }, icon('check', 17)),
      h('button', { class: 'ib', type: 'button', title: 'Close  Esc', onclick: closeThread }, icon('close', 16))
    );
    const all = [{ author: c.author, text: c.text, details: c.details, created_at: c.created_at, first: true }].concat(c.replies || []);
    fill(thread.msgs, all.map((m) =>
      h('div', { class: 'msg' + (m.pending ? ' pending' : '') },
        avatar(m.author),
        h('div', { class: 'body' },
          h('div', { class: 'meta' },
            h('span', { class: 'name', text: displayName(m.author) }),
            isAgent(m.author) && h('span', { class: 'tag', text: 'AGENT' }),
            h('span', { class: 'time', text: ago(m.created_at) })),
          h('div', { class: 'txt', text: m.text }),
          m.details && h('div', { class: 'details', text: m.details }),
          m.first && c.assignee && h('div', { class: 'assignee', text: '→ ' + displayName(c.assignee) }),
          m.first && a.tag && h('div', { class: 'target' }, icon('target', 12), h('span', { text: '<' + (a.dom ? a.tag + (a.dom.id ? '#' + a.dom.id : a.dom.classes.length ? '.' + a.dom.classes.slice(0, 2).join('.') : '') : a.tag) + '>' + (a.text ? '  “' + a.text.slice(0, 48) + (a.text.length > 48 ? '…' : '') + '”' : '') }))))
    ));
  }

  function closeThread() {
    if (mode !== 'thread') return;
    const prev = entries.get(openId);
    if (card) card.remove();
    card = null; thread = null; openId = null; mode = 'idle';
    if (prev) paint(prev);
  }

  function resolveComment(e) {
    emit('comment.resolve', { id: e.c.id, status: 'resolved' });
    closeThread();
    if (e.node) e.node.remove();
    entries.delete(e.c.id);
    toast('Resolved');
  }

  // ---------- data from the bridge (BR-3) ----------
  function setComments(list, url, opts) {
    if (opts && opts.author) me = opts.author;
    if (url && pageKey(url) !== pageKey(location.href)) return 'stale';
    list = (Array.isArray(list) ? list.slice() : []).sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
    const keep = new Set();
    list.forEach((c, i) => {
      c._n = i + 1;
      if (c.status === 'resolved') return;
      let e = entries.get(c.id);
      if (!e && c.tempId && entries.has(c.tempId)) { // optimistic pin becomes the real one, same node
        e = entries.get(c.tempId);
        entries.delete(c.tempId);
        entries.set(c.id, e);
        if (openId === c.tempId) openId = c.id;
      }
      if (!e) { e = { c, el: null, status: 'detached', node: null }; entries.set(c.id, e); }
      else if ((e.c.anchor || {}).selector !== (c.anchor || {}).selector) e.el = null;
      e.c = c;
      keep.add(c.id);
    });
    for (const [id, e] of entries) {
      if (keep.has(id) || (e.c.pending && Date.now() - e.born < 15000)) continue;
      if (openId === id) closeThread();
      if (e.node) e.node.remove();
      entries.delete(id);
    }
    resolveAll();
    for (const e of entries.values()) paint(e);
    if (mode === 'thread' && entries.has(openId)) fillThread(entries.get(openId));
    scheduleLayout();
    return 'ok';
  }

  // ---------- navigation (OV-9) ----------
  function checkUrl() {
    if (location.href === lastHref) return;
    const was = pageKey(lastHref);
    lastHref = location.href;
    if (pageKey(lastHref) === was) return; // plain #anchor jump
    closeThread();
    hidePreview();
    for (const e of entries.values()) if (e.node) e.node.remove();
    entries.clear();
    emit('navigate');
  }
  // We run in Chrome's AppleScript isolated world, so patching history only catches calls from this world;
  // popstate/hashchange/Navigation API events and the URL check in drain() cover the page's own navigations.
  for (const m of ['pushState', 'replaceState']) {
    const orig = history[m];
    history[m] = function () { const r = orig.apply(this, arguments); setTimeout(checkUrl, 0); return r; };
  }
  addEventListener('popstate', checkUrl);
  addEventListener('hashchange', checkUrl);
  if (window.navigation && navigation.addEventListener) navigation.addEventListener('currententrychange', () => setTimeout(checkUrl, 0));
  setInterval(checkUrl, 500);

  // ---------- global listeners ----------
  addEventListener('keydown', (ev) => {
    if (ev.key !== 'Escape' || mode === 'idle') return;
    ev.preventDefault();
    ev.stopImmediatePropagation();
    if (closeMentions) closeMentions(); // Esc closes the @ list first
    else if (mode === 'thread') closeThread(); else endCapture(true);
  }, true);
  addEventListener('mousedown', (ev) => { if (mode === 'thread' && ev.target !== host) closeThread(); }, true);
  addEventListener('mousemove', (ev) => { mouse.x = ev.clientX; mouse.y = ev.clientY; }, { capture: true, passive: true });
  addEventListener('resize', scheduleLayout, { passive: true });
  addEventListener('scroll', scheduleLayout, { capture: true, passive: true });
  addEventListener('load', scheduleLayout, true);
  if (document.fonts) document.fonts.addEventListener('loadingdone', scheduleLayout);
  if (window.ResizeObserver && document.body) new ResizeObserver(scheduleLayout).observe(document.body);

  // DOM changes: reposition on the next frame; at most every 300 ms re-check anchors (PERF-2, PERF-5):
  // lost elements get re-resolved, connected ones only get a cheap text comparison (no search).
  let resolveTimer = 0;
  function recheck() {
    resolveTimer = 0;
    let dirty = false;
    for (const e of entries.values()) {
      const before = e.status;
      if (!e.el || !e.el.isConnected) resolve(e);
      else if (e.status === 'exact' || e.status === 'changed') {
        const want = (e.c.anchor || {}).text;
        e.status = !want || textOf(e.el) === want ? 'exact' : 'changed';
      }
      if (e.status !== before) { paint(e); dirty = true; }
    }
    if (dirty && mode === 'thread' && entries.has(openId)) fillThread(entries.get(openId));
    scheduleLayout();
  }
  new MutationObserver(() => {
    if (!host.isConnected) document.documentElement.appendChild(host);
    scheduleLayout();
    if (!resolveTimer && entries.size) resolveTimer = setTimeout(recheck, 300);
  }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });

  // ---------- bridge API (OV-2) ----------
  window.__annot = {
    alive: true,
    version: 1,
    drain() { checkUrl(); const q = queue; queue = []; return q; },
    busy: () => mode !== 'idle',
    setComments,
    startCapture,
    stopCapture() { if (mode === 'capture' || mode === 'compose') endCapture(true); return 'ok'; },
    stats() {
      const statuses = {};
      for (const e of entries.values()) statuses[e.status] = (statuses[e.status] || 0) + 1;
      return Object.assign({ pins: entries.size, mode, statuses }, stats);
    },
  };
  emit('ready');
  return 'injected';
})();
