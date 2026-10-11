// Node-only behavioural check of the /explain page scripts (no browser needed).
// Usage:
//   node tests/explain-lang-sim.mjs lang <page.html>   language switch, deep links, hand-over
//   node tests/explain-lang-sim.mjs poll <page.html>   reload poll (template, index, placeholder)
// Runs the page's own inline <script> blocks in a small DOM stand-in with a
// laid-out geometry (the two articles have different block heights, like a
// translation), so the logic is exercised, not grepped. tests/explain-lang-check.mjs
// covers the same switch in a real headless Chromium where one is available.
// Prints "PASS <name>" / "FAIL <name>" lines; exit 1 on any failure.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const [mode, file] = process.argv.slice(2);
if (!mode || !file) { console.error('usage: explain-lang-sim.mjs lang|poll <page.html>'); process.exit(2); }
const html = readFileSync(file, 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((x) => x[1]);
let failed = 0;
const ok = (name, cond, info = '') => { console.log(`${cond ? 'PASS' : 'FAIL'} sim ${mode}: ${name}${cond || !info ? '' : ` (${info})`}`); if (!cond) failed++; };

// ---------------------------------------------------------------------------
// DOM stand-in built from the page source

const VOID = new Set(['meta', 'br', 'img', 'hr', 'input', 'link', 'source', 'wbr', 'col']);
function parseArticles() {
  const arts = [];
  const re = /<article lang="(\w+)">([\s\S]*?)<\/article>/g; let m;
  while ((m = re.exec(html))) {
    const art = { lang: m[1], els: [], h1: (/<h1>([^<]*)<\/h1>/.exec(m[2]) || [])[1] || '' };
    const stack = []; const tag = /<(\/?)([a-zA-Z0-9]+)([^>]*)>/g; let t;
    while ((t = tag.exec(m[2]))) {
      const [, close, name, attrs] = t;
      if (VOID.has(name.toLowerCase())) continue;
      if (!close) {
        const dl = /data-label="([^"]+)"/.exec(attrs);
        const node = { name, label: dl ? dl[1] : null, parent: null, kids: [] };
        for (let i = stack.length - 1; i >= 0; i--) if (stack[i].label) { node.parent = stack[i]; break; }
        if (node.label) { art.els.push(node); if (node.parent) node.parent.kids.push(node); }
        stack.push(node);
      } else {
        for (let i = stack.length - 1; i >= 0; i--) if (stack[i].name === name) { stack.length = i; break; }
      }
    }
    arts.push(art);
  }
  return arts;
}

