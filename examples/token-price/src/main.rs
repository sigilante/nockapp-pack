//! token-price — an HTTP API NockApp that returns the live USD price of a Base token.
//!
//! Given a Base (chain) token contract address, it returns that token's USD price read LIVE
//! from the DexScreener public API. No API key required.
//!
//!   GET /price/<token-address>  -> {"token":"0x…","price_usd":<f64>,"pair":"<dex/pair>",
//!                                   "liquidity_usd":<f64>}
//!   GET /                       -> a tiny help page
//!
//! Architecture (see RECIPE.md): this is the balance-api shape — a pure-Rust axum HTTP
//! server that calls an external API per request, with a trivial `basic` Hoon kernel booted
//! only so the process is a valid supervised NockApp the way nockd expects. ALL logic lives
//! in this Rust file. Unlike balance-api the data source is NOT a Nockchain RPC; it is the
//! DexScreener HTTP API (https://api.dexscreener.com), whose base URL is hardcoded — there
//! is no endpoint-by-name and no `--endpoint` arg.
//!
//! Status metric (DESIGN status-cmd): every successful lookup logs one line of the form
//! `price token=… price_usd=… pair=… liquidity_usd=…`, and the deploy manifest scrapes
//! `price_usd=<n>` into the PRICE column of `nockd ps`. Because nockd's status command only
//! sees the RECENT log tail, an on-demand-only app would show an empty PRICE when idle — so a
//! background task polls a default token (NOCK on Base) every ~30s and emits the same line,
//! keeping PRICE current even with no traffic. The on-demand `GET /price/<addr>` API is
//! unchanged.

use std::error::Error;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Json};
use axum::routing::get;
use axum::Router;
use nockapp::kernel::boot;
use nockapp::noun::slab::NounSlab;
use nockapp::wire::{SystemWire, Wire};
use nockapp::NockApp;
use nockvm::noun::{D, T};
use nockvm_macros::tas;
use serde_json::{json, Value};
use tracing::{error, info, warn};

const DEFAULT_HTTP_PORT: u16 = 8086;

/// DexScreener token endpoint base. Hardcoded: this is a fixed public API, not a Nockchain
/// RPC, so there is no endpoint-by-name resolution. We append the token address.
const DEXSCREENER_BASE: &str = "https://api.dexscreener.com/latest/dex/tokens";

/// We only report prices for tokens on Base.
const CHAIN_ID: &str = "base";

/// Default token for the background price poll that keeps the PRICE status fresh when idle:
/// the $NOCK token on Base (deepest pool: Aerodrome NOCK/USDC).
const DEFAULT_TOKEN: &str = "0x9B5E262cF9bb04869ab40b19AF91D2dc85761722";

/// How often the background task refreshes the default-token price line.
const POLL_INTERVAL: Duration = Duration::from_secs(30);

/// Shared HTTP-handler state: a reqwest client and a cumulative request counter (for the
/// `metric: requests=<N>` status line).
struct AppState {
    http: reqwest::Client,
    requests: AtomicU64,
}

/// Resolve the HTTP listen port: `--port <n>` / `--port=<n>` CLI arg, else `NOCKD_APP_PORT`
/// (the port nockd injects), else `TOKEN_PRICE_PORT` env var, else the default 8086.
fn resolve_port() -> u16 {
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => {
                if let Some(p) = args.next().and_then(|s| s.parse().ok()) {
                    return p;
                }
            }
            other => {
                if let Some(p) = other.strip_prefix("--port=").and_then(|s| s.parse().ok()) {
                    return p;
                }
            }
        }
    }
    // nockd injects NOCKD_APP_PORT (declared once as `port` in nockd.toml); honor it so the
    // dashboard's port/relay link and the port we actually bind stay in sync.
    if let Ok(p) = std::env::var("NOCKD_APP_PORT")
        .and_then(|s| s.parse().map_err(|_| std::env::VarError::NotPresent))
    {
        return p;
    }
    if let Ok(p) = std::env::var("TOKEN_PRICE_PORT")
        .and_then(|s| s.parse().map_err(|_| std::env::VarError::NotPresent))
    {
        return p;
    }
    DEFAULT_HTTP_PORT
}

/// An EVM token address is `0x` followed by exactly 40 hex digits. We validate syntactically
/// to reject obvious garbage with a 400 before spending an HTTP round-trip.
fn looks_like_address(s: &str) -> bool {
    let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) else {
        return false;
    };
    hex.len() == 40 && hex.bytes().all(|b| b.is_ascii_hexdigit())
}

/// A resolved price: the deepest Base pool for the token.
struct PriceInfo {
    price_usd: f64,
    pair: String,
    liquidity_usd: f64,
}

