//! lot-tls — a TLS client the LinuxOnTab page drives byte by byte.
//!
//! The page owns the transport: it opens a WISP TCP stream to <host>:443,
//! feeds what arrives into `lt_feed`, and sends whatever `lt_pull_cipher`
//! hands back. This module only does TLS: rustls with the ring provider,
//! certificates checked against the bundled Mozilla roots (webpki-roots)
//! for the requested host name, ALPN http/1.1. The WISP backend sees
//! ciphertext and the host name it was asked to connect to — nothing else.
//!
//! Plain C ABI, no wasm-bindgen; built for wasm32-wasip1. The page provides
//! the only WASI imports it needs: random_get and clock_time_get (plus
//! no-op stubs for the few std references fd_write/proc_exit/environ_*).
//!
//! Every call that can fail returns a negative number and leaves a message
//! for `lt_error`. A connection is a handle (index + 1) into a slot table.

use std::io::{Read, Write};
use std::sync::Arc;

use rustls::client::ClientConnection;
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, RootCertStore};

struct Conn {
    tls: ClientConnection,
    error: String,
}

static mut CONFIG: Option<Arc<ClientConfig>> = None;
static mut SLOTS: Vec<Option<Conn>> = Vec::new();
static mut LAST_ERROR: String = String::new();

#[allow(static_mut_refs)]
fn config() -> Result<Arc<ClientConfig>, String> {
    unsafe {
        if let Some(c) = &CONFIG {
            return Ok(c.clone());
        }
        let mut roots = RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut cfg = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map_err(|e| e.to_string())?
            .with_root_certificates(roots)
            .with_no_client_auth();
        cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
        let cfg = Arc::new(cfg);
        CONFIG = Some(cfg.clone());
        Ok(cfg)
    }
}

#[allow(static_mut_refs)]
fn slot(h: u32) -> Option<&'static mut Conn> {
    unsafe { SLOTS.get_mut((h as usize).checked_sub(1)?)?.as_mut() }
}

#[allow(static_mut_refs)]
fn set_global_error(msg: String) {
    unsafe { LAST_ERROR = msg };
}

unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 { &[] } else { std::slice::from_raw_parts(ptr, len) }
}

unsafe fn bytes_mut<'a>(ptr: *mut u8, len: usize) -> &'a mut [u8] {
    if len == 0 { &mut [] } else { std::slice::from_raw_parts_mut(ptr, len) }
}

// ── memory for the page ────────────────────────────────────────────────────
#[no_mangle]
pub extern "C" fn lt_alloc(len: usize) -> *mut u8 {
    let mut v = Vec::<u8>::with_capacity(len.max(1));
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    p
}

#[no_mangle]
pub unsafe extern "C" fn lt_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Vec::from_raw_parts(ptr, 0, len.max(1)));
    }
}

// ── connections ────────────────────────────────────────────────────────────
/// New client connection for `host` (UTF-8). Returns a handle > 0, or 0 on
/// error (message via lt_error(0, …)). The ClientHello is ready to pull.
#[no_mangle]
#[allow(static_mut_refs)]
pub unsafe extern "C" fn lt_new(host_ptr: *const u8, host_len: usize) -> u32 {
    let host = match std::str::from_utf8(bytes(host_ptr, host_len)) {
        Ok(h) => h.to_string(),
        Err(_) => { set_global_error("host is not UTF-8".into()); return 0; }
    };
    let name = match ServerName::try_from(host) {
        Ok(n) => n,
        Err(e) => { set_global_error(format!("bad host name: {e}")); return 0; }
    };
    let cfg = match config() {
        Ok(c) => c,
        Err(e) => { set_global_error(format!("tls config: {e}")); return 0; }
    };
    let tls = match ClientConnection::new(cfg, name) {
        Ok(t) => t,
        Err(e) => { set_global_error(format!("tls: {e}")); return 0; }
    };
    let c = Conn { tls, error: String::new() };
    if let Some(i) = SLOTS.iter().position(|s| s.is_none()) {
        SLOTS[i] = Some(c);
        (i + 1) as u32
    } else {
        SLOTS.push(Some(c));
        SLOTS.len() as u32
    }
}