function makePage(scen) {
  const state = { requests: 0, reloads: 0, scrollY: 0 };
  const arts = parseArticles();
  const root = { attrs: {}, lang: '', setAttribute(n, v) { this.attrs[n] = String(v); }, getAttribute(n) { return this.attrs[n] ?? null; } };
  const LEAF = { en: 100, pt: 140 };        // translated text is longer
  // Layout of the shown article: sections take 40 px of heading, leaves LEAF[lang].
  function layout() {
    const shown = root.getAttribute('data-show');
    for (const a of arts) {
      let y = 120;
      const place = (el) => {
        el.absTop = y;
        if (el.kids.length) { y += 40; el.kids.forEach(place); } else y += LEAF[a.lang] || 100;
        el.absBottom = y; y += 10;
      };
      a.els.filter((e) => !e.parent).forEach(place);
      a.hidden = shown != null && a.lang !== shown;
    }
  }
  for (const a of arts) {
    a.getAttribute = (n) => (n === 'lang' ? a.lang : null);
    a.querySelectorAll = (s) => (s === '[data-label]' ? a.els : []);
    a.querySelector = (s) => (s === 'h1' ? { textContent: a.h1 } : null);
    for (const e of a.els) {
      e.art = a; e.id = e.label; e.cls = new Set();
      e.classList = { add: (c) => e.cls.add(c), remove: (c) => e.cls.delete(c) };
      e.getAttribute = (n) => (n === 'data-label' ? e.label : null);
      e.removeAttribute = (n) => { if (n === 'id') e.id = null; };
      e.querySelector = (s) => (s === '[data-label]' ? e.kids[0] || null : null);
      e.getBoundingClientRect = () => { layout(); return a.hidden ? { top: 0, bottom: 0, left: 0 } : { top: e.absTop - state.scrollY, bottom: e.absBottom - state.scrollY, left: 70 }; };
      e.scrollIntoView = () => { layout(); state.scrollY = e.absTop; state.scrolled = e; };
    }
  }
  const btns = [...new Set([...html.matchAll(/data-set-lang="(\w+)"/g)].map((x) => x[1]))].map((l) => {
    const b = { l, pressed: null, getAttribute: (n) => (n === 'data-set-lang' ? l : null), setAttribute: (n, v) => { if (n === 'aria-pressed') b.pressed = v; } };
    return b;
  });
  const store = scen.stored ? { 'opsx-explain-lang': scen.stored } : {};
  const hooks = {};
  const url = new URL('http://127.0.0.1:1/1/' + (scen.search || '') + (scen.hash || ''));
  const loc = {
    get search() { return url.search; }, get hash() { return url.hash; }, get pathname() { return url.pathname; }, get href() { return url.href; },
    set hash(h) { url.hash = h; (hooks['w:hashchange'] || []).forEach((f) => f()); },
    reload() { state.reloads++; },
  };
  const all = () => arts.flatMap((a) => a.els);
  const doc = {
    documentElement: root, title: '', body: { appendChild() {} },
    querySelectorAll(s) {
      if (s === 'article[lang]') return arts;
      if (s === '[data-set-lang]') return btns;
      if (s === '.opsx-target') return all().filter((e) => e.cls.has('opsx-target'));
      return [];
    },
    getElementById: (i) => all().find((e) => e.id === i) || null,
    addEventListener(t, f) { (hooks[t] = hooks[t] || []).push(f); },
  };
  const timers = [];
  const ctx = {
    document: doc, location: loc, console, URL, URLSearchParams, decodeURIComponent, String,
    navigator: { language: scen.navlang || 'en-US' },
    localStorage: { getItem: (k) => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } },
    history: { replaceState(_s, _t, u) { const n = new URL(u, url.href); url.search = n.search; url.hash = n.hash; } },
    performance: { getEntriesByType: () => [] },
    matchMedia: () => ({ matches: false }),
    fetch: (...a) => { state.requests++; return scen.fetch ? scen.fetch(...a) : new Promise(() => {}); },
    setTimeout: (f) => { timers.push(f); return timers.length; },
    scrollBy: (x, y) => { state.scrollY += y; },
  };
  Object.defineProperty(ctx, 'scrollY', { get: () => state.scrollY });
  ctx.window = ctx;
  ctx.addEventListener = (t, f) => { (hooks['w:' + t] = hooks['w:' + t] || []).push(f); };
  vm.createContext(ctx);
  return {
    state, store, arts, root, btns, doc, loc, timers, layout,
    run(src) { vm.runInContext(src, ctx); },
    load() { (hooks.DOMContentLoaded || []).forEach((f) => f()); },
    click(l) { const b = btns.find((x) => x.l === l); (hooks.click || []).forEach((f) => f({ target: { closest: (s) => (s === '[data-set-lang]' ? b : null) } })); },
    el: (lang, label) => arts.find((a) => a.lang === lang).els.find((e) => e.label === label),
    owners(label) { return all().filter((e) => e.id === label).map((e) => e.art.lang); },
    target() { const t = all().find((e) => e.cls.has('opsx-target')); return t ? `${t.art.lang}:${t.label}` : null; },
  };
}

function langPage(scen) {
  const p = makePage(scen);
  p.run(scripts[0]);
  p.load();
  return p;
}

// ---------------------------------------------------------------------------