/// The core read, shared by the route. Calls DexScreener for the token, filters to Base
/// pairs, picks the deepest (max `liquidity.usd`) pool, and reads its `priceUsd`.
///
/// Returns:
///   Ok(Some(info))  — a Base pool was found
///   Ok(None)        — DexScreener responded but the token has no Base pool (-> 404)
///   Err(msg)        — upstream/transport/parse failure (-> 502)
async fn lookup_price(
    http: &reqwest::Client,
    token: &str,
) -> Result<Option<PriceInfo>, String> {
    let url = format!("{DEXSCREENER_BASE}/{token}");
    let resp = http
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("request to DexScreener failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("DexScreener returned HTTP {}", resp.status()));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| format!("could not parse DexScreener response: {e}"))?;

    let pairs = match body.get("pairs") {
        Some(Value::Array(p)) => p,
        // DexScreener returns `"pairs": null` for an unknown token.
        _ => return Ok(None),
    };

    // Filter to Base, then pick the pool with the deepest liquidity (most reliable price).
    let best = pairs
        .iter()
        .filter(|p| p.get("chainId").and_then(Value::as_str) == Some(CHAIN_ID))
        .max_by(|a, b| {
            let la = liquidity_usd(a);
            let lb = liquidity_usd(b);
            la.partial_cmp(&lb).unwrap_or(std::cmp::Ordering::Equal)
        });

    let Some(best) = best else {
        return Ok(None);
    };

    // `priceUsd` is a string in the DexScreener payload (already in USD).
    let price_usd = best
        .get("priceUsd")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<f64>().ok())
        .ok_or_else(|| "DexScreener pool had no parseable priceUsd".to_string())?;

    let dex = best
        .get("dexId")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let base_sym = best
        .pointer("/baseToken/symbol")
        .and_then(Value::as_str)
        .unwrap_or("?");
    let quote_sym = best
        .pointer("/quoteToken/symbol")
        .and_then(Value::as_str)
        .unwrap_or("?");
    let pair = format!("{dex}/{base_sym}-{quote_sym}");

    Ok(Some(PriceInfo {
        price_usd,
        pair,
        liquidity_usd: liquidity_usd(best),
    }))
}

/// Read `pair.liquidity.usd` as an f64 (0.0 if absent).
fn liquidity_usd(pair: &Value) -> f64 {
    pair.pointer("/liquidity/usd")
        .and_then(Value::as_f64)
        .unwrap_or(0.0)
}

/// Bump the cumulative request counter (kept for log/debug visibility; not the PRICE metric).
fn record_request(state: &AppState) {
    let n = state.requests.fetch_add(1, Ordering::Relaxed) + 1;
    println!("metric: requests={n}");
}

/// Emit the one greppable price line that nockd's status-cmd scrapes (`price_usd=<n>` ->
/// PRICE column). Used by BOTH the on-demand handler and the background poll, so the format
/// stays identical.
fn emit_price_line(token: &str, info: &PriceInfo) {
    info!(
        "price token={token} price_usd={} pair={} liquidity_usd={}",
        info.price_usd, info.pair, info.liquidity_usd
    );
}

/// Background task: poll the default token every `POLL_INTERVAL` and emit its price line, so
/// the PRICE status in `nockd ps` stays current even when the API is idle. Failures are
/// logged (warn) and retried next tick — they never crash the server.
async fn price_poller(http: reqwest::Client) {
    let mut ticker = tokio::time::interval(POLL_INTERVAL);
    loop {
        ticker.tick().await;
        match lookup_price(&http, DEFAULT_TOKEN).await {
            Ok(Some(info)) => emit_price_line(DEFAULT_TOKEN, &info),
            Ok(None) => warn!("background poll: no Base pool for default token {DEFAULT_TOKEN}"),
            Err(e) => warn!("background poll failed for {DEFAULT_TOKEN}: {e}"),
        }
    }
}

/// `GET /price/<token>`
async fn price_path(
    State(state): State<Arc<AppState>>,
    Path(token): Path<String>,
) -> impl IntoResponse {
    record_request(&state);

    if !looks_like_address(&token) {
        warn!("rejecting malformed token address: {token:?}");
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "invalid token address",
                "detail": "expected an EVM address: 0x followed by 40 hex digits",
                "token": token,
            })),
        )
            .into_response();
    }

    match lookup_price(&state.http, &token).await {
        Ok(Some(info)) => {
            emit_price_line(&token, &info);
            (
                StatusCode::OK,
                Json(json!({
                    "token": token,
                    "price_usd": info.price_usd,
                    "pair": info.pair,
                    "liquidity_usd": info.liquidity_usd,
                })),
            )
                .into_response()
        }
        Ok(None) => {
            warn!("no Base pool found for token={token}");
            (
                StatusCode::NOT_FOUND,
                Json(json!({
                    "error": "no Base pool found",
                    "detail": "DexScreener has no Base (chainId=base) trading pair for this token",
                    "token": token,
                })),
            )
                .into_response()
        }
        Err(e) => {
            error!("lookup failed for {token}: {e}");
            (
                StatusCode::BAD_GATEWAY,
                Json(json!({
                    "error": "upstream lookup failed",
                    "detail": e,
                    "token": token,
                })),
            )
                .into_response()
        }
    }
}

