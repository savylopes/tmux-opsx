---
name: explain
description: "Turn a topic from the current agent session into a clean, diagrammed web page written by a read-only full-context fork and served from this machine through /expose (login-protected URL, share links), so the user can read it on any device, hand it to a client, and refine it by talking to the fork ('expand P7', 'the arrow in D2 is wrong'). Every block carries a stable label (S P D T C N). Works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI inside tmux. Use when the user types /explain, asks to 'explain this as a page', 'make a web page explaining', 'diagram this for a client'. Also /explain share, /explain list, /explain stop. Trigger: /explain"
trigger: /explain
---

# /explain

Open a **read-only fork** of this session (see `/fork`) whose only job is to write **one self-contained web page** about a topic. The page is served from this machine by the project's explain server and published once through `/expose` at `https://explain--<project>.<domain>/<id>/`, behind the expose login. The user reads it anywhere, refines it by talking to the fork pane by label, and shares it with a share link. Pages persist as a library.

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

Every block has a visible label in the left margin and an HTML id equal to it; clicking a label copies `#<label>`, so `<url>#P7` deep-links to it:

| Prefix | Block |
|---|---|
| `S<n>` (`S1.2` nested) | section |
| `P<n>` | paragraph |
| `D<n>` | diagram (Mermaid, inline SVG or ASCII) |
| `T<n>` | table |
| `C<n>` | code block |
| `N<n>` | callout / note |

The user tells the **fork pane** what to change: "expand P7", "D2: the arrow from cache to db is wrong", "add a table after S3 comparing the options", "drop N2". The fork rewrites the whole page with `fork.sh page`, keeps every existing label (an edited block keeps its label, new blocks get the next unused number, removed labels are never reused) and records them in `manifest.tsv` beside the page (`label<TAB>one-line summary`), which it reads before every rewrite. The open browser reloads within a few seconds (it polls the page's `Last-Modified` every 2 s).

## Sharing, library, stop

- `"$EXPLAIN_SH" share --for acme --ttl 3d` → a share link for the whole explain host of this project (**every page in the library**, not one page), last line of output. Tell the user so before handing it to a client. `--list` shows links, `--revoke <r|id|all>` removes them. Give the user the link; do not open it.
- `"$EXPLAIN_SH" list` → pages, server state, URL. The library index is also the root URL `https://explain--<project>.<domain>/`.
- `"$EXPLAIN_SH" stop` → `expose.sh down explain`, kills the `ox >explain` window (tag `@opsx_explain=<project>`), keeps every page. The next `/explain` starts it again. `/opsx-run` `close-all` never touches it.

Pages live in `${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/<id>/` (`index.html`, `manifest.tsv`, `.meta`) and survive `fork.sh close` and `stop`. They are never written into the project checkout.

## Page template

`explain.sh open` appends this skeleton to the brief. The fork keeps the `<style>`, every `<script>` block and the Mermaid script tag (exact version and `integrity` hash, which the server's Content-Security-Policy allows), and replaces the title and the body content. Labels are drawn in the margin from `data-label` by CSS; a click in the margin copies `#<label>`; the page reloads itself when the served file changes (HEAD polling of `Last-Modified` every 2 s); Mermaid comes from a CDN, pinned with Subresource Integrity and sent without a referrer (the diagram source stays readable as text when the CDN is unreachable).

<!-- explain-page-template -->
```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TITLE</title>
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
[data-label]{position:relative;scroll-margin-top:1.5rem}
[data-label]::before{content:attr(data-label);position:absolute;left:-4.3rem;top:.2rem;width:3.6rem;text-align:right;font:600 11px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted);cursor:pointer;white-space:nowrap}
section[data-label]::before{top:.55rem}
[data-label]:target{outline:2px solid var(--accent);outline-offset:4px;border-radius:2px}
#opsx-toast{position:fixed;bottom:1rem;left:50%;transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:.35rem .8rem;border-radius:6px;font-size:.85rem;opacity:0;transition:opacity .2s;pointer-events:none}
@media (max-width:40rem){body{padding-left:3rem;font-size:16px}[data-label]::before{left:-3rem;width:2.6rem;font-size:10px}}
</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js" integrity="sha384-EOXBFmc3gx5mb+vn0vPvvGqACToJD24hhacX5Yx+8NUUQrHIle/Qi5Bg9o3zKwW2" crossorigin="anonymous" referrerpolicy="no-referrer"></script>
<script>
if (window.mermaid) mermaid.initialize({startOnLoad: true, theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'});
</script>
</head>
<body>
<h1>TITLE</h1>
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

<span id="opsx-toast"></span>
<script>
// Click a margin label: copy "#<label>" and deep-link to it.
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
// Reload when the served page changes (HEAD poll of Last-Modified every 2 s).
(function () {
  var last = null;
  function poll() {
    fetch(location.pathname, {method: 'HEAD', cache: 'no-store'}).then(function (r) {
      var m = (r.headers.get('Last-Modified') || '') + '|' + (r.headers.get('Content-Length') || '');
      if (last !== null && m !== last) { location.reload(); return; }
      last = m; setTimeout(poll, 2000);
    }).catch(function () { setTimeout(poll, 2000); });
  }
  poll();
})();
</script>
</body>
</html>
```

## Rules

- One page per fork; one fork per page. To explain another topic, run `/explain` again (a new page id).
- The fork is read-only apart from `fork.sh page` (page and manifest) and `fork.sh return`; on CLIs whose read-only mode blocks `fork.sh page` (Gemini, Cursor, OpenCode plan, Codex without approval), the fork says the page cannot be written and stops — open the fork with `--cli claude` instead.
- Pages are served behind the expose login; nothing leaves the machine unless the user creates a share link. Never put secrets into a page.
- The server, not the page, enforces the safety rules: it serves only `/`, `/<id>/` and their `index.html` (no listings, dotfiles, manifests or `launch.sh`), answers only to `127.0.0.1`, `localhost` and the expose host, and sends a strict Content-Security-Policy (inline scripts and the pinned Mermaid file only; no external images, fonts, styles, frames or fetches; no forms) with `Referrer-Policy: no-referrer`. Keep the template's Mermaid tag exactly (pinned version and `integrity` hash) or diagrams will not render.
