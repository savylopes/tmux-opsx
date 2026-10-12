---
name: explain
description: "Turn a topic from the current agent session into a clean, diagrammed web page written by a read-only full-context fork and served from this machine through /expose (login-protected URL, share links), so the user can read it on any device, hand it to a client, and refine it by talking to the fork ('expand P7', 'the arrow in D2 is wrong'). Every page is bilingual (English and Portuguese, EN / PT switch) and every block carries a stable label (S P D T C N), the same in both languages. Works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI inside tmux. Use when the user types /explain, asks to 'explain this as a page', 'make a web page explaining', 'diagram this for a client'. Also /explain share, /explain list, /explain stop. Trigger: /explain"
trigger: /explain
---

# /explain

Open a **read-only fork** of this session (see `/fork`) whose only job is to write **one self-contained web page** about a topic, in **English and Portuguese** (one EN / PT switch, the same block labels in both). The page is served from this machine by the project's explain server and published once through `/expose` at `https://explain--<project>.<domain>/<id>/`, behind the expose login. The user reads it anywhere, refines it by talking to the fork pane by label, and shares it with a share link. Pages persist as a library.

Requires tmux and the `/fork` skill. `/expose` (`install.sh --expose-domain <domain>`) is needed for URLs that work on other devices and for sharing; without it the page is served on `http://127.0.0.1:<port>/<id>/` only.

## Usage

| Command | What it does |
|---|---|
| `/explain "<topic>"` | open a page fork for the topic (side pane), start the server + exposure if needed, print the page URL |
| `/explain --window "<topic>"` / `--vertical` | the fork in a new window / split top-bottom |
| `/explain --cli <c> "<topic>"` / `--model <m>` | child CLI / model, as for `/fork` |
| `/explain share [--for <r>] [--ttl <d>]` | share link for the explain host (`expose.sh share explain …`); `--list`, `--revoke <r\|id\|all>` |
| `/explain list` | the project's pages (id, created, fork, title), server state and URL |
| `/explain stop` | remove the exposure and the server window; **pages are kept** |

`/explain` with no topic: ask the user for one and open nothing.

## The script

Resolve `explain.sh` once, like `fork.sh` (for Claude Code: `~/.claude/skills/explain/explain.sh`):

```bash
EXPLAIN_SH=$(ls ~/.claude/skills/explain/explain.sh ~/.cursor/skills/explain/explain.sh ~/.agents/skills/explain/explain.sh \
  ~/.codex/skills/explain/explain.sh ~/.config/opencode/skills/explain/explain.sh ~/.gemini/skills/explain/explain.sh 2>/dev/null | head -n1)
```

```
explain.sh open "<topic>" [--window] [--vertical] [--cli <c>] [--model <m>]
                [--parent-model <m>] [--brief-only]            [< notes]
explain.sh native [--cli <c>] [--brief-only]       (= fork.sh native)
explain.sh share [--for <r>] [--ttl <d>] [--list] [--revoke <r|id|all>]
explain.sh list | stop | serve | root
```