/// `GET /` — a tiny help page.
async fn root() -> impl IntoResponse {
    Html(
        r#"<!doctype html>
<html><head><meta charset="utf-8"><title>token-price</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; line-height: 1.5">
<h1>token-price</h1>
<p>Live USD price of any token on <b>Base</b>, read from
<a href="https://dexscreener.com">DexScreener</a>. No API key.</p>
<h2>Usage</h2>
<pre>GET /price/&lt;base-token-address&gt;</pre>
<p>Returns JSON: <code>{"token":"0x…","price_usd":&lt;f64&gt;,"pair":"&lt;dex/pair&gt;","liquidity_usd":&lt;f64&gt;}</code>
from the deepest Base liquidity pool for that token.</p>
<h2>Example</h2>
<p>The $NOCK token on Base:</p>
<pre>curl /price/0x9B5E262cF9bb04869ab40b19AF91D2dc85761722</pre>
</body></html>
"#,
    )
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = boot::default_boot_cli(false);
    boot::init_default_tracing(&cli);

    // The nockchain dependency graph pulls in BOTH rustls crypto providers (`ring` and
    // `aws-lc-rs`), so rustls cannot auto-pick one and panics on the first TLS handshake
    // ("Could not automatically determine the process-level CryptoProvider"). Install one
    // explicitly before any TLS use. Required for the https DexScreener call.
    if rustls::crypto::ring::default_provider()
        .install_default()
        .is_err()
    {
        warn!("a rustls CryptoProvider was already installed");
    }

    // Boot the kernel so this is a real, supervised NockApp (consumes out.jam, sets up the
    // PMA/event-log state dir). nockd stages out.jam into the app's state dir, which is also
    // our cwd, so the relative read works both under `nockup run` and under nockd.
    let kernel = fs::read("out.jam").map_err(|e| format!("Failed to read out.jam: {}", e))?;
    let mut nockapp: NockApp = boot::setup(&kernel, cli, &[], "token-price", None).await?;

    // Fire the kernel's demo poke once so the kernel is genuinely exercised at boot.
    let mut poke_slab = NounSlab::new();
    let command_noun = T(&mut poke_slab, &[D(tas!(b"cause")), D(0x0)]);
    poke_slab.set_root(command_noun);
    if let Err(e) = nockapp.poke(SystemWire.to_wire(), poke_slab).await {
        warn!("kernel boot poke failed (non-fatal): {e:?}");
    }
    // Keep the kernel handle alive for the lifetime of the process. We do not call
    // `nockapp.run()`: this app's work is the Rust HTTP server below, not Hoon-side drivers.
    let _nockapp = nockapp;

    let port = resolve_port();
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .user_agent("token-price-nockapp/0.1")
        .build()
        .map_err(|e| format!("failed to build HTTP client: {e}"))?;
    let state = Arc::new(AppState {
        http: http.clone(),
        requests: AtomicU64::new(0),
    });

    info!("token-price starting; data source={DEXSCREENER_BASE}; http port={port}");
    // Greppable boot marker so logs always show the resolved config.
    println!("metric: source={DEXSCREENER_BASE}");

    // Background poll of the default token keeps the PRICE status fresh when idle. It uses its
    // own clone of the reqwest client; the on-demand API state owns the other clone.
    tokio::spawn(price_poller(http));

    let app = Router::new()
        .route("/", get(root))
        .route("/price/:token", get(price_path))
        .with_state(state);

    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .map_err(|e| format!("failed to bind {addr}: {e}"))?;
    info!("listening on http://{addr}");

    // Graceful shutdown: nockd SIGTERMs on stop/restart. Shut the server down cleanly on
    // SIGTERM (and Ctrl-C when run by hand).
    let shutdown = async {
        let mut sigterm =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(s) => s,
                Err(e) => {
                    error!("failed to install SIGTERM handler: {e}");
                    let _ = tokio::signal::ctrl_c().await;
                    return;
                }
            };
        tokio::select! {
            _ = sigterm.recv() => info!("received SIGTERM; shutting down cleanly"),
            _ = tokio::signal::ctrl_c() => info!("received Ctrl-C; shutting down cleanly"),
        }
    };

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown)
        .await
        .map_err(|e| format!("http server error: {e}"))?;

    Ok(())
}
