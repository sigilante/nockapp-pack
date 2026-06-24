# solitaire — Klondike Solitaire as a NockApp

A fully playable **drag-and-drop Klondike Solitaire** (draw-1) served over HTTP, with
**all game logic in the Hoon kernel** — the deck shuffle/deal, every legal-move check,
foundation building, auto-flip, recycle, and win detection. The Rust binary only boots the
kernel from `out.jam` and attaches the library HTTP driver.

You **drag** cards with the mouse; a tiny JS layer carries only the in-flight drag state
and then submits one atomic `POST /move?src=<pile>&i=<index>&dst=<pile>`. The **kernel is
the sole authority**: it re-validates the move against the same legality rules and either
applies it (returning the re-rendered board) or rejects it (board unchanged). An illegal
drop changes nothing.

Because the entire game is one versioned noun in kernel state, nockd checkpoints it: an
in-progress game survives `nockd restart` for free.

The card art is **reused from the sibling blackjack project**
(`/Users/neal/zorp/blackjack/img/sprites.png`) — a 13×4 sprite sheet (71×96 px per card).
We base64-encode it once and serve it from `GET /style.css` with a one-day
`cache-control`, so the browser fetches the ~80 KB sprite CSS **once** and every per-move
re-render ships only the small board HTML.

## Run it

```sh
export PATH="$PATH:/Users/neal/zorp/nockd/target/release"

# Build the kernel + binary (run from examples/, name the project — see RECIPE.md):
( cd .. && nockup project build solitaire )

# Deploy + run under nockd (project-mode: nockd builds via nockup and ships the artifact):
nockd deploy -f nockd.toml
nockd restart solitaire
nockd ps            # solitaire → running, verified, MOVES <n>
```

Then open <http://localhost:8087/> (the port is declared once in `nockd.toml`; nockd
exports it as `NOCKD_APP_PORT`, which `main.rs` bridges to the driver's `HTTP_PORT`).

You can also run it standalone without nockd:

```sh
HTTP_PORT=8087 ./target/release/solitaire     # reads out.jam from the cwd
```

## How to play

- **Stock** (top-left, face-down): **click** to draw one card to the waste (drawing from
  the stock is a click, not a drag). When the stock is empty it shows a ↻ recycle button —
  click it to flip the waste back into the stock.
- **Move a card or run** by **dragging**:
  - Grab any **face-up card** and drop it on a destination. In a tableau column, grabbing a
    card takes that card **and every card below it** (the movable run).
  - **Drop targets** are a tableau column's exposed card (or the empty-column slot) and the
    four **foundation** slots at the top-right. The hovered target highlights in gold.
  - On drop, the browser submits `POST /move?src=<pile>&i=<index>&dst=<pile>`; the kernel
    validates + applies it and returns the new board. (The earlier click-based
    `/sel` + `/to` endpoints are retained but the UI no longer uses them.)
- **Legal moves** (enforced in Hoon):
  - **Tableau:** descending rank, **alternating colors**. An empty column accepts only a
    **King** (and any legal run headed by one).
  - **Foundation:** one suit each, ascending **A → K**; an empty foundation accepts only an
    **Ace**. Only a single card may go to a foundation.
  - An illegal move is rejected and the selection is cleared.
- Whenever a tableau move exposes a face-down card, it is **auto-flipped** face-up.
- **New game** deals a fresh shuffle (seeded from the poke's entropy).
- **Win:** move all 52 cards onto the foundations and a "YOU WIN!" banner appears.

## What surfaces in `nockd ps`

The kernel slogs `metric: moves=<N>` (cumulative successful/mutating actions) on every
mutating request. `nockd.toml`'s `[deploy.status]` greps the most recent value into the
**MOVES** column.

## The JS / kernel split

The only JavaScript in the suite (~1.2 KB at the cached `GET /app.js`) does exactly three
things and holds no game rules:

- `dragstart` — record `{src, i}` from the dragged card's `data-pile` / `data-i`.
- `dragover` — `preventDefault()` on any `[data-dst]` element so a drop is allowed (and add
  a highlight class).
- `drop` — read the target's `data-dst` and submit `POST /move?src&i&dst`.

All legality lives in the kernel: the same `try-move` / `legal-run` / `tab-ok` / `found-ok`
checks the click version used. JS cannot make an illegal move stick — the kernel rejects it
and returns the unchanged board.

## Files

- `hoon/app/app.hoon` — the whole game: card model, shuffle/deal, legality, the move engine,
  drag-aware rendering, `/move` + `/app.js` routes, and the `++inner` door (`load`/`peek`/
  `poke` only; helpers live in the prelude core).
- `hoon/lib/sprite.hoon` — the blackjack sprite sheet as a base64 cord constant.
- `src/main.rs` — boots the kernel and attaches `http_driver()`; handles SIGTERM cleanly.
- `nockd.toml` — project-mode deploy manifest + the MOVES status metric.

See `RECIPE.md` for the build gotchas (especially the in-Hoon card model, the JS/kernel
split, and serving a binary sprite sheet from Hoon without a base64 decoder).
