---
name: explain
description: "Turn a topic from the current agent session into a designed, diagrammed web page written by a read-only full-context fork and served from this machine through /expose (login-protected URL, share links), so the user can read it on any device, hand it to a client, and refine it by talking to the fork ('expand P7', 'the arrow in D2 is wrong'). Pages are English by default (--lang pt, --lang en,pt for Portuguese or both, with an EN / PT switch) and every block carries a stable label (S P D T C N). Works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI inside tmux. Use when the user types /explain, asks to 'explain this as a page', 'make a web page explaining', 'diagram this for a client'. Also /explain share, /explain list, /explain stop. Trigger: /explain"
trigger: /explain
---

# /explain

Open a **read-only fork** of this session (see `/fork`) whose only job is to write **one self-contained web page** about a topic, in the language the user asked for (English by default; Portuguese, or both with one EN / PT switch and the same block labels in each). The project's pages live in one directory that is published through `/expose` as a directory exposure (Caddy's file server behind the expose login) at `https://explain--<project>.<domain>/<id>/`. The user reads it anywhere, refines it by talking to the fork pane by label, and shares it with a share link. Pages persist as a library.

Requires tmux and the `/fork` skill. `/expose` (`install.sh --expose-domain <domain>`) is needed for the URL: without it nothing serves the pages, `open` prints the page's file path and the fork still writes it.

## Usage

| Command | What it does |
|---|---|
| `/explain "<topic>"` | open a page fork for the topic (side pane), publish the pages directory if needed, print the page URL |
| `/explain --lang <en\|pt\|en,pt> "<topic>"` | the page's language(s); default `en`. `en,pt` writes both with the EN / PT switch |
| `/explain --window "<topic>"` / `--vertical` | the fork in a new window / split top-bottom |
| `/explain --cli <c> "<topic>"` / `--model <m>` | child CLI / model, as for `/fork` |
| `/explain share [--for <r>] [--ttl <d>]` | share link for the explain host (`expose.sh share explain …`); `--list`, `--revoke <r\|id\|all>` |
| `/explain list` | the project's pages (id, created, fork, title), whether they are exposed and the URL |
| `/explain stop` | remove the exposure (`expose.sh down explain`); **pages are kept** |

`/explain` with no topic: ask the user for one and open nothing. The user says "in Portuguese" / "em português" → `--lang pt`; "in both languages" / "bilingual" → `--lang en,pt`.

## The script

Resolve `explain.sh` once, like `fork.sh` (for Claude Code: `~/.claude/skills/explain/explain.sh`):

```bash
EXPLAIN_SH=$(ls ~/.claude/skills/explain/explain.sh ~/.cursor/skills/explain/explain.sh ~/.agents/skills/explain/explain.sh \
  ~/.codex/skills/explain/explain.sh ~/.config/opencode/skills/explain/explain.sh ~/.gemini/skills/explain/explain.sh 2>/dev/null | head -n1)
```

```
explain.sh open "<topic>" [--lang en|pt|en,pt] [--window] [--vertical] [--cli <c>]
                [--model <m>] [--parent-model <m>] [--brief-only]  [< notes]
explain.sh native [--cli <c>] [--brief-only]       (= fork.sh native)
explain.sh share [--for <r>] [--ttl <d>] [--list] [--revoke <r|id|all>]
explain.sh list | stop | serve | root
```