if (mode === 'lang') {
  let p = langPage({ navlang: 'en-US' });
  ok('English browser: English shown, P1 id only in English', p.root.getAttribute('data-show') === 'en' && p.owners('P1').join() === 'en' && p.btns.find((b) => b.l === 'en').pressed === 'true' && p.doc.title === 'TITLE_EN');
  p.click('pt');
  ok('click PT: Portuguese shown, stored, ids moved, no request or reload', p.root.getAttribute('data-show') === 'pt' && p.store['opsx-explain-lang'] === 'pt' && p.owners('P1').join() === 'pt' && p.state.requests === 0 && p.state.reloads === 0 && p.doc.title === 'TITLE_PT');
  ok('click PT without ?lang= leaves the URL unchanged', !p.loc.href.includes('lang='), p.loc.href);

  p = langPage({ navlang: 'pt-BR' });
  ok('pt-BR browser: Portuguese first', p.root.getAttribute('data-show') === 'pt');
  p = langPage({ navlang: 'en-US', stored: 'pt' });
  ok('remembered choice wins over the browser language', p.root.getAttribute('data-show') === 'pt');
  p = langPage({ navlang: 'pt-BR', stored: 'pt', search: '?lang=en', hash: '#P2' });
  ok('?lang=en wins, #P2 lands on the English P2', p.root.getAttribute('data-show') === 'en' && p.target() === 'en:P2' && p.state.scrollY === p.el('en', 'P2').absTop, `${p.target()} ${p.state.scrollY}`);
  p.click('pt');
  ok('switch with #P2: ?lang= rewritten, the Portuguese P2 is the target', p.loc.href.includes('lang=pt') && p.loc.hash === '#P2' && p.target() === 'pt:P2' && p.state.scrollY === p.el('pt', 'P2').absTop, `${p.loc.href} ${p.target()}`);
  p.loc.hash = '#D1';
  ok('hashchange lands on the shown language', p.target() === 'pt:D1');

  // Hand-over without a #label: the block at the top of the screen stays there.
  p = langPage({ navlang: 'en-US' });
  p.layout();
  const leaf = p.arts[0].els.filter((e) => !e.kids.length).at(-1);       // last leaf (inside a nested section)
  p.state.scrollY = leaf.absTop + 12;                                       // 12 px into it
  p.click('pt');
  const pl = p.el('pt', leaf.label); p.layout();
  ok(`switch without #label keeps ${leaf.label} at the top (hand-over by label)`, p.root.getAttribute('data-show') === 'pt' && pl.absTop - p.state.scrollY === -12 && pl.absTop !== leaf.absTop, `scrollY ${p.state.scrollY}, ${leaf.label} en ${leaf.absTop} pt ${pl.absTop}`);
  p.click('en');
  ok('and back: the same block in English', leaf.absTop - p.state.scrollY === -12, `scrollY ${p.state.scrollY}`);
  const sec = p.arts[0].els.find((e) => e.kids.length);                     // a section, its heading at the top
  p.state.scrollY = sec.absTop - 30;
  p.click('pt');
  p.layout();
  ok(`a section heading below the top keeps its place (${sec.label})`, p.el('pt', sec.label).absTop - p.state.scrollY === 30, `scrollY ${p.state.scrollY}`);
  p = langPage({ navlang: 'en-US' });
  p.click('pt');
  ok('at the top of the page a switch stays at the top', p.state.scrollY === 0);
} else if (mode === 'poll') {
  const pollSrc = scripts.find((s) => s.includes("method:") && s.includes('HEAD'));
  ok('page has a HEAD poll script', !!pollSrc);
  if (pollSrc) {
    const queue = [];
    const resp = (status, h, redirected = false) => ({ ok: status >= 200 && status < 300, status, redirected, headers: { get: (k) => h[k] ?? null } });
    const p = makePage({ fetch: () => { const r = queue.shift(); return r instanceof Error ? Promise.reject(r) : Promise.resolve(r); } });
    const tick = async () => { await new Promise((r) => setImmediate(r)); const f = p.timers.shift(); if (f) f(); await new Promise((r) => setImmediate(r)); };
    const page = { ETag: '"aaa"', 'Last-Modified': 'Sun, 11 Oct 2026 10:00:00 GMT', 'Content-Length': '500' };
    queue.push(resp(200, page));                                       // first poll, on load: baseline
    p.run(pollSrc);
    await new Promise((r) => setImmediate(r));
    ok('first answer is the baseline (no reload, next poll scheduled)', p.state.reloads === 0 && p.timers.length === 1);
    queue.push(resp(421, { 'Content-Length': '20' }));
    await tick();
    ok('a 421 (host not yet allowed) does not reload', p.state.reloads === 0 && p.timers.length === 1);
    queue.push(resp(502, { 'Content-Length': '0' }));
    await tick();
    ok('a 5xx from the proxy does not reload', p.state.reloads === 0 && p.timers.length === 1);
    queue.push(resp(200, { 'Content-Length': '900' }, true));
    await tick();
    ok('a redirect (login) does not reload', p.state.reloads === 0 && p.timers.length === 1);
    queue.push(new Error('offline'));
    await tick();
    ok('a network error keeps polling', p.state.reloads === 0 && p.timers.length === 1);
    queue.push(resp(200, page));
    await tick();
    ok('the same page after errors does not reload', p.state.reloads === 0 && p.timers.length === 1);
    queue.push(resp(200, { ...page, ETag: '"bbb"' }));
    await tick();
    ok('same second and length, new content hash: reloads', p.state.reloads === 1);
  }
} else {
  console.error(`unknown mode ${mode}`); process.exit(2);
}
process.exit(failed ? 1 : 0);
