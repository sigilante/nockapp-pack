# gematria

Compute the **gematria** (letter-sum) of a word or phrase, served over HTTP — with all the
logic (the char→value map, the summing fold, percent/plus form decoding, HTML rendering)
living in the **Hoon kernel**. The Rust wrapper only boots the kernel and runs the library
HTTP driver.

It computes **two** schemes for any input and shows both:

- **English ordinal** — A=1, B=2, … Z=26 (case-insensitive). So `(letter − 'a' + 1)`.
- **English Qaballa (EQ)** — the Lees / *Liber Trigrammaton* cipher: each letter's value is
  its 1-based position in the sequence **`ALWHSDOZKVGRCNYJUFQBMXITEP`** (A=1, L=2, W=3, H=4,
  S=5, D=6, O=7, Z=8, K=9, V=10, G=11, R=12, C=13, N=14, Y=15, J=16, U=17, F=18, Q=19, B=20,
  M=21, X=22, I=23, T=24, E=25, P=26). Source:
  <https://en.wikipedia.org/wiki/English_Qaballa>.

Both schemes **skip spaces and any other non-letter characters** — a non-letter maps to 0,
so the fold ignores it for free.

Examples:

| input         | ordinal | EQ  |
|---------------|---------|-----|
| `abc`         | 6       | 34  |
| `hello world` | 124     | 70  |

(`abc` EQ = a=1 + b=20 + c=13 = 34; `hello world` skips the space in both schemes.)

## Deploy

```sh
nockd deploy -f nockd.toml      # project-mode: nockd builds via nockup, ships, runs
nockd restart gematria          # swap the live process onto the new artifact
nockd ps                        # gematria · running · verified · SUMS <n>
```

Serves on **http://127.0.0.1:8090/**.

## Use

Open `http://127.0.0.1:8090/` in a browser, type a word or phrase, press **Sum** — both
totals render with a per-letter breakdown. Or drive it with curl:

```sh
curl http://127.0.0.1:8090/                                # landing form
curl -X POST "http://127.0.0.1:8090/sum?w=abc"             # query string
curl -X POST "http://127.0.0.1:8090/sum?w=hello%20world"   # %20 = space
curl -X POST  http://127.0.0.1:8090/sum --data "w=hello+world"   # form body ('+' = space)
```

The phrase may arrive in the query string (`?w=…`) or the POST body (`w=…`); the browser
form uses the body. Query takes precedence if both are present. Empty / space-only input
renders a total of 0 gracefully.

## How to see it work

`nockd ps` shows the **SUMS** status — the cumulative count of computations this session,
scraped from the `metric: sums=<N>` log line the kernel emits on every `/sum` (and reports
the current count on every `GET /`, so the status is always current).

## Notes

- HTTP port is declared once in `nockd.toml` (`port = 8090`); nockd exports it as
  `NOCKD_APP_PORT`, and the wrapper bridges that to the driver's `HTTP_PORT` (nockchain
  PR #134 — no proxy). Standalone fallback is 8090. Built against nockchain rev `07577127…`.
- `EXPIRE_CACHE=1` (not 0): `0` panics this rev's HTTP driver (`Duration::ZERO`). See
  `RECIPE.md`.
- There is no `de-purl` in this stdlib, so URL form decoding (`+` → space, `%XX` → byte) is
  hand-rolled in Hoon. User input is HTML-escaped before being echoed back into the page.