Run it from the project directory (it derives `<project>` from the main checkout's folder name, the same for every worktree). Never run `expose.sh up` for pages yourself, and never start a web server for them: Caddy serves the directory.

## Parent: `/explain "<topic>"`

1. **Ask which brief to write**: `"$EXPLAIN_SH" native [--cli <c>]` (same `--cli` you will pass to `open`). `full …` → the fork inherits this whole conversation; `brief …` → it knows only what you write.
2. **Write the notes** (stdin of `open`, quoted heredoc). `explain.sh` itself adds the topic, the page URL, the library URL, the languages and the **HTML template below** (cut down to one article when one language is asked), and `fork.sh` adds the fork and page protocols, so the notes only carry what the fork cannot know:
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

   Pass `--lang`, `--window`, `--vertical`, `--cli`, `--model` only when the user asked. Always pass `--parent-model <your own model id>` (as for `/fork`).
3. **Report in one sentence**: the page URL (the last output line, `page <id> <url>`) and the fork line (`fork <id> pane <%N> cli <cli> model <m>`), e.g. "Page 3 is being written at https://explain--shop.dev.example.com/3/ by fork 2 in the pane on the right; ask it for changes by label (\"expand P7\"), it reloads by itself." If the output has a `# local only` line, add that `/expose` is not configured, so the page is only a file on this machine (`install.sh --expose-domain <domain>` gives it a URL). Then continue with your own work; do not poll the fork.

The fork pane is the only way to change the page. Do not write or edit pages yourself, and do not paste the page into this conversation.

## Talking to the page by label

Every block has a visible label in the left margin and an HTML id equal to it; clicking a label copies `#<label>`, so `<url>#P7` deep-links to it. On a bilingual page the labels are the same in the English and the Portuguese version (EN / PT switch at the top, `?lang=en|pt` in a link):

| Prefix | Block | Template element |
|---|---|---|
| `S<n>` (`S1.2` nested) | section | `<section>` with its `h2` / `h3` |
| `P<n>` | paragraph | `<p>` (also a list `<ul>`/`<ol>`) |
| `D<n>` | diagram | `<figure>`: inline SVG in a `.frame`, a Mermaid `pre.mermaid`, or an ASCII `pre` |
| `T<n>` | tabular | `.tscroll` table with `.pill` states, `.key` cards, `dl.terms` list |
| `C<n>` | code block | `<pre><code>` |
| `N<n>` | callout / note | `.callout` (accent), `.callout.warn`, `.callout.bad`, `.callout.ok` |

The user tells the **fork pane** what to change: "expand P7", "D2: the arrow from cache to db is wrong", "add a table after S3 comparing the options", "drop N2", "make D1 a Mermaid diagram", "add Portuguese". The fork rewrites the whole page with one `fork.sh page`, applies every change to every language the page carries, keeps every existing label (an edited block keeps its label, new blocks get the next unused number, removed labels are never reused) and records them in `manifest.tsv` beside the page (`label<TAB>one-line summary`), which it reads before every rewrite. The open browser reloads within a few seconds (it polls the page's `ETag` and `Last-Modified` every 2 s and ignores error answers, so a page open on a phone never reloads into an error).

## Sharing, library, stop

- `"$EXPLAIN_SH" share --for acme --ttl 3d` → a share link for the whole explain host of this project (**every page in the library**, not one page), last line of output. Tell the user so before handing it to a client. `--list` shows links, `--revoke <r|id|all>` removes them. Give the user the link; do not open it.
- `"$EXPLAIN_SH" list` → pages, then `exposed: <url>/` or `exposed: no`. The library index is also the root URL `https://explain--<project>.<domain>/`.
- `"$EXPLAIN_SH" stop` → `expose.sh down explain`, keeps every page. The next `/explain` publishes them again.

Pages live in `${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/<id>/` (`index.html`, `index.html.sha256` — its content hash, served as the ETag — `manifest.tsv`, `.meta`) and survive `fork.sh close` and `stop`. They are never written into the project checkout.

## Page template

`explain.sh open` appends this skeleton to the brief (for one language it keeps only that `<article>` and drops the EN / PT switch; the markers `<!-- article:en -->`, `<!-- article:pt -->` and `<!-- lang-switch -->` delimit what is cut). The fork keeps the `<link>` to the fonts, the `<style>` and every `<script>` block, and replaces the titles and the content of the article(s). Labels are drawn in the margin from `data-label` by CSS; a click in the margin copies `#<label>`; the page reloads itself when the served file changes (HEAD polling of `ETag` — a content hash — `Last-Modified` and `Content-Length` every 2 s; only a direct 2xx answer counts, so errors and login redirects never replace the page).

**The design.** One visual system, the same on every page: Red Hat Display for headings, Red Hat Text for prose, Red Hat Mono for labels, keys and code (Google Fonts, `display=swap`, system fallbacks when the fonts cannot load), colour tokens for light and dark (`--accent`, `--warn`, `--bad`, `--ok`, each with a `-soft` background), an 880 px rail where figures and tables may stretch and a 68 ch `.prose` column for text. The page opens with a **hero** (`header.hero`: a mono `.eyebrow` with the provenance, the `h1`, a `.lede` that states the whole answer in two sentences with the one thing to remember in bold). Then it builds from these elements, each labelled: **key cards** (`.key`, three to four facts with a `.k` key and a `.v` value coloured `accent`, `warn`, `bad` or `ok`), **framed figures** (`figure > .frame > svg`, or two side by side in a `.pair`, each with a `figcaption`), **tables** (`.tscroll > table`, uppercase mono headers, `.pill` states `ok`, `bad`, `warn`, `no`), **callouts** (`.callout`, `.warn`, `.bad`, `.ok`, with a bold lead-in), a **terms list** (`dl.terms`) near the end, and a **footer** naming the sources. Everything is plain HTML and CSS; no other external resource.

**Diagrams.** Draw them as **inline SVG first**: a `viewBox`, `role="img"` and an `aria-label` that says what the picture shows, boxes as `rect` with `rx`, labels as `text`, colours only from the tokens (`fill="var(--accent-soft)" stroke="var(--accent)"`, `fill="currentColor"` for text, `var(--surface)` for neutral boxes), arrows as `line` with a `marker-end`, and an `id` on every `marker` that is unique across the whole page (suffix it with the language on a bilingual page: `arrow-en-1`, `arrow-pt-1`). Use **Mermaid** (`<pre class="mermaid">` inside the `.frame`) only when a diagram has too many nodes to draw by hand, and then add the pinned Mermaid `<script>` tag given in the brief (exact URL and `integrity`; the server's policy allows exactly that file) before the first `<script>` in `<head>` — a page without Mermaid loads no script from outside. An ASCII `<pre>` is the last resort. Every diagram carries a `D<n>` label.

**Languages.** The brief's `Languages:` line says which article(s) the page carries. With one language the page has one `<article lang="xx">` and no switch. With both, every page carries the whole explanation twice: `<article lang="en">` and `<article lang="pt">`, each with its own hero and the **same labelled blocks in the same order** (same `data-label`, same `id`; the source repeats each id once per language on purpose). The EN / PT switch at the top shows one article without a reload and remembers the choice in `localStorage`; the first choice is `?lang=en|pt` in the URL, else the remembered one, else Portuguese when the browser language starts with `pt`, else English. The script keeps the ids only on the shown article, so `<url>#P7` (or `<url>?lang=pt#P7`) lands on P7 in the shown language and click-to-copy works in both. Without a `#label` in the URL, a switch keeps the reader on the same block: the labelled block at the top of the screen is found by its label in the other article and scrolled to the same place. Diagrams are duplicated (node text translated, same structure, same `D<n>` in both articles); Mermaid renders only the shown article's diagrams, the other ones on the first switch. `<title>` holds both titles, `English title · Título em português` (the library index shows it as is; the tab shows the shown article's `<h1>`). Without JavaScript both articles are shown one after the other.

<!-- explain-page-template -->
```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>TITLE_EN · TITLE_PT</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Red+Hat+Display:wght@500;600;700&family=Red+Hat+Text:ital,wght@0,400;0,500;1,400&family=Red+Hat+Mono:wght@400;500&display=swap">
<style>
/* Tokens: light, dark (system or data-theme), type with system fallbacks. */
:root{color-scheme:light;--bg:#f5f7fa;--surface:#ffffff;--fg:#1a2230;--muted:#5a6577;--line:#d5dbe4;
--accent:#0e7a89;--accent-soft:#e2f2f4;--warn:#b5680e;--warn-soft:#fbefdc;--bad:#b32d2d;--bad-soft:#f9e3e3;--ok:#2a7a3b;--ok-soft:#e3f3e6;
--display:"Red Hat Display","Segoe UI",system-ui,sans-serif;--body:"Red Hat Text","Segoe UI",system-ui,sans-serif;--mono:"Red Hat Mono",ui-monospace,"SF Mono",Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#10151c;--surface:#171e27;--fg:#e5e9f0;--muted:#98a3b4;--line:#2a3441;--accent:#3fb8c8;--accent-soft:#10303a;--warn:#e2a24e;--warn-soft:#3a2a12;--bad:#ec6e6e;--bad-soft:#3d1c1c;--ok:#62c47d;--ok-soft:#173422;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#10151c;--surface:#171e27;--fg:#e5e9f0;--muted:#98a3b4;--line:#2a3441;--accent:#3fb8c8;--accent-soft:#10303a;--warn:#e2a24e;--warn-soft:#3a2a12;--bad:#ec6e6e;--bad-soft:#3d1c1c;--ok:#62c47d;--ok-soft:#173422;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--body);font-size:16px;line-height:1.6}
/* Layout: one 880 px rail for figures and tables, a 68 ch column for prose; the left gutter holds the labels. */
.wrap{max-width:960px;margin:0 auto;padding:40px 20px 72px 5rem}
.prose{max-width:68ch}
header.hero{border-bottom:1px solid var(--line);padding-bottom:28px;margin-bottom:36px}
.eyebrow{font-family:var(--mono);font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 12px}
h1{font-family:var(--display);font-weight:700;font-size:clamp(30px,5vw,44px);line-height:1.1;margin:0 0 16px;text-wrap:balance;letter-spacing:-.01em}
.lede{font-size:19px;line-height:1.5;color:var(--fg);margin:0;max-width:62ch}
.lede strong{font-weight:600}
h2{font-family:var(--display);font-weight:600;font-size:24px;line-height:1.25;margin:0 0 12px;text-wrap:balance;letter-spacing:-.005em}
h3{font-family:var(--display);font-weight:600;font-size:17px;margin:0 0 8px}
section{margin-top:48px}section section{margin-top:28px}
p{margin:0 0 14px}ul,ol{margin:0 0 14px;padding-left:22px}li{margin-bottom:6px}
a{color:var(--accent)}
code{font-family:var(--mono);font-size:.9em;background:var(--surface);border:1px solid var(--line);border-radius:4px;padding:1px 5px}
pre{font-family:var(--mono);font-size:13px;line-height:1.55;background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:14px 16px;margin:0 0 16px;overflow:visible}
pre code{display:block;overflow-x:auto;background:none;border:0;padding:0;font-size:inherit}
/* Key cards: three or four facts that carry the page. */
.key{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;margin:22px 0 6px}
.key>div{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:14px 16px;min-width:0}
.key .k{font-family:var(--mono);font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin-bottom:6px}
.key .v{font-family:var(--display);font-weight:600;font-size:17px;line-height:1.3}
.key .v.accent{color:var(--accent)}.key .v.warn{color:var(--warn)}.key .v.bad{color:var(--bad)}.key .v.ok{color:var(--ok)}
/* Figures: a framed inline SVG (or Mermaid / ASCII), alone or two side by side. */
figure{margin:22px 0 28px}
figure .frame{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:14px;overflow-x:auto}
figure svg{display:block;max-width:100%;height:auto;font-family:var(--body)}
figure svg .mono{font-family:var(--mono)}
figure pre{margin:0;border:0;background:none}
figure pre.mermaid{text-align:center}
figcaption{font-size:14px;color:var(--muted);margin-top:10px;line-height:1.5;max-width:72ch}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:18px}
.pair figure{margin:0;min-width:0}.pair figure h3{margin:0 0 10px}
/* Callouts, tables, pills, terms, footer. */
.callout{border-left:3px solid var(--accent);background:var(--accent-soft);padding:12px 16px;border-radius:0 6px 6px 0;margin:18px 0}
.callout.warn{border-color:var(--warn);background:var(--warn-soft)}.callout.bad{border-color:var(--bad);background:var(--bad-soft)}.callout.ok{border-color:var(--ok);background:var(--ok-soft)}
.callout p:last-child{margin:0}
.tscroll{overflow-x:auto;margin:14px 0 20px}
table{border-collapse:collapse;width:100%;font-size:15px}
th,td{text-align:left;vertical-align:top;padding:9px 12px;border-bottom:1px solid var(--line)}
th{font-family:var(--mono);font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);font-weight:500}
td.mono{font-family:var(--mono);font-size:13.5px}
.pill{display:inline-block;font-family:var(--mono);font-size:11px;letter-spacing:.04em;padding:2px 8px;border-radius:999px;border:1px solid;white-space:nowrap}
.pill.ok{color:var(--ok);border-color:var(--ok);background:var(--ok-soft)}.pill.bad{color:var(--bad);border-color:var(--bad);background:var(--bad-soft)}
.pill.warn{color:var(--warn);border-color:var(--warn);background:var(--warn-soft)}.pill.no{color:var(--muted);border-color:var(--line);background:var(--surface)}
dl.terms{display:grid;grid-template-columns:max-content 1fr;gap:8px 18px;margin:14px 0 20px}
dl.terms dt{font-family:var(--mono);font-size:13.5px;color:var(--accent);padding-top:2px}dl.terms dd{margin:0}
footer{margin-top:56px;padding-top:18px;border-top:1px solid var(--line);font-size:13.5px;color:var(--muted)}
footer code{font-size:12.5px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
/* Explain plumbing: margin labels, deep-link target, languages, switch, toast. */
[data-label]{position:relative;scroll-margin-top:3rem}
[data-label]::before{content:attr(data-label);position:absolute;left:-4.4rem;top:.3rem;width:3.6rem;text-align:right;font:500 11px/1.6 var(--mono);letter-spacing:.04em;color:var(--muted);cursor:pointer;white-space:nowrap}
.pair figure[data-label]::before{left:auto;right:.2rem;top:0;width:auto}
[data-label].opsx-target{outline:2px solid var(--accent);outline-offset:4px;border-radius:2px}
article[lang]+article[lang]{border-top:1px solid var(--line);margin-top:3rem;padding-top:1rem}
html[data-show="en"] article[lang]:not([lang="en"]),html[data-show="pt"] article[lang]:not([lang="pt"]){display:none}
html[data-show] article[lang]+article[lang]{border-top:0;margin-top:0;padding-top:0}
.opsx-lang{position:fixed;top:.75rem;right:1rem;z-index:10;display:flex;gap:2px;padding:2px;background:var(--surface);border:1px solid var(--line);border-radius:999px}
.opsx-lang button{font:600 12px/1 var(--mono);color:var(--muted);background:none;border:0;border-radius:999px;padding:.4rem .65rem;cursor:pointer}
.opsx-lang button[aria-pressed="true"]{background:var(--accent-soft);color:var(--accent)}
#opsx-toast{position:fixed;bottom:1rem;left:50%;transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:.35rem .8rem;border-radius:6px;font-size:.85rem;opacity:0;transition:opacity .2s;pointer-events:none}
@media (max-width:720px){.wrap{padding:28px 16px 56px 3rem}.pair{grid-template-columns:1fr}.lede{font-size:17px}[data-label]::before{left:-2.9rem;width:2.5rem;font-size:10px}}
@media (max-width:560px){dl.terms{grid-template-columns:1fr}dl.terms dd{margin-bottom:8px}}
</style>
<script>
if (window.mermaid) mermaid.initialize({startOnLoad: false, theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'});
// Language: ?lang=en|pt, else the remembered choice, else the browser language (pt* -> pt), else en.
// Every article carries the same labels and ids; only the shown article keeps its ids, so #P1 lands on P1 in that language.
// With one article the page just shows it (no switch).
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
<!-- lang-switch -->
<nav class="opsx-lang" aria-label="Language / Idioma"><button type="button" data-set-lang="en" lang="en">EN</button><button type="button" data-set-lang="pt" lang="pt">PT</button></nav>
<!-- /lang-switch -->
<div class="wrap">

<!-- article:en -->
<article lang="en">
<header class="hero">
<p class="eyebrow">PROJECT · WHERE THIS COMES FROM · ONE LINE</p>
<h1>TITLE_EN</h1>
<p class="lede">Two sentences that give the whole answer, with <strong>the one thing to remember</strong> in bold.</p>
</header>

<section id="S1" data-label="S1" class="prose">
<h2>In one picture</h2>
<div class="key" id="T1" data-label="T1">
<div><div class="k">what it expects</div><div class="v accent">the short fact</div></div>
<div><div class="k">what it gets</div><div class="v warn">the surprising fact</div></div>
<div><div class="k">result</div><div class="v bad">the consequence</div></div>
</div>
<p id="P1" data-label="P1">A paragraph. Every block has an id equal to its label.</p>
</section>

<section id="S2" data-label="S2">
<h2 class="prose">How it works</h2>
<figure id="D1" data-label="D1">
<div class="frame">
<svg viewBox="0 0 440 150" role="img" aria-label="A request goes from the client to the cache; a hit answers in two milliseconds.">
<defs><marker id="arrow-en-1" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="currentColor"/></marker></defs>
<rect x="20" y="40" width="120" height="60" rx="6" fill="var(--accent-soft)" stroke="var(--accent)" stroke-width="1.5"/>
<text x="80" y="75" font-size="13" font-weight="600" text-anchor="middle" fill="currentColor">client</text>
<rect x="300" y="40" width="120" height="60" rx="6" fill="var(--surface)" stroke="currentColor" stroke-opacity=".6" stroke-width="1.5"/>
<text x="360" y="68" font-size="13" font-weight="600" text-anchor="middle" fill="currentColor">cache</text>
<text x="360" y="86" font-size="11" text-anchor="middle" class="mono" fill="currentColor" fill-opacity=".8">hit / miss</text>
<line x1="140" y1="70" x2="298" y2="70" stroke="var(--accent)" stroke-width="2" marker-end="url(#arrow-en-1)" color="var(--accent)"/>
<text x="219" y="60" font-size="11" text-anchor="middle" fill="var(--accent)">GET /item/42</text>
<rect x="150" y="112" width="140" height="24" rx="12" fill="var(--ok-soft)" stroke="var(--ok)"/>
<text x="220" y="128" font-size="11" text-anchor="middle" class="mono" fill="var(--ok)">hit: 2 ms</text>
</svg>
</div>
<figcaption>What the diagram shows, in one sentence.</figcaption>
</figure>
<div class="pair">
<figure id="D2" data-label="D2">
<h3>Before</h3>
<div class="frame"><svg viewBox="0 0 200 80" role="img" aria-label="One box labelled before."><rect x="20" y="20" width="160" height="40" rx="6" fill="var(--warn-soft)" stroke="var(--warn)" stroke-width="1.5"/><text x="100" y="45" font-size="13" text-anchor="middle" fill="currentColor">before</text></svg></div>
<figcaption>The left half of a comparison.</figcaption>
</figure>
<figure id="D3" data-label="D3">
<h3>After</h3>
<div class="frame"><svg viewBox="0 0 200 80" role="img" aria-label="One box labelled after."><rect x="20" y="20" width="160" height="40" rx="6" fill="var(--ok-soft)" stroke="var(--ok)" stroke-width="1.5"/><text x="100" y="45" font-size="13" text-anchor="middle" fill="currentColor">after</text></svg></div>
<figcaption>The right half.</figcaption>
</figure>
</div>
<p id="P2" data-label="P2" class="prose">Prose stays in the 68 ch column; figures and tables may use the whole rail.</p>
<div class="tscroll" id="T2" data-label="T2">
<table>
<thead><tr><th>Item</th><th>State</th><th>Note</th></tr></thead>
<tbody>
<tr><td>Something done</td><td><span class="pill ok">done</span></td><td>Where it is.</td></tr>
<tr><td>Something not met</td><td><span class="pill bad">not met</span></td><td>Why.</td></tr>
<tr><td>Something pending</td><td><span class="pill no">pending</span></td><td>What it waits for.</td></tr>
</tbody>
</table>
</div>
<pre id="C1" data-label="C1"><code>example code, HTML-escaped (&lt; &gt; &amp;)</code></pre>
<div class="callout warn" id="N1" data-label="N1"><p><strong>Decision needed.</strong> A callout: caveat, decision, warning. Variants: <code>callout</code> (accent), <code>warn</code>, <code>bad</code>, <code>ok</code>.</p></div>
<section id="S2.1" data-label="S2.1" class="prose">
<h3>Nested section</h3>
<p id="P3" data-label="P3">Numbers are per prefix across the whole page, not per section.</p>
</section>
</section>

<section id="S3" data-label="S3" class="prose">
<h2>Terms used above</h2>
<dl class="terms" id="T3" data-label="T3">
<dt>term</dt><dd>What it means, in one sentence.</dd>
<dt>other term</dt><dd>And this one.</dd>
</dl>
</section>

<footer>Source: the files, commands and conversation this page was written from. Nothing confidential is shown.</footer>
</article>
<!-- /article:en -->

<!-- article:pt -->
<article lang="pt">
<header class="hero">
<p class="eyebrow">PROJETO · DE ONDE ISTO VEM · UMA LINHA</p>
<h1>TITLE_PT</h1>
<p class="lede">Duas frases que dão a resposta inteira, com <strong>a única coisa a lembrar</strong> em negrito.</p>
</header>

<section id="S1" data-label="S1" class="prose">
<h2>Em uma imagem</h2>
<div class="key" id="T1" data-label="T1">
<div><div class="k">o que espera</div><div class="v accent">o fato curto</div></div>
<div><div class="k">o que recebe</div><div class="v warn">o fato surpreendente</div></div>
<div><div class="k">resultado</div><div class="v bad">a consequência</div></div>
</div>
<p id="P1" data-label="P1">Um parágrafo. Cada bloco tem um id igual ao seu rótulo.</p>
</section>

<section id="S2" data-label="S2">
<h2 class="prose">Como funciona</h2>
<figure id="D1" data-label="D1">
<div class="frame">
<svg viewBox="0 0 440 150" role="img" aria-label="Uma requisição vai do cliente ao cache; um acerto responde em dois milissegundos.">
<defs><marker id="arrow-pt-1" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="currentColor"/></marker></defs>
<rect x="20" y="40" width="120" height="60" rx="6" fill="var(--accent-soft)" stroke="var(--accent)" stroke-width="1.5"/>
<text x="80" y="75" font-size="13" font-weight="600" text-anchor="middle" fill="currentColor">cliente</text>
<rect x="300" y="40" width="120" height="60" rx="6" fill="var(--surface)" stroke="currentColor" stroke-opacity=".6" stroke-width="1.5"/>
<text x="360" y="68" font-size="13" font-weight="600" text-anchor="middle" fill="currentColor">cache</text>
<text x="360" y="86" font-size="11" text-anchor="middle" class="mono" fill="currentColor" fill-opacity=".8">acerto / falha</text>
<line x1="140" y1="70" x2="298" y2="70" stroke="var(--accent)" stroke-width="2" marker-end="url(#arrow-pt-1)" color="var(--accent)"/>
<text x="219" y="60" font-size="11" text-anchor="middle" fill="var(--accent)">GET /item/42</text>
<rect x="150" y="112" width="140" height="24" rx="12" fill="var(--ok-soft)" stroke="var(--ok)"/>
<text x="220" y="128" font-size="11" text-anchor="middle" class="mono" fill="var(--ok)">acerto: 2 ms</text>
</svg>
</div>
<figcaption>O que o diagrama mostra, em uma frase.</figcaption>
</figure>
<div class="pair">
<figure id="D2" data-label="D2">
<h3>Antes</h3>
<div class="frame"><svg viewBox="0 0 200 80" role="img" aria-label="Uma caixa com o rótulo antes."><rect x="20" y="20" width="160" height="40" rx="6" fill="var(--warn-soft)" stroke="var(--warn)" stroke-width="1.5"/><text x="100" y="45" font-size="13" text-anchor="middle" fill="currentColor">antes</text></svg></div>
<figcaption>A metade esquerda de uma comparação.</figcaption>
</figure>
<figure id="D3" data-label="D3">
<h3>Depois</h3>
<div class="frame"><svg viewBox="0 0 200 80" role="img" aria-label="Uma caixa com o rótulo depois."><rect x="20" y="20" width="160" height="40" rx="6" fill="var(--ok-soft)" stroke="var(--ok)" stroke-width="1.5"/><text x="100" y="45" font-size="13" text-anchor="middle" fill="currentColor">depois</text></svg></div>
<figcaption>A metade direita.</figcaption>
</figure>
</div>
<p id="P2" data-label="P2" class="prose">A prosa fica na coluna de 68 ch; figuras e tabelas podem usar o trilho inteiro.</p>
<div class="tscroll" id="T2" data-label="T2">
<table>
<thead><tr><th>Item</th><th>Estado</th><th>Nota</th></tr></thead>
<tbody>
<tr><td>Algo feito</td><td><span class="pill ok">feito</span></td><td>Onde está.</td></tr>
<tr><td>Algo não atendido</td><td><span class="pill bad">não atendido</span></td><td>Por quê.</td></tr>
<tr><td>Algo pendente</td><td><span class="pill no">pendente</span></td><td>Do que depende.</td></tr>
</tbody>
</table>
</div>
<pre id="C1" data-label="C1"><code>example code, HTML-escaped (&lt; &gt; &amp;)</code></pre>
<div class="callout warn" id="N1" data-label="N1"><p><strong>Decisão necessária.</strong> Um destaque: ressalva, decisão, aviso. Variantes: <code>callout</code> (accent), <code>warn</code>, <code>bad</code>, <code>ok</code>.</p></div>
<section id="S2.1" data-label="S2.1" class="prose">
<h3>Seção aninhada</h3>
<p id="P3" data-label="P3">A numeração é por prefixo na página inteira, não por seção.</p>
</section>
</section>

<section id="S3" data-label="S3" class="prose">
<h2>Termos usados acima</h2>
<dl class="terms" id="T3" data-label="T3">
<dt>termo</dt><dd>O que significa, em uma frase.</dd>
<dt>outro termo</dt><dd>E este.</dd>
</dl>
</section>

<footer>Fonte: os arquivos, comandos e a conversa de que esta página foi escrita. Nada confidencial é mostrado.</footer>
</article>
<!-- /article:pt -->

</div>
<span id="opsx-toast"></span>
<script>
// Click a margin label (or the corner label of a paired figure): copy "#<label>" and deep-link to it.
document.addEventListener('click', function (e) {
  var el = e.target.closest && e.target.closest('[data-label]');
  if (!el) return;
  var r = el.getBoundingClientRect(), paired = el.parentElement && el.parentElement.classList.contains('pair');
  if (paired ? !(e.clientX >= r.right - 56 && e.clientY <= r.top + 18) : e.clientX >= r.left) return;
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

- One page per fork; one fork per page. The page carries the language(s) asked at `open` (`--lang`, English by default); the user can ask the fork to add the other language later ("add Portuguese"), or for wording changes in one language by label ("PT P3: use 'implantação'"). To explain another topic, run `/explain` again (a new page id).
- The fork is read-only apart from `fork.sh page` (page and manifest) and `fork.sh return`; on CLIs whose read-only mode blocks `fork.sh page` (Gemini, Cursor, OpenCode plan, Codex without approval), the fork says the page cannot be written and stops — open the fork with `--cli claude` instead.
- Pages are served behind the expose login; nothing leaves the machine unless the user creates a share link. Never put secrets into a page.
- The proxy, not the page, enforces the safety rules: the pages directory is published with `expose.sh up --dir … --hide manifest.tsv --hide '*.sha256' --csp <policy>`, so Caddy serves only regular files (no listings, no dotfiles such as `.meta` or `.ids`, no manifests or sidecars) and sends a strict Content-Security-Policy on every response (inline scripts and the pinned Mermaid file only; styles and fonts only from the page itself and Google Fonts; no other external images, styles, frames or fetches; no forms) with `Referrer-Policy: no-referrer`. Keep the template's fonts `<link>` and, when Mermaid is used, the exact pinned tag from the brief (version and `integrity` hash) or diagrams will not render.
