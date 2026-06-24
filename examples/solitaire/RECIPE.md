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

## Gotchas reused (not re-derived here)

HTTP_PORT bridging, the `++inner` door shape, the `og`-is-stubbed PRNG-from-`shax` pattern,
the `grep -aoE 'moves=…'` NUL-safe status command — see the shared GOTCHAS and minesweeper.
