// Minimal DOM stand-in that runs the page template's first inline <script> (language
// logic) with no browser. usage: node langsim.js <template.html> <scenario>
// Prints JSON describing the state after the scenario.
const fs = require('fs'), vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const scen = JSON.parse(process.argv[3] || '{}'); // {search, hash, stored, navlang, click}
const arts = [];
const re = /<article lang="(\w+)">([\s\S]*?)<\/article>/g; let m;
while ((m = re.exec(html))) {
  const a = { lang: m[1], els: [], h1: (/<h1>([^<]*)<\/h1>/.exec(m[2]) || [])[1] || '' };
  const r2 = /data-label="([^"]+)"/g; let k;
  while ((k = r2.exec(m[2]))) a.els.push({ label: k[1], id: k[1], cls: new Set(), art: a, scrollIntoView() { state.scrolled = this; }, classList: null });
  for (const e of a.els) e.classList = { add: c => e.cls.add(c), remove: c => e.cls.delete(c) };
  a.getAttribute = n => n === 'lang' ? a.lang : null;
  a.querySelectorAll = s => s === '[data-label]' ? a.els : (s === 'pre.mermaid:not([data-processed])' ? [] : []);
  a.querySelector = s => s === 'h1' ? { textContent: a.h1 } : null;
  arts.push(a);
}
for (const a of arts) for (const e of a.els) {
  e.getAttribute = n => n === 'data-label' ? e.label : null;
  e.removeAttribute = n => { if (n === 'id') e.id = null; };
  Object.defineProperty(e, 'idSetter', { value: 0 });
}
// element.id = x works as plain property; removeAttribute sets null
const btns = [...html.matchAll(/data-set-lang="(\w+)"/g)].map(x => x[1]).filter((v, i, s) => s.indexOf(v) === i)
  .map(l => { const b = { l, pressed: null, getAttribute: n => n === 'data-set-lang' ? l : null, setAttribute: (n, v) => { if (n === 'aria-pressed') b.pressed = v; } }; return b; });
const state = { requests: 0, reloads: 0, scrolled: null };
const store = Object.assign({}, scen.stored ? { 'opsx-explain-lang': scen.stored } : {});
const hooks = {};
const root = { attrs: {}, lang: '', setAttribute(n, v) { this.attrs[n] = v; }, getAttribute(n) { return this.attrs[n]; } };
const loc = { search: scen.search || '', hash: scen.hash || '', pathname: '/1/', href: 'http://127.0.0.1:1/1/' + (scen.search || '') + (scen.hash || '') };
const doc = {
  documentElement: root, title: '',
  querySelectorAll(s) {
    if (s === 'article[lang]') return arts;
    if (s === '[data-set-lang]') return btns;
    if (s === '.opsx-target') return arts.flatMap(a => a.els).filter(e => e.cls.has('opsx-target'));
    return [];
  },
  getElementById(i) { return arts.flatMap(a => a.els).find(e => e.id === i) || null; },
  addEventListener(t, f) { (hooks[t] = hooks[t] || []).push(f); },
};
const ctx = {
  document: doc, location: loc, console, URLSearchParams, URL, decodeURIComponent,
  navigator: { language: scen.navlang || 'en-US' },
  localStorage: { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } },
  history: { replaceState() {} }, performance: { getEntriesByType: () => [] },
  matchMedia: () => ({ matches: false }), fetch: () => { state.requests++; return { then() { return { catch() {} }; } }; },
  XMLHttpRequest: function () { state.requests++; }, setTimeout: () => 0,
};
ctx.window = ctx; ctx.window.addEventListener = (t, f) => { (hooks['w:' + t] = hooks['w:' + t] || []).push(f); };
loc.reload = () => { state.reloads++; };
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x => x[1]);
vm.createContext(ctx);
vm.runInContext(scripts[0], ctx);
(hooks.DOMContentLoaded || []).forEach(f => f());
if (scen.click) {
  const b = btns.find(x => x.l === scen.click);
  (hooks.click || []).forEach(f => f({ target: { closest: s => s === '[data-set-lang]' ? b : null } }));
}
const shown = root.attrs['data-show'];
const ids = {};
for (const a of arts) for (const e of a.els) if (e.id) (ids[e.id] = ids[e.id] || []).push(a.lang);
console.log(JSON.stringify({ shown, rootLang: root.lang, stored: store['opsx-explain-lang'] || null,
  idOwners: ids, requests: state.requests, reloads: state.reloads, target: state.scrolled ? state.scrolled.art.lang + ':' + state.scrolled.label : null,
  title: doc.title, pressed: Object.fromEntries(btns.map(b => [b.l, b.pressed])) }));