/// Ciphertext from the network. Consumes as much as it can and returns the
/// number of bytes taken (>= 0); it stops early once decrypted data is
/// waiting (rustls caps that buffer at 16 KiB), so the page drains
/// lt_pull_plain and feeds the rest. <0 = fatal: -3 is a TLS error (a
/// failed certificate check lands here), see lt_error.
#[no_mangle]
pub unsafe extern "C" fn lt_feed(h: u32, ptr: *const u8, len: usize) -> i32 {
    let Some(c) = slot(h) else { return -1 };
    let all = bytes(ptr, len);
    let mut rest = all;
    while !rest.is_empty() {
        match c.tls.read_tls(&mut rest) {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) => { c.error = format!("read_tls: {e}"); return -2; }
        }
        match c.tls.process_new_packets() {
            Ok(io) => if io.plaintext_bytes_to_read() > 0 { break },
            Err(e) => { c.error = e.to_string(); return -3; }
        }
    }
    (all.len() - rest.len()) as i32
}

/// Plaintext to send (queued until the handshake is done). Returns 0 or <0.
#[no_mangle]
pub unsafe extern "C" fn lt_write(h: u32, ptr: *const u8, len: usize) -> i32 {
    let Some(c) = slot(h) else { return -1 };
    match c.tls.writer().write_all(bytes(ptr, len)) {
        Ok(()) => 0,
        Err(e) => { c.error = format!("write: {e}"); -2 }
    }
}

/// Copy up to `cap` bytes of pending ciphertext to `out`. Returns the
/// count (0 = nothing pending) or <0.
#[no_mangle]
pub unsafe extern "C" fn lt_pull_cipher(h: u32, out: *mut u8, cap: usize) -> i32 {
    let Some(c) = slot(h) else { return -1 };
    let mut buf = bytes_mut(out, cap);
    let mut total = 0usize;
    while c.tls.wants_write() && !buf.is_empty() {
        match c.tls.write_tls(&mut buf) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(e) => { c.error = format!("write_tls: {e}"); return -2; }
        }
    }
    total as i32
}

/// Copy up to `cap` bytes of decrypted data to `out`. Returns the count,
/// 0 when nothing is buffered right now, -4 once the peer closed cleanly
/// (close_notify) and everything was read, or another negative on error.
#[no_mangle]
pub unsafe extern "C" fn lt_pull_plain(h: u32, out: *mut u8, cap: usize) -> i32 {
    let Some(c) = slot(h) else { return -1 };
    match c.tls.reader().read(bytes_mut(out, cap)) {
        Ok(0) => -4,
        Ok(n) => n as i32,
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => 0,
        Err(e) => { c.error = format!("read: {e}"); -2 }
    }
}

/// 1 while the handshake is still in progress, else 0.
#[no_mangle]
pub unsafe extern "C" fn lt_handshaking(h: u32) -> i32 {
    slot(h).map(|c| c.tls.is_handshaking() as i32).unwrap_or(0)
}

/// Queue a close_notify (pull it with lt_pull_cipher).
#[no_mangle]
pub unsafe extern "C" fn lt_close(h: u32) {
    if let Some(c) = slot(h) {
        c.tls.send_close_notify();
    }
}

#[no_mangle]
#[allow(static_mut_refs)]
pub unsafe extern "C" fn lt_drop(h: u32) {
    if let Some(s) = SLOTS.get_mut((h as usize).wrapping_sub(1)) {
        *s = None;
    }
}

/// Last error for handle h (or the last lt_new failure when h == 0), copied
/// to out; returns its length.
#[no_mangle]
#[allow(static_mut_refs)]
pub unsafe extern "C" fn lt_error(h: u32, out: *mut u8, cap: usize) -> usize {
    let msg: &str = if h == 0 {
        LAST_ERROR.as_str()
    } else {
        match slot(h) { Some(c) => c.error.as_str(), None => "no such connection" }
    };
    let n = msg.len().min(cap);
    bytes_mut(out, n).copy_from_slice(&msg.as_bytes()[..n]);
    n
}
