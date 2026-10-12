// Headless check of the /explain page language switch (EN / PT).
// Usage: node tests/explain-lang-check.mjs <chrome-binary> <page-url-without-query> [<page-file>]
// With <page-file>, also checks that a rewrite reloads the page in the chosen language.
// Drives a real headless Chromium over CDP (node >= 22 WebSocket, no npm deps)
// against a page served by the real explain server, so the server's CSP is in
// force. Prints "PASS <name>" / "FAIL <name>" lines; exit 1 on any failure.
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, base, pageFile] = process.argv.slice(2);
if (!chrome || !base) { console.error('usage: explain-lang-check.mjs <chrome> <url>'); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failed = 0;
const ok = (name, cond, info = '') => { console.log(`${cond ? 'PASS' : 'FAIL'} lang: ${name}${cond || !info ? '' : ` (${info})`}`); if (!cond) failed++; };

async function launch(extraArgs) {
  const dir = mkdtempSync(join(tmpdir(), 'explain-chrome-'));
  const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu', '--no-first-run',
    '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${dir}`, ...extraArgs, 'about:blank'],
  { stdio: 'ignore' });
  const portFile = join(dir, 'DevToolsActivePort');
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  const port = readFileSync(portFile, 'utf8').split('\n')[0];
  let targets = [];
  for (let i = 0; i < 50; i++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch { /* not yet */ }
    if (targets.some((t) => t.type === 'page')) break;
    await sleep(100);
  }
  const page = targets.find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  let seq = 0; const pending = new Map(); const listeners = [];
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
    else listeners.forEach((f) => f(msg));
  };
  const send = (method, params = {}) => new Promise((r) => { const id = ++seq; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
  const close = () => { try { ws.close(); } catch { /* ignore */ } proc.kill('SIGKILL'); setTimeout(() => rmSync(dir, { recursive: true, force: true }), 300); };
  return { send, listeners, close };
}

async function run(b, preload) {
  await b.send('Page.enable');
  await b.send('Runtime.enable');
  await b.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `window.__errs = []; window.addEventListener('error', function (e) { window.__errs.push(String(e.message)); }); window.__csp = []; document.addEventListener('securitypolicyviolation', function (e) { window.__csp.push(e.violatedDirective + ' ' + e.blockedURI); });${preload || ''}`,
  });
  let pageReqs = 0;
  await b.send('Network.enable');
  b.listeners.push((m) => {
    if (m.method === 'Network.requestWillBeSent' && m.params.request.method === 'GET' && m.params.request.url.split('?')[0].split('#')[0] === base) pageReqs++;
  });
  const ev = async (expr) => (await b.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result.result?.value;
  const go = async (url) => {
    await b.send('Page.navigate', { url: 'about:blank' });
    await sleep(150);
    const loaded = new Promise((r) => b.listeners.push((m) => { if (m.method === 'Page.loadEventFired') r(); }));
    await b.send('Page.navigate', { url });
    await Promise.race([loaded, sleep(10000)]);
    // the about:blank load event can arrive late: wait for this URL to be complete
    for (let i = 0; i < 100; i++) {
      const r = await ev(`document.readyState + ' ' + location.href`);
      if (r === `complete ${url}`) break;
      await sleep(100);
    }
    await sleep(300);
  };
  const state = () => ev(`(() => {
    const vis = (l) => { const a = document.querySelector('article[lang="' + l + '"]'); return !!a && getComputedStyle(a).display !== 'none'; };
    const p1 = document.querySelectorAll('[id="P1"]');
    const t = document.querySelector('.opsx-target');
    return { show: document.documentElement.getAttribute('data-show'), lang: document.documentElement.lang,
      en: vis('en'), pt: vis('pt'), p1: p1.length, p1lang: p1[0] ? p1[0].closest('article').lang : null,
      ids: [...new Set([...document.querySelectorAll('[id]')].map((e) => e.id))].length === document.querySelectorAll('[id]').length,
      target: t ? t.closest('article').lang + ':' + t.getAttribute('data-label') : null,
      pressed: (document.querySelector('[data-set-lang][aria-pressed="true"]') || {}).textContent || null,
      title: document.title, store: (() => { try { return localStorage.getItem('opsx-explain-lang'); } catch (x) { return 'ERR'; } })(),
      href: location.href, csp: window.__csp, ready: document.readyState, errs: window.__errs };
  })()`);
  return { go, ev, state, pageReqs: () => pageReqs };
}

