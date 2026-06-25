//! gematria: compute the English-ordinal gematria (A=1 .. Z=26, case-insensitive, spaces and
//! other non-letters skipped) of a word or phrase, with ALL logic (char->value mapping, the
//! summing fold, percent/plus form decoding, HTML rendering) living in the Hoon kernel. This
//! binary just boots the kernel from `out.jam` and attaches the library's HTTP driver.
//!
//! ## Port
//!
//! We pin the nockchain crates at a rev that includes PR #134's `HTTP_PORT` support, so the
//! stock `http_driver()` binds 127.0.0.1:$HTTP_PORT directly in local mode -- NO TCP proxy.
//! nockd declares the port once in nockd.toml and exports it as NOCKD_APP_PORT; we bridge that
//! to HTTP_PORT below, with DEFAULT_PORT=8090 as the standalone fallback.
//!
//! ## Cache
//!
//! The spec asks for `EXPIRE_CACHE=0`, but at this rev (07577127) `EXPIRE_CACHE=0` PANICS the
//! driver: it builds `tokio::time::interval(Duration::from_secs(0))` ("`period` must be
//! non-zero"). So we set `EXPIRE_CACHE=1` (a 1-second TTL) -- the smallest value that doesn't
//! crash. Sums are POSTs (never cached); GET `/` is re-poked at least once a second, keeping
//! the `metric: sums=<N>` line current.

use std::error::Error;
use std::fs;

use nockapp::kernel::boot;
use nockapp::{http_driver, NockApp};
use tokio::signal::unix::{signal, SignalKind};

/// Standalone fallback port (when nockd does not export NOCKD_APP_PORT). 8090: 8081-8089 taken.
const DEFAULT_PORT: &str = "8090";

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // 1-second GET-cache TTL (set before the driver starts). NOT 0: EXPIRE_CACHE=0 panics this
    // rev's driver (Duration::ZERO -> "period must be non-zero"). 1 is the safe minimum.
    std::env::set_var("EXPIRE_CACHE", "1");
    // Force local mode (bind 127.0.0.1, no ACME/HTTPS).
    std::env::set_var("HTTPS_DOMAIN", "localhost");
    // PR #134: the stock http_driver() reads HTTP_PORT for its local-mode bind. No proxy.
    // nockd exports NOCKD_APP_PORT (the port declared in nockd.toml); bridge it to HTTP_PORT.
    if let Ok(p) = std::env::var("NOCKD_APP_PORT") {
        std::env::set_var("HTTP_PORT", p);
    } else if std::env::var("HTTP_PORT").is_err() {
        std::env::set_var("HTTP_PORT", DEFAULT_PORT);
    }

    // boot::default_boot_cli builds a Cli struct directly; it does NOT parse argv, so nockd's
    // injected args do not collide with the boot CLI.
    let cli = boot::default_boot_cli(false);
    boot::init_default_tracing(&cli);

    let port = std::env::var("HTTP_PORT").unwrap_or_else(|_| DEFAULT_PORT.to_string());
    tracing::info!("gematria starting; HTTP port {port}");

    // The kernel jam is read cwd-relative. Under nockd the cwd is the app's state dir, where
    // nockd places out.jam; running by hand, run from the dir containing out.jam.
    let kernel = fs::read("out.jam").map_err(|e| format!("Failed to read out.jam: {}", e))?;

    // At this rev boot::setup takes `cli: Cli` (not Option<Cli>) and NockApp is generic
    // NockApp<J: Jammer> (inferred here).
    let mut nockapp: NockApp = boot::setup(&kernel, cli, &[], "gematria", None)
        .await
        .map_err(|e| format!("Kernel setup failed: {}", e))?;

    nockapp.add_io_driver(http_driver()).await;

    // Run the app, racing against SIGTERM/SIGINT so nockd stop/restart shuts us down cleanly.
    let mut sigterm = signal(SignalKind::terminate())?;
    tokio::select! {
        res = nockapp.run() => {
            res.map_err(|e| format!("NockApp run failed: {}", e))?;
        }
        _ = sigterm.recv() => {
            tracing::info!("gematria: received SIGTERM; shutting down cleanly");
        }
        _ = tokio::signal::ctrl_c() => {
            tracing::info!("gematria: received SIGINT; shutting down cleanly");
        }
    }

    Ok(())
}
