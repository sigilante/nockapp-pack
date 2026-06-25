# gematria — build/deploy recipe

Builds on the suite's shared recipe — see `../wordle/RECIPE.md` and
`/Users/neal/zorp/nockd/examples/GOTCHAS.md` for the toolchain gotchas. This file covers
only what's specific to gematria.

## Build

- nockchain crates pinned at rev **`07577127958db94be12e95ea816f31bc7582aa2c`**
  (current origin/master — includes PR #134's `HTTP_PORT`).
- `rust-toolchain.toml` → `nightly-2026-04-03` (avoids the `cold_path` E0658).
- `nockup project build gematria` (run from `examples/`) → `target/release/gematria` + `out.jam`.
  - **`nockup project build` prints `✓` even when the Hoon crashes.** The *real* signal is
    whether `out.jam` was rewritten. Confirmed here: the hash changed across the two builds
    (`316e5f4…` → `dff37a3…` after adding EQ), so the new logic actually shipped.

## HTTP serving (PR #134) + port

The library `http_driver()` binds the port from `HTTP_PORT`. The port is declared **once** in
`nockd.toml` (`port = 8090`); nockd exports it as `NOCKD_APP_PORT`, and `main.rs` bridges that
to `HTTP_PORT` with `DEFAULT_PORT = 8090` as the standalone fallback — no TCP proxy. (8081–8089
were already taken by sibling apps.)

```rust
std::env::set_var("EXPIRE_CACHE", "1");   // NOT 0 — see below
if let Ok(p) = std::env::var("NOCKD_APP_PORT") { std::env::set_var("HTTP_PORT", p); }
```

### EXPIRE_CACHE=0 PANICS at this rev — use 1

At rev `07577127` `EXPIRE_CACHE=0` panics the HTTP driver on the first cache tick
(`tokio::time::interval(Duration::from_secs(0))` → "`period` must be non-zero"). Set
`EXPIRE_CACHE=1` (smallest non-panicking value). `/sum` is a POST (never cached), so its
re-rendered result is always fresh; `GET /` re-pokes at least once a second, keeping the
`metric: sums=<N>` line current.

## Deploy (project-mode)

```sh
nockd deploy -f nockd.toml      # project = "." → nockd builds via nockup + ships
nockd restart gematria          # deploy registers the artifact; restart swaps the live process
```

Verified under nockd: `gematria running verified`, GET `/` renders the form, a POST `/sum`
returns both totals, and `nockd ps` shows `SUMS <n>` after the first request.

## Hoon logic (app.hoon) — points of note

### Two schemes from one primitive

`++letter-val` takes `[s=scheme c=@t]` and is the only place a letter becomes a number;
everything else (`++gematria` fold, `++breakdown` per-letter list) just passes a scheme
through. A non-letter returns 0, so spaces/punctuation are skipped by every fold for free.

- **`%ord` (English ordinal):** `+((sub lc 'a'))` — i.e. `letter − 'a' + 1`. A=1 … Z=26.
- **`%eq` (English Qaballa):** value = 1-based index of the lowercased letter in the cipher
  cord `eq-seq = "alwhsdozkvgrcnyjufqbmxitep"`, computed as `+((need (find ~[c] eq-seq)))`.
  This is the Lees / *Liber Trigrammaton* ALW cipher (source:
  <https://en.wikipedia.org/wiki/English_Qaballa>). `find ~[c]` searches for the
  single-element list (one char) and returns its `(unit @ud)` index; `need` + `+` make it
  1-based. Verified: `abc` → a=1, b=20, c=13 = **34**.

### Form / query parsing (no de-purl)

There is no `de-purl` in this stdlib, so URL decoding is hand-rolled:

- `++decode` — `'+'` → space, `'%XX'` → byte (via `++from-hex`), malformed sequences pass
  through literally. (Mirrors common-blog's decoder.)
- `++split` on `&` then `=` → `++field` pulls a named value out of a `key=val&…` blob.
- `++grab-word` checks the **query string first** (everything after `?`), then the POST body —
  both are `w=…` blobs. So `/sum?w=abc`, `/sum` + body `w=abc`, and `w=hello+world` all work.
- `++esc` HTML-escapes user input (`& < > "`) before echoing it back into the page.

### `{N}` in `"..."` is interpolation

A `{ }` inside a `"..."` tape interpolates. CSS (which is full of `{ }`) therefore lives in a
`'''`-literal block (`++css`), where braces are literal — same trick as wordle.

### State + metric

State is the versioned noun `[%0 sums=@ud]` — just the cumulative computation count, which
nockd checkpoints so it survives `restart`. The current input/result are recomputed per
request, not stored. `metric: sums=<N>` is slogged on every request → the `SUMS` status; the
`/sum` line also logs `ord=` and `eq=` for visibility.

## Verification transcript

```
$ curl -s -X POST 'http://127.0.0.1:8090/sum?w=abc'         # ordinal 6, EQ 34
$ curl -s -X POST 'http://127.0.0.1:8090/sum?w=hello%20world' # ordinal 124, EQ 70
$ curl -s -X POST  http://127.0.0.1:8090/sum --data 'w=hello+world' # ordinal 124, EQ 70
$ curl -s -X POST 'http://127.0.0.1:8090/sum?w='            # 0 / 0 (graceful)
$ nockd ps | grep gematria                                  # running verified SUMS 4
```

## Gotchas reused (not re-derived here)

HTTP_PORT bridge, the `++inner` door taking exactly `load`/`peek`/`poke` (helpers live in the
prelude core), `EXPIRE_CACHE=1`, and the `grep -a` NUL-strip in `nockd.toml` — see the shared
GOTCHAS and wordle's RECIPE.