Run it from the project directory (it derives `<project>` from the main checkout's folder name, the same for every worktree). Never start a web server, `tmux new-window` or `expose.sh up` for pages yourself.

## Parent: `/explain "<topic>"`

1. **Ask which brief to write**: `"$EXPLAIN_SH" native [--cli <c>]` (same `--cli` you will pass to `open`). `full …` → the fork inherits this whole conversation; `brief …` → it knows only what you write.
2. **Write the notes** (stdin of `open`, quoted heredoc). `explain.sh` itself adds the topic, the page URL, the library URL and the **HTML template below**, and `fork.sh` adds the fork and page protocols, so the notes only carry what the fork cannot know:
   - always: what to emphasise, the audience if the user said ("for the client", "for a new dev"), sections or diagrams the user asked for;
   - in `brief` mode also a `## Context` section: 5–15 lines from this conversation (goal, relevant files with line numbers, decisions, current state). Summarise, don't research. Never include secrets.

   If you need a modified template, paste your version of it into the notes (any notes containing `data-label` replace the default template).

   ```bash
   "$EXPLAIN_SH" open "<topic>" --parent-model <your own model id> <<'EOF'
   ## Focus
   - <what the page must explain, emphasis, audience>

   ## Context
   - <brief mode only: 5–15 lines>
   EOF
   ```

   Pass `--window`, `--vertical`, `--cli`, `--model` only when the user asked. Always pass `--parent-model <your own model id>` (as for `/fork`).
3. **Report in one sentence**: the page URL (the last output line, `page <id> <url>`) and the fork line (`fork <id> pane <%N> cli <cli> model <m>`), e.g. "Page 3 is being written at https://explain--shop.dev.example.com/3/ by fork 2 in the pane on the right; ask it for changes by label (\"expand P7\"), it reloads by itself." If the output has a `# local only` line, add that `/expose` is not configured and the URL works on this machine only (`install.sh --expose-domain <domain>`). Then continue with your own work; do not poll the fork.

The fork pane is the only way to change the page. Do not write or edit pages yourself, and do not paste the page into this conversation.

## Talking to the page by label

Every block has a visible label in the left margin and an HTML id equal to it; clicking a label copies `#<label>`, so `<url>#P7` deep-links to it. Labels are the same in the English and the Portuguese version of the page (EN / PT switch at the top, `?lang=en|pt` in a link):

| Prefix | Block |
|---|---|
| `S<n>` (`S1.2` nested) | section |
| `P<n>` | paragraph |
| `D<n>` | diagram (Mermaid, inline SVG or ASCII) |
| `T<n>` | table |
| `C<n>` | code block |
| `N<n>` | callout / note |

The user tells the **fork pane** what to change: "expand P7", "D2: the arrow from cache to db is wrong", "add a table after S3 comparing the options", "drop N2". The fork rewrites the whole page, both languages, with one `fork.sh page`, applies every change to the English and the Portuguese article alike, keeps every existing label (an edited block keeps its label, new blocks get the next unused number, removed labels are never reused) and records them in `manifest.tsv` beside the page (`label<TAB>one-line summary`), which it reads before every rewrite. The open browser reloads within a few seconds (it polls the page's `ETag` and `Last-Modified` every 2 s and ignores error answers, so a page open on a phone never reloads into an error).

## Sharing, library, stop

- `"$EXPLAIN_SH" share --for acme --ttl 3d` → a share link for the whole explain host of this project (**every page in the library**, not one page), last line of output. Tell the user so before handing it to a client. `--list` shows links, `--revoke <r|id|all>` removes them. Give the user the link; do not open it.
- `"$EXPLAIN_SH" list` → pages, server state, URL. The library index is also the root URL `https://explain--<project>.<domain>/`.
- `"$EXPLAIN_SH" stop` → `expose.sh down explain`, kills the `ox >explain` window (tag `@opsx_explain=<project>`), keeps every page. The next `/explain` starts it again. `/opsx-run` `close-all` never touches it.

Pages live in `${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/<id>/` (`index.html`, `manifest.tsv`, `.meta`) and survive `fork.sh close` and `stop`. They are never written into the project checkout.

## Page template

`explain.sh open` appends this skeleton to the brief. The fork keeps the `<style>`, the language switch (`<nav class="opsx-lang">`), every `<script>` block and the Mermaid script tag (exact version and `integrity` hash, which the server's Content-Security-Policy allows), and replaces the titles and the content of both articles. Labels are drawn in the margin from `data-label` by CSS; a click in the margin copies `#<label>`; the page reloads itself when the served file changes (HEAD polling of `ETag` — a content hash — `Last-Modified` and `Content-Length` every 2 s; only a direct 2xx answer counts, so errors and login redirects never replace the page); Mermaid comes from a CDN, pinned with Subresource Integrity and sent without a referrer (the diagram source stays readable as text when the CDN is unreachable).

**Two languages.** Every page carries the whole explanation twice: `<article lang="en">` (English) and `<article lang="pt">` (Portuguese), each with its own `<h1>` and the **same labelled blocks in the same order** (same `data-label`, same `id`; the source repeats each id once per language on purpose). The EN / PT switch at the top shows one article without a reload and remembers the choice in `localStorage`; the first choice is `?lang=en|pt` in the URL, else the remembered one, else Portuguese when the browser language starts with `pt`, else English. The script keeps the ids only on the shown article, so `<url>#P7` (or `<url>?lang=pt#P7`) lands on P7 in the shown language and click-to-copy works in both. Without a `#label` in the URL, a switch keeps the reader on the same block: the labelled block at the top of the screen is found by its label in the other article and scrolled to the same place. Diagrams are duplicated (node text translated, same structure, same `D<n>` in both articles); Mermaid renders only the shown article's diagrams, the other ones on the first switch. `<title>` holds both titles, `English title · Título em português` (the library index shows it as is; the tab shows the shown article's `<h1>`). Without JavaScript both articles are shown one after the other.

<!-- explain-page-template -->
```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TITLE_EN · TITLE_PT</title>
<style>
:root{--fg:#1d1d1f;--muted:#8a8a8e;--bg:#fff;--soft:#f5f5f7;--line:#e3e3e6;--accent:#0b57d0;--note:#fff8e1;--note-line:#f0c040}
@media (prefers-color-scheme:dark){:root{--fg:#ececf1;--muted:#8d8d96;--bg:#141416;--soft:#1e1e22;--line:#2e2e34;--accent:#8ab4f8;--note:#2a2410;--note-line:#a07c10}}
*{box-sizing:border-box}
body{font:17px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif;color:var(--fg);background:var(--bg);max-width:46rem;margin:2.5rem auto;padding:0 1rem 4rem 4.5rem}
h1{font-size:1.9rem;line-height:1.2;margin:0 0 .3rem}h2{font-size:1.35rem;margin:2.2rem 0 .6rem}h3{font-size:1.1rem;margin:1.6rem 0 .5rem}
.subtitle{color:var(--muted);margin:0 0 2rem}
a{color:var(--accent)}code{font:.88em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--soft);padding:.1em .3em;border-radius:4px}
pre{font:.85rem/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--soft);padding:.9rem 1rem;border-radius:8px;overflow:visible}
pre code{display:block;overflow-x:auto;background:none;padding:0}
table{border-collapse:collapse;width:100%;font-size:.95rem}th,td{text-align:left;padding:.45rem .6rem;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600}
figure{margin:1.2rem 0}figcaption{color:var(--muted);font-size:.85rem;margin-top:.4rem}
pre.mermaid{background:none;text-align:center}
aside.note{background:var(--note);border-left:3px solid var(--note-line);padding:.7rem 1rem;border-radius:4px;margin:1.2rem 0}
[data-label]{position:relative;scroll-margin-top:3rem}
[data-label]::before{content:attr(data-label);position:absolute;left:-4.3rem;top:.2rem;width:3.6rem;text-align:right;font:600 11px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted);cursor:pointer;white-space:nowrap}
section[data-label]::before{top:.55rem}
[data-label].opsx-target{outline:2px solid var(--accent);outline-offset:4px;border-radius:2px}
article[lang]+article[lang]{border-top:1px solid var(--line);margin-top:3rem;padding-top:1rem}
html[data-show="en"] article[lang]:not([lang="en"]),html[data-show="pt"] article[lang]:not([lang="pt"]){display:none}
html[data-show] article[lang]+article[lang]{border-top:0;margin-top:0;padding-top:0}
.opsx-lang{position:fixed;top:.75rem;right:1rem;z-index:10;display:flex;gap:2px;padding:2px;background:var(--soft);border:1px solid var(--line);border-radius:999px}
.opsx-lang button{font:600 12px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted);background:none;border:0;border-radius:999px;padding:.4rem .65rem;cursor:pointer}
.opsx-lang button[aria-pressed="true"]{background:var(--bg);color:var(--fg);box-shadow:0 0 0 1px var(--line)}
#opsx-toast{position:fixed;bottom:1rem;left:50%;transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:.35rem .8rem;border-radius:6px;font-size:.85rem;opacity:0;transition:opacity .2s;pointer-events:none}
@media (max-width:40rem){body{padding-left:3rem;font-size:16px}[data-label]::before{left:-3rem;width:2.6rem;font-size:10px}}
</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js" integrity="sha384-EOXBFmc3gx5mb+vn0vPvvGqACToJD24hhacX5Yx+8NUUQrHIle/Qi5Bg9o3zKwW2" crossorigin="anonymous" referrerpolicy="no-referrer"></script>
<script>
if (window.mermaid) mermaid.initialize({startOnLoad: false, theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'});
// Language: ?lang=en|pt, else the remembered choice, else the browser language (pt* -> pt), else en.
// Both articles carry the same labels and ids; only the shown article keeps its ids, so #P1 lands on P1 in that language.
(function () {
  var LANGS = ['en', 'pt'], KEY = 'opsx-explain-lang', root = document.documentElement;
  function ok(l) { return LANGS.indexOf(l) >= 0; }
  function pick() {
    var q = null; try { q = new URLSearchParams(location.search).get('lang'); } catch (x) {}
    if (ok(q)) return q;
    try { var s = localStorage.getItem(KEY); if (ok(s)) return s; } catch (x) {}
    return /^pt\b/i.test(navigator.language || '') ? 'pt' : 'en';
  }
  function jump() {
    var old = document.querySelectorAll('.opsx-target');
    for (var i = 0; i < old.length; i++) old[i].classList.remove('opsx-target');
    var h = ''; try { h = decodeURIComponent(location.hash.slice(1)); } catch (x) {}
    var el = h && document.getElementById(h);
    if (el) { el.classList.add('opsx-target'); el.scrollIntoView(); }
  }
  function show(lang, scroll) {
    var arts = document.querySelectorAll('article[lang]'), cur = null, i, j;
    for (i = 0; i < arts.length; i++) if (arts[i].getAttribute('lang') === lang) cur = arts[i];
    if (!cur && arts.length) { cur = arts[0]; lang = cur.getAttribute('lang'); }
    root.setAttribute('data-show', lang); root.lang = lang;
    for (i = 0; i < arts.length; i++) {
      var els = arts[i].querySelectorAll('[data-label]');
      for (j = 0; j < els.length; j++) {
        if (arts[i] === cur) els[j].id = els[j].getAttribute('data-label'); else els[j].removeAttribute('id');
      }
    }
    var btns = document.querySelectorAll('[data-set-lang]');
    for (i = 0; i < btns.length; i++) btns[i].setAttribute('aria-pressed', String(btns[i].getAttribute('data-set-lang') === lang));
    var h1 = cur && cur.querySelector('h1'); if (h1) document.title = h1.textContent;
    var run = null;
    if (window.mermaid && cur) { try { run = mermaid.run({nodes: cur.querySelectorAll('pre.mermaid:not([data-processed])')}); } catch (x) {} }
    if (scroll) { jump(); if (run && run.then) run.then(jump, jump); }
    return run;
  }
  // Without a #label, a switch keeps the reader on the same block: the innermost labelled block
  // at the top of the viewport (else the section around it) and its offset, found again by label.
  function anchor() {
    try {
      if (!window.scrollY) return null;
      var arts = document.querySelectorAll('article[lang]'), cur = null, els, a = null, i, r;
      for (i = 0; i < arts.length; i++) if (arts[i].getAttribute('lang') === root.getAttribute('data-show')) cur = arts[i];
      els = cur ? cur.querySelectorAll('[data-label]') : [];
      for (i = 0; i < els.length; i++) {
        r = els[i].getBoundingClientRect();
        if (r.bottom <= 8) continue;
        a = {label: els[i].getAttribute('data-label'), top: r.top};
        if (r.top > 8 || !els[i].querySelector('[data-label]')) break;
      }
      return a;
    } catch (x) { return null; }
  }
  function restore(a) {
    try { var el = document.getElementById(a.label); if (el) window.scrollBy(0, el.getBoundingClientRect().top - a.top); } catch (x) {}
  }
  var first = pick(); root.setAttribute('data-show', first); root.lang = first;
  document.addEventListener('DOMContentLoaded', function () {
    var nav = performance.getEntriesByType ? performance.getEntriesByType('navigation')[0] : null;
    show(root.getAttribute('data-show'), !(nav && nav.type === 'reload'));
  });
  document.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('[data-set-lang]');
    if (!b) return;
    var l = b.getAttribute('data-set-lang');
    try { localStorage.setItem(KEY, l); } catch (x) {}
    try { var u = new URL(location.href); if (u.searchParams.has('lang')) { u.searchParams.set('lang', l); history.replaceState(null, '', u.href); } } catch (x) {}
    var a = location.hash ? null : anchor(), run = show(l, !a);
    if (a) { restore(a); if (run && run.then) run.then(function () { restore(a); }, function () {}); }
  });
  window.addEventListener('hashchange', jump);
})();
</script>
</head>
<body>
<nav class="opsx-lang" aria-label="Language / Idioma"><button type="button" data-set-lang="en" lang="en">EN</button><button type="button" data-set-lang="pt" lang="pt">PT</button></nav>

<article lang="en">
<h1>TITLE_EN</h1>
<p class="subtitle">One-line summary of what this page explains.</p>

<section id="S1" data-label="S1">
<h2>First section</h2>
<p id="P1" data-label="P1">A paragraph. Every block has an id equal to its label.</p>
<figure id="D1" data-label="D1">
<pre class="mermaid">
flowchart LR
  A[Request] --> B{Cached?}
  B -- yes --> C[Return cached]
  B -- no --> D[Fetch] --> C
</pre>
<figcaption>What the diagram shows.</figcaption>
</figure>
<table id="T1" data-label="T1">
<thead><tr><th>Option</th><th>Trade-off</th></tr></thead>
<tbody><tr><td>A</td><td>…</td></tr></tbody>
</table>
<pre id="C1" data-label="C1"><code>example code, HTML-escaped (&lt; &gt; &amp;)</code></pre>
<aside class="note" id="N1" data-label="N1">A callout: caveat, decision, warning.</aside>
<section id="S1.1" data-label="S1.1">
<h3>Nested section</h3>
<p id="P2" data-label="P2">Numbers are per prefix across the whole page, not per section.</p>
</section>
</section>
</article>

<article lang="pt">
<h1>TITLE_PT</h1>
<p class="subtitle">Resumo em uma linha do que esta página explica.</p>

<section id="S1" data-label="S1">
<h2>Primeira seção</h2>
<p id="P1" data-label="P1">Um parágrafo. Cada bloco tem um id igual ao seu rótulo.</p>
<figure id="D1" data-label="D1">
<pre class="mermaid">
flowchart LR
  A[Requisição] --> B{Em cache?}
  B -- sim --> C[Retorna do cache]
  B -- não --> D[Busca] --> C
</pre>
<figcaption>O que o diagrama mostra.</figcaption>
</figure>
<table id="T1" data-label="T1">
<thead><tr><th>Opção</th><th>Compromisso</th></tr></thead>
<tbody><tr><td>A</td><td>…</td></tr></tbody>
</table>
<pre id="C1" data-label="C1"><code>example code, HTML-escaped (&lt; &gt; &amp;)</code></pre>
<aside class="note" id="N1" data-label="N1">Um destaque: ressalva, decisão, aviso.</aside>
<section id="S1.1" data-label="S1.1">
<h3>Seção aninhada</h3>
<p id="P2" data-label="P2">A numeração é por prefixo na página inteira, não por seção.</p>
</section>
</section>
</article>

<span id="opsx-toast"></span>
<script>
// Click a margin label: copy "#<label>" and deep-link to it (works in either language).
document.addEventListener('click', function (e) {
  var el = e.target.closest && e.target.closest('[data-label]');
  if (!el || e.clientX >= el.getBoundingClientRect().left) return;
  var tag = '#' + el.getAttribute('data-label');
  history.replaceState(null, '', tag);
  var toast = document.getElementById('opsx-toast');
  function done(ok) { toast.textContent = ok ? 'copied ' + tag : tag; toast.style.opacity = 1; setTimeout(function () { toast.style.opacity = 0; }, 1200); }
  if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(tag).then(function () { done(true); }, function () { done(false); }); }
  else { var t = document.createElement('textarea'); t.value = tag; document.body.appendChild(t); t.select(); var ok = false; try { ok = document.execCommand('copy'); } catch (x) {} t.remove(); done(ok); }
});
// Reload when the served page changes: HEAD poll every 2 s of ETag (content hash), Last-Modified
// and Content-Length. Only a direct 2xx answer counts; errors (421, 5xx, proxy) and redirects
// (login) are ignored, so the page never reloads into an error or a login screen.
(function () {
  var last = null;
  function poll() {
    fetch(location.pathname, {method: 'HEAD', cache: 'no-store'}).then(function (r) {
      if (r.ok && !r.redirected) {
        var m = [r.headers.get('ETag'), r.headers.get('Last-Modified'), r.headers.get('Content-Length')].join('|');
        if (last !== null && m !== last) { location.reload(); return; }
        last = m;
      }
      setTimeout(poll, 2000);
    }).catch(function () { setTimeout(poll, 2000); });
  }
  poll();
})();
</script>
</body>
</html>
```

## Rules

- One page per fork; one fork per page. Every page is bilingual (English and Portuguese, identical labels); the user can ask the fork for wording changes in either language by label ("PT P3: use 'implantação'"). To explain another topic, run `/explain` again (a new page id).
- The fork is read-only apart from `fork.sh page` (page and manifest) and `fork.sh return`; on CLIs whose read-only mode blocks `fork.sh page` (Gemini, Cursor, OpenCode plan, Codex without approval), the fork says the page cannot be written and stops — open the fork with `--cli claude` instead.
- Pages are served behind the expose login; nothing leaves the machine unless the user creates a share link. Never put secrets into a page.
- The server, not the page, enforces the safety rules: it serves only `/`, `/<id>/` and their `index.html` (no listings, dotfiles, manifests or `launch.sh`), answers only to `127.0.0.1`, `localhost` and the expose host, and sends a strict Content-Security-Policy (inline scripts and the pinned Mermaid file only; no external images, fonts, styles, frames or fetches; no forms) with `Referrer-Policy: no-referrer`. Keep the template's Mermaid tag exactly (pinned version and `integrity` hash) or diagrams will not render.