// 1. English browser, fresh profile
{
  const b = await launch(['--lang=en-US']);
  const t = await run(b);
  await t.go(base);
  let s = await t.state();
  ok('default is English for an en browser', s.show === 'en' && s.lang === 'en' && s.en && !s.pt, JSON.stringify(s));
  ok('ids unique in the live DOM, P1 in the English article', s.ids && s.p1 === 1 && s.p1lang === 'en', JSON.stringify(s));
  ok('EN button pressed, title from the English h1', s.pressed === 'EN' && s.title === 'TITLE_EN', JSON.stringify(s));
  ok('no CSP violations on load', s.csp.length === 0, JSON.stringify(s.csp));
  await t.ev('window.__noReload = 1');
  const before = t.pageReqs();
  await t.ev(`document.querySelector('[data-set-lang="pt"]').click()`);
  await sleep(300);
  s = await t.state();
  ok('click PT shows Portuguese without a reload', s.show === 'pt' && s.pt && !s.en && (await t.ev('window.__noReload')) === 1 && t.pageReqs() === before, JSON.stringify(s));
  ok('click PT stores the choice and moves the ids', s.store === 'pt' && s.p1 === 1 && s.p1lang === 'pt' && s.ids && s.pressed === 'PT' && s.title === 'TITLE_PT', JSON.stringify(s));
  ok('click PT leaves a URL without ?lang= unchanged', !s.href.includes('lang='), s.href);
  await t.go(base + '#P1');
  s = await t.state();
  ok('remembered PT after navigation, #P1 lands on the Portuguese P1', s.show === 'pt' && s.target === 'pt:P1' && s.p1lang === 'pt', JSON.stringify(s));
  await t.go(base + '?lang=en#P2');
  s = await t.state();
  ok('?lang=en overrides the remembered choice, #P2 in English', s.show === 'en' && s.target === 'en:P2', JSON.stringify(s));
  await t.ev(`document.querySelector('[data-set-lang="pt"]').click()`);
  await sleep(300);
  s = await t.state();
  ok('switching rewrites an existing ?lang= and keeps the target', s.href.includes('lang=pt') && s.href.endsWith('#P2') && s.target === 'pt:P2', JSON.stringify(s));
  await t.ev(`location.hash = '#D1'`);
  await sleep(200);
  s = await t.state();
  ok('hashchange lands on the shown language', s.target === 'pt:D1', JSON.stringify(s));
  const csp = await t.ev('window.__csp');
  ok('no CSP violations after switching', csp.length === 0, JSON.stringify(csp));
  if (pageFile) {
    await t.ev('window.__noReload = 1');
    appendFileSync(pageFile, '<!-- rewrite -->\n');
    let reloaded = false;
    for (let i = 0; i < 80 && !reloaded; i++) { await sleep(100); reloaded = (await t.ev('window.__noReload')) !== 1 && (await t.ev('document.readyState')) === 'complete'; }
    await sleep(300);
    const r = await t.state();
    ok('a rewrite reloads the page and keeps the chosen language', reloaded && r.show === 'pt' && r.pt && !r.en && r.p1lang === 'pt', JSON.stringify(r));
  }
  const lazy = await t.ev(`!document.querySelector('article[lang="en"] [data-label="D1"] svg')`);
  await t.ev(`document.querySelector('[data-set-lang="en"]').click()`);
  await sleep(1500);
  const merm = await t.ev(`(() => ({ loaded: !!window.mermaid, pt: !!document.querySelector('article[lang="pt"] [data-label="D1"] svg'), en: !!document.querySelector('article[lang="en"] [data-label="D1"] svg') }))()`);
  if (merm.loaded) ok('Mermaid renders only the shown language, the other on first switch', lazy && merm.pt && merm.en, JSON.stringify({ lazy, ...merm }));
  else console.log('SKIP lang: Mermaid not loaded (CDN unreachable from this host)');
  b.close();
}

// 2. Portuguese browser, fresh profile
{
  const b = await launch(['--lang=pt-BR']);
  const t = await run(b, `Object.defineProperty(navigator, 'language', { get: function () { return 'pt-BR'; } });`);
  await t.go(base + '#P1');
  const s = await t.state();
  ok('default is Portuguese for a pt-BR browser, #P1 lands there', s.show === 'pt' && s.target === 'pt:P1' && s.p1 === 1, JSON.stringify(s));
  b.close();
}

// 3. ?lang=pt with an English browser
{
  const b = await launch(['--lang=en-US']);
  const t = await run(b);
  await t.go(base + '?lang=pt#P1');
  const s = await t.state();
  ok('?lang=pt#P1 shows Portuguese and lands on its P1', s.show === 'pt' && s.p1 === 1 && s.p1lang === 'pt' && s.target === 'pt:P1', JSON.stringify(s));
  b.close();
}

await sleep(400);
process.exit(failed ? 1 : 0);
