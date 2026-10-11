// Scroll hand-over sim: runs the template's first inline <script> in a DOM stand-in with a
// layout where the PT article has taller blocks than the EN one (like a translation).
// usage: node handover.js <template.html> <label> <offset-px>
// Prints JSON {label, enTop, ptTop, scrollBefore, scrollAfter, topAfter, expectedTop, shown}
const fs = require('fs'), vm = require('vm');
const [, , file, label, offs] = process.argv;
const off = Number(offs || 12);
const html = fs.readFileSync(file, 'utf8');
const H = { en: 100, pt: 150 };
const state = { scrollY: 0 };
const arts = [];
const re = /<article lang="(\w+)">([\s\S]*?)<\/article>/g; let m;
while ((m = re.exec(html))) {
  const a = { lang: m[1], els: [], h1: (/<h1>([^<]*)<\/h1>/.exec(m[2]) || [])[1] || '' };
  const r2 = /data-label="([^"]+)"/g; let k, y = 100;
  while ((k = r2.exec(m[2]))) { a.els.push({ label: k[1], id: k[1], art: a, absTop: y, absBottom: y + H[a.lang] - 10, cls: new Set() }); y += H[a.lang]; }
  a.getAttribute = n => n === 'lang' ? a.lang : null;
  a.querySelectorAll = s => s === '[data-label]' ? a.els : [];
  a.querySelector = s => s === 'h1' ? { textContent: a.h1 } : null;
  arts.push(a);
}
const root = { attrs: {}, lang: '', setAttribute(n, v) { this.attrs[n] = String(v); }, getAttribute(n) { return this.attrs[n] ?? null; } };
const hidden = a => root.attrs['data-show'] != null && a.lang !== root.attrs['data-show'];
for (const a of arts) for (const e of a.els) {
  e.classList = { add: c => e.cls.add(c), remove: c => e.cls.delete(c) };
  e.getAttribute = n => n === 'data-label' ? e.label : null;
  e.removeAttribute = n => { if (n === 'id') e.id = null; };
  e.querySelector = () => null;
  e.getBoundingClientRect = () => hidden(a) ? { top: 0, bottom: 0, left: 0 } : { top: e.absTop - state.scrollY, bottom: e.absBottom - state.scrollY, left: 70 };
  e.scrollIntoView = () => { state.scrollY = e.absTop; };
}
const btns = [...new Set([...html.matchAll(/data-set-lang="(\w+)"/g)].map(x => x[1]))].map(l => {
  const b = { l, getAttribute: n => n === 'data-set-lang' ? l : null, setAttribute() {} }; return b; });
const hooks = {}, store = {};
const url = new URL('http://127.0.0.1:1/1/');
const loc = { get search() { return url.search; }, get hash() { return url.hash; }, get pathname() { return url.pathname; }, get href() { return url.href; }, reload() {} };
const all = () => arts.flatMap(a => a.els);
const doc = { documentElement: root, title: '', body: { appendChild() {} },
  querySelectorAll(s) { return s === 'article[lang]' ? arts : s === '[data-set-lang]' ? btns : s === '.opsx-target' ? all().filter(e => e.cls.has('opsx-target')) : []; },
  getElementById: i => all().find(e => e.id === i) || null,
  addEventListener(t, f) { (hooks[t] = hooks[t] || []).push(f); } };
const ctx = { document: doc, location: loc, console, URL, URLSearchParams, decodeURIComponent, String,
  navigator: { language: 'en-US' },
  localStorage: { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } },
  history: { replaceState(_s, _t, u) { const n = new URL(u, url.href); url.search = n.search; url.hash = n.hash; } },
  performance: { getEntriesByType: () => [] }, matchMedia: () => ({ matches: false }),
  fetch: () => new Promise(() => {}), setTimeout: () => 0,
  scrollBy: (x, y) => { state.scrollY += y; }, scrollTo: (x, y) => { state.scrollY = typeof x === 'object' ? x.top : y; } };
Object.defineProperty(ctx, 'scrollY', { get: () => state.scrollY });
Object.defineProperty(ctx, 'pageYOffset', { get: () => state.scrollY });
ctx.window = ctx; ctx.addEventListener = (t, f) => { (hooks['w:' + t] = hooks['w:' + t] || []).push(f); };
vm.createContext(ctx);
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x => x[1]);
vm.runInContext(scripts[0], ctx);
(hooks.DOMContentLoaded || []).forEach(f => f());
const en = arts.find(a => a.lang === 'en').els.find(e => e.label === label);
const pt = arts.find(a => a.lang === 'pt').els.find(e => e.label === label);
if (!en || !pt) { console.log(JSON.stringify({ error: 'label ' + label + ' missing' })); process.exit(0); }
state.scrollY = en.absTop + off;
const before = state.scrollY;
const b = btns.find(x => x.l === 'pt');
(hooks.click || []).forEach(f => f({ target: { closest: s => s === '[data-set-lang]' ? b : null } }));
console.log(JSON.stringify({ label, enTop: en.absTop, ptTop: pt.absTop, scrollBefore: before, scrollAfter: state.scrollY,
  topAfter: pt.absTop - state.scrollY, expectedTop: -off, shown: root.attrs['data-show'] }));
