# CLAUDE.md — NockApp Pack

Self-contained demo NockApps under `examples/`. Each builds with **nockup**, deploys under
**nockd** (`nockd deploy -f nockd.toml`), and is observable via a status metric in `nockd ps`.
Canonical repo; origin = `github.com/sigilante/nockapp-pack` (branch `master`).

## Standard workflow (per example)

1. **Scaffold** — copy `/Users/neal/zorp/nockd/examples/_skeleton/` (or a sibling example of the
   same shape) and read `/Users/neal/zorp/nockd/examples/GOTCHAS.md` first.
2. **Write** minimal Hoon (all app logic lives in the kernel) + the thin Rust wrapper.
3. **Build** — `nockup project build <name>` (run from the parent dir). The real success signal
   is that `out.jam` was rewritten — nockup prints a green ✓ even when the Hoon compile crashed.
4. **Deploy** — project-mode: `nockd deploy -f nockd.toml` then `nockd restart <name>`
   (deploy registers the new artifact; restart swaps the running process onto it).
5. **Verify** — `nockd ps` shows `running` + `verified` + the status metric; then exercise it
   (curl / play). Assert on the `ps` STATUS column, not piped `nockd logs`.
6. **Document** — `README.md` + `RECIPE.md` (transcript + any new rough edges).
7. **Commit** here (`master`) and **push** to origin (`nockapp-pack`). This repo is the sole
   home for the examples — the nockd repo gitignores `examples/` (do **not** mirror there).
8. **Register in Typhoon** (`../typhoon`) at the release SHA — see below.

## Conventions

- **Rev policy:** HTTP-driver apps → nockchain `07577127` + `HTTP_PORT` (via `NOCKD_APP_PORT`)
  + `EXPIRE_CACHE=1` (**0 panics** at this rev). Other apps → `6d29078`. Bump all together at
  release. `rust-toolchain.toml` pins `nightly-2026-04-03`.
- **Deploy mode:** project-mode preferred. Multi-bin projects (the `grpc` template) can't use
  project-mode — deploy prebuilt with `--bin`/`--jam`.
- **Status metric:** log one greppable line `metric: key=val`; scrape it in `nockd.toml`
  `[deploy.status]` (`grep -aoE 'key=[0-9.]+' | tail -1 | grep -aoE '[0-9.]+'`; allow the dot
  for decimals; suffix per-source keys so an aggregate key doesn't cross-match).
- **Port:** declare `port = N` in `nockd.toml`; HTTP-driver apps bridge `NOCKD_APP_PORT`→`HTTP_PORT`
  in main.rs; axum apps take `args = ["--port", "{port}"]`.
- **Icon:** an emoji-tile `icon.svg` per app + `icon = "icon.svg"` under `[deploy]`.
- **Gotchas:** `/Users/neal/zorp/nockd/examples/GOTCHAS.md` is authoritative; record new ones in
  the app's `RECIPE.md`.
- **Secrets:** never commit secrets/keys/state. Per-app `.gitignore` excludes `target/`,
  `out.jam`, `app.nock`, `.data.*`. Re-scan tracked files before pushing (public repo).

## Typhoon registration (verifiability — milestone A: reproducible `out.jam`)

Goal: an artifact is verifiable when its `out.jam` can be reproduced from a registry-pinned
source + a pinned toolchain. Typhoon pins the source; nockd's attestation records the toolchain.

- Edit `../typhoon/scripts/regen-registry.py` — **never hand-edit `registry.toml`** (generated;
  CI runs `generate --check`).
- Add `nockapp-pack` to `WORKSPACES` (git_url, `ref` = the release SHA, description, root_path).
- Add **explicit per-app package entries** — `nockapp/<app>` → `hoon/app/app.hoon`, deps `[]`
  (apps are self-contained: empty Hoon deps; local `/+`/`/=` imports are bundled). Use the
  explicit-list pattern (like `URBIT_PACKAGES`), not import-derivation.
- Run `scripts/regen-registry.py generate`; confirm `generate --check` passes; commit in typhoon.
- **Pin a stable release SHA** (after the suite converges), not a moving HEAD.
- The **attestation side** (recording source ref + hoonc/nockup version so `nockd verify` can
  re-run hoonc and compare the kernel hash) is handled in the **nockd** workstream — out of scope here.
