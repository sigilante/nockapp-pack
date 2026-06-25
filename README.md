# NockApp Pack

A collection of NockApp programs.

![](./img/hero.jpg)

Each example is self-contained, builds with [nockup](https://github.com/nockchain/nockchain/tree/master/crates/nockup), and deploys under [nockd](https://github.com/sigilante/nockd) in one command: `nockd deploy -f nockd.toml`.

| App | What it does | Port | Status |
|-----|--------------|------|--------|
| [`chain-watch`](examples/chain-watch) | Watches a Nockchain RPC and logs the chain tip; deploy one per endpoint for a lag-comparison fleet | — | `HEIGHT` |
| [`nock-price`](examples/nock-price) | Aggregates the live $NOCK price across Base, Kraken, and SafeTrade | — | `USD` |
| [`balance-api`](examples/balance-api) | `GET /balance/<pubkey>` → on-chain balance over gRPC | 8082 | `REQ` |
| [`token-price`](examples/token-price) | `GET /price/<base-token>` → USD price from DexScreener | 8086 | `PRICE` |
| [`http-counter`](examples/http-counter) | A counter served over HTTP that persists across restarts | 8081 | `COUNT` |
| [`http-static`](examples/http-static) | Serves static pages rendered by the Hoon kernel | 8083 | `REQ` |
| [`echo-grpc`](examples/echo-grpc) | poke→peek echo over the private gRPC surface | 5561 | `POKES` |
| [`hello-basic`](examples/hello-basic) | The minimal supervised NockApp: a heartbeat tick | — | `TICKS` |
| [`minesweeper`](examples/minesweeper) | Playable Minesweeper, all game logic in Hoon | 8084 | `MOVES` |
| [`common-blog`](examples/common-blog) | A minimal self-hosted blog (publish/read) | 8085 | `POSTS` |
| [`wordle`](examples/wordle) | Wordle with green/yellow/grey feedback | 8088 | `GUESSES` |
| [`conway`](examples/conway) | Conway's Game of Life | 8089 | `GEN` |
| [`solitaire`](examples/solitaire) | Drag-and-drop Klondike, with card sprites reused from the blackjack project | 8087 | `MOVES` |

Chain-aware apps read a Nockchain RPC by named endpoint (read-only). Standalone games and tools keep all their logic in the Hoon kernel; the Rust wrapper only boots the kernel and runs the HTTP/gRPC driver.

