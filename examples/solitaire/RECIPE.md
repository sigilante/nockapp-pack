# solitaire — build/deploy recipe

Builds on the suite's shared recipe — see `../minesweeper/RECIPE.md` and
`/Users/neal/zorp/nockd/examples/GOTCHAS.md` for the toolchain gotchas. This file covers
what's *new* in solitaire: a real card-game state model in Hoon, and serving a binary
sprite sheet from the kernel without a base64 decoder.

## Build

- nockchain crates pinned at rev **`07577127958db94be12e95ea816f31bc7582aa2c`**
  (current origin/master — includes PR #134's `HTTP_PORT`).
- `rust-toolchain.toml` → `nightly-2026-04-03` (avoids the `cold_path` E0658).
- **Invocation matters.** `nockup project build` (no arg) and `nockup project build .` both
  fail with `Project directory 'solitaire' not found` — nockup appends the *package name*
  as a subdir. Build from the **parent** dir and name the project:

  ```sh
  cd examples && nockup project build solitaire
  ```

  (Project-mode deploy via nockd works correctly — nockd passes the absolute path.)
- **Watch the real signal.** nockup prints `✓ Hoon compilation completed successfully!`
  **even when hoonc crashed.** The truth is whether `out.jam` was (re)written — look for
  `hoonc: output written successfully to '…/out.jam'`. A Hoon error instead shows
  `hoonc: build failed, skipping write and exiting` followed by `Exit(1)`, and **no**
  `out.jam`. Grep the build log for `find-fork` / `nest-fail` / `build failed`.

## HTTP serving + cache (PR #134)

The library `http_driver()` binds the port from `HTTP_PORT`. `main.rs` bridges nockd's
`NOCKD_APP_PORT` (declared once as `port = 8087` in `nockd.toml`) to `HTTP_PORT`.

**`EXPIRE_CACHE` must be `1`, not `0`.** At this rev the driver builds a cache-invalidation
timer with `tokio::time::interval(Duration::from_secs($EXPIRE_CACHE))`; `0` →
`interval(Duration::ZERO)` → panic *"period must be non-zero"*, which crash-loops the app.
We set `EXPIRE_CACHE=1` (1-second GET TTL). This is correct for solitaire because **every
move is a POST** and POST responses are never cached — so the 1 s GET cache can never serve
a stale board after a move. (The brief said `0`; that value is unusable at this rev.)

## The card model in Hoon (new)

- A **card is a `@ud` 0..51**: `suit=(div c 13)` (0 hearts, 1 diamonds, 2 clubs, 3 spades),
  `rank=(mod c 13)` (0=A … 12=K). Color is `red = (lth suit 2)`. This single-integer model
  makes legality checks trivial arithmetic and keeps the whole game a compact noun.
- **State** (`+$ game`) is one versioned noun: `stock` / `waste` lists, a `tabs` list of 7
  `[down=(list card) up=(list card)]` piles, 4 `founds` lists, the current `sel`ection, and
  a `moves` counter. nockd checkpoints it, so a game survives restart.
- **Tableau ordering convention:** in `up`, the **head is the deepest face-up card** and the
  **last element is the exposed top**. A movable run is therefore a *suffix* of `up`
  (`(slag i up)`), which is exactly what select-then-move needs; the deepest card of the run
  (`i.run`) is the one tested against the destination.
- **Shuffle without `og`:** the stdlib `og` RNG is stubbed to `!!` at this rev (same as
  minesweeper), so Fisher-Yates draws each step's index from `(shax (add (mul eny k) i))`
  reduced mod the remaining span. Seeded from the poke's `eny`.
- **Auto-flip / recycle / win** are all in Hoon: removing the last face-up card from a
  tableau column flips the next face-down card up; an empty stock + `/draw` flips the waste
  back down into the stock; `won` is simply "all 4 foundations total 52 cards".

## Drag-and-drop: the JS / kernel split (new)

The UI is HTML5 drag-and-drop, but the **kernel stays the authority** — only the in-flight
drag state lives in the browser.

- **One atomic kernel endpoint:** `POST /move?src=<pile>&i=<index>&dst=<pile>`. It parses
  both endpoints (`grab-key` for the `tab|found|waste` token, `grab-num` for the pile index
  and the run index `i=`), then runs the *exact same* move engine the click version used
  (`run-at` → `legal-run` → `try-move`). On success it returns the re-rendered board; on an
  illegal/duplicate/empty move it clears the selection and returns the **unchanged** board.
  `/draw` stays a click; the old `/sel` + `/to` are kept (harmless) but unused by the UI.
- **Drag attributes in the render:** each movable face-up card is
  `<div class="card …" draggable="true" data-pile="tabK" data-i="N" data-dst="tabK">` — it is
  both a drag *source* (pile+index) and the column's drop *target* (so dropping on the
  exposed card targets the column). Foundations and empty columns are bare
  `<div class="dropzone" data-dst="foundK|tabK">`.
- **The only JS in the suite** (`++ app-js`, served cached at `GET /app.js` as
  `application/javascript`): `dragstart` records `{src,i}` from the element's data attrs;
  `dragover` `preventDefault()`s on `[data-dst]` (and highlights it); `drop` reads
  `data-dst` and submits a generated `POST /move` form (full-page replace with the kernel's
  new board). ~1.2 KB; holds zero game rules.
- **Headless proof:** since curl can't drag, the atomic endpoint is the testable contract.
  `POST /move?src=tabA&i=0&dst=tabB` performs a legal tableau move; an illegal `dst` leaves
  the board byte-identical; `dst=foundK` lands an Ace. All verified by curl before deploy.
- **Serving JS from a Hoon `'''`-block:** like the CSS, the JS lives in a `'''` literal block
  so its `{ }`, `( )`, and quotes are taken verbatim (no tape interpolation). Build it as a
  cord, `(crip app-js)` → `to-octs` in the GET handler.

## Serving a binary sprite sheet from Hoon (new)

No base64 *decoder* in Hoon and no shipping ~80 KB per render:

1. `base64 -i sprites.png | tr -d '\n'` once → a pure-ASCII string.
2. Embed it as a **single-quoted cord** in `hoon/lib/sprite.hoon` (`++ data ^- @t '<b64>'`).
   It is plain `A-Za-z0-9+/=`, so a `'…'` cord is safe (no `\`/`{` escaping needed).
3. `GET /style.css` welds it into `url('data:image/png;base64,<b64>')` and returns it with
   `content-type: text/css` + `cache-control: public, max-age=86400`. The board page just
   `<link>`s `/style.css`, so the browser fetches the big sprite CSS **once** and caches it;
   per-move re-renders ship only small HTML.
4. Verified the round-trip: the embedded base64 decodes **byte-for-byte** to the original
   `sprites.png`.

## Rough edges hit (in order)

1. **Literal `{` in a `"…"` tape** is tape interpolation, not a brace — `syntax error`. The
   one CSS rule built with a `"…"` tape (`.card{background-image:…}`) needed `\{`. The bulk
   of the CSS lives in a `'''`-block where `{ }` are literal and safe.
2. **`i.run` on a `(list card)`** is a `find-fork`: the compiler can't take `.i` of a list
   that might be `~`. Guard with `?~ run` (then bind `=/ lo=card i.run`).
3. **Extra arms in the `++inner` door** → `nest-fail` against the wrapper's `fort` mold. The
   door must be **exactly** `load`/`peek`/`poke`. Move helpers (`try-move`, `remove-src`,
   `post-move`) into the prelude core and pass `g=game` explicitly. (This is the same rule
   minesweeper's RECIPE states; it bites hard here because the move engine is large.)
4. **Drag-and-drop retrofit:** adding `/move` was trivial (it reuses the whole move engine);
   the only fiddly part was CSS — once tableau cards became bare draggable `.card` divs
   (not form-wrapped buttons), the column-stacking overlap rule had to move from
   `.tabcol .cardform` to `.tabcol>.card` with the last child un-overlapped, and the exposed
   card carries `data-dst` so no extra drop strip is needed.
5. **Drop dead-zone on multi-card columns:** putting `data-dst` only on the offset/overlapping
   card divs left uncovered gaps over a 2+ pile, so `closest('[data-dst]')` returned null and
   the `drop` handler silently ignored the drop (1-card columns happened to fill their area, so
   they worked — masking the bug). Fix: put `data-dst="{src}"` on the whole non-empty
   `.tabcol` container so a drop *anywhere* over the column resolves to the column (the kernel
   maps it to the exposed top via `(rear up.p)`). The kernel move logic was already correct
   for any pile size and was not touched.
6. **Waste card was a drop target too → self-drop killed waste→tableau drags:** the waste
   (drawn) card was rendered by the same `drag-card` helper as tableau cards, so it carried
   `data-dst="waste"`. A `draggable` element that is *also* a drop target can, in WebKit, have
   a drop resolve back onto the dragged element itself; `closest('[data-dst]')` then returned
   the waste card and the move went out as `dst=waste`, which the kernel correctly rejects
   (you can't drop onto the waste) — so a perfectly legal waste→tableau move (e.g. 10♣ onto
   J♥) silently did nothing. Diagnosed empirically: a temporary `~> %slog` in `/move` showed
   the kernel *accepting* every `src=waste&i=0&dst=tabN` curl sent, so the fault was in the
   render/JS layer, not the kernel. Fix: `drag-card` takes a `target=?` flag; the waste card
   is rendered with `target=|` (no `data-dst` — it is a drag *source* only, never a target).
   Hardened the JS too: `dragstart` selects `[data-pile]` (robust, no attribute-value quoting),
   the source is also encoded in the dataTransfer payload as a fallback, and a `dst===src`
   self-drop is ignored client-side.
7. **Cached assets defeated every redeploy (the real reason "fixes didn't stick"):**
   `/style.css` and `/app.js` are served `cache-control: public, max-age=86400` (1 day) so the
   big sprite CSS is fetched once. But that also meant that after a redeploy with a *fixed*
   `app.js`, the browser kept running the **old cached JS** for a day — so the user kept seeing
   the same drag bug no matter how many times we fixed and redeployed. The kernel and the
   *current* `app.js` were correct; the browser just never fetched the new one. Fix:
   cache-bust with a version token. `++ asset-ver` is a short cord (currently `"4"`); the page
   HTML (served fresh on every GET, never cached) references `/style.css?v={asset-ver}` and
   `/app.js?v={asset-ver}`, so a bump changes the URL and forces a refetch immediately. **Bump
   `asset-ver` whenever app.js or style.css change.** The day-long `cache-control` stays (now
   safe — the URL changes when the content does). `route-is` is a prefix match
   (`=(\`0 (find pfx t))`), so `/style.css?v=4` and `/app.js?v=4` still match the route and
   serve 200; no route change was needed.

## Gotchas reused (not re-derived here)

HTTP_PORT bridging, the `++inner` door shape, the `og`-is-stubbed PRNG-from-`shax` pattern,
the `grep -aoE 'moves=…'` NUL-safe status command — see the shared GOTCHAS and minesweeper.
