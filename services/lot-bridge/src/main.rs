use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::Mutex;
use tokio_tungstenite::{connect_async, tungstenite::Message, WebSocketStream, MaybeTlsStream};
use tokio::net::TcpStream as StdTcpStream;
use futures_util::{SinkExt, StreamExt};

const STATUS_PATH: &str = "/tmp/lot-bridge.status.json";
const CODE_PATH:   &str = "/tmp/lot-bridge.code";
const PID_PATH:    &str = "/tmp/lot-bridge.pid";
const LOG_PATH:    &str = "/tmp/lot-bridge.log";

// ── CLI ───────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "lot-bridge", version, about = "Persistent WS↔TCP bridge pool for LinuxOnTab")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
    /// Tunnel relay base URL
    #[arg(long, global = true, default_value = "https://linuxontab-tunnel.fly.dev", env = "LOT_BRIDGE_RELAY")]
    relay: String,
}

#[derive(Subcommand)]
enum Cmd {
    /// Register ports and run bridge pool (run in foreground; use & to background)
    Up {
        /// TCP ports to bridge (default: 22 8080)
        #[arg(default_values = &["22", "8080"])]
        ports: Vec<u16>,
        /// WebSocket connections to maintain per port
        #[arg(long, short, default_value = "8")]
        pool: usize,
    },
    /// Print status JSON from running daemon
    Status,
    /// Stop the running daemon (SIGTERM)
    Down,
}

// ── Data types ────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Clone, Default)]
struct PortStats {
    /// WS connections currently open
    connected: usize,
    /// Lifetime bridges spawned for this port
    total_spawned: u64,
}

#[derive(Debug, Serialize)]
struct Status {
    code: String,
    relay: String,
    ports: Vec<u16>,
    pool_size: usize,
    pool: HashMap<String, PortStats>,
    uptime_s: u64,
    pid: u32,
}

#[derive(Debug, Deserialize)]
struct RegisterResp {
    code: String,
}

// ── Entry point ───────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.cmd {
        Cmd::Up { ports, pool } => run_up(cli.relay, ports, pool).await?,
        Cmd::Status => {
            match std::fs::read_to_string(STATUS_PATH) {
                Ok(s)  => println!("{}", s),
                Err(_) => eprintln!("lot-bridge is not running (no status file at {})", STATUS_PATH),
            }
        }
        Cmd::Down => {
            match std::fs::read_to_string(PID_PATH) {
                Ok(s) => {
                    let pid = s.trim().to_owned();
                    let _ = std::process::Command::new("kill").arg(&pid).status();
                    println!("[lot-bridge] sent SIGTERM to pid {}", pid);
                    // Files removed by the daemon itself on shutdown
                }
                Err(_) => eprintln!("[lot-bridge] not running (no pid file at {})", PID_PATH),
            }
        }
    }

    Ok(())
}

// ── run_up ────────────────────────────────────────────────────────────────────

async fn run_up(relay: String, ports: Vec<u16>, pool_size: usize) -> Result<()> {
    // Lower OOM score so the kernel avoids killing us under memory pressure
    let _ = std::fs::write("/proc/self/oom_score_adj", "-500");

    // Register ports with the relay
    print!("[lot-bridge] registering ports {:?} with {} ... ", ports, relay);
    let code = register_ports(&relay, &ports).await
        .context("failed to register ports with relay")?;
    println!("code: {}", code);

    // Write PID and code files
    std::fs::write(PID_PATH, std::process::id().to_string())?;
    std::fs::write(CODE_PATH, &code)?;
    println!("[lot-bridge] pid file: {}  code file: {}", PID_PATH, CODE_PATH);
    println!("[lot-bridge] status file: {}  log file: {}", STATUS_PATH, LOG_PATH);

    // Shared per-port stats
    let stats: Arc<Mutex<HashMap<String, PortStats>>> = Arc::new(Mutex::new(
        ports.iter().map(|p| (p.to_string(), PortStats::default())).collect(),
    ));

    let start = Instant::now();

    // Spawn pool manager for each port
    for &port in &ports {
        tokio::spawn(run_port_pool(
            relay.clone(), code.clone(), port, pool_size, stats.clone(),
        ));
    }

    // Spawn status writer (every 5 s)
    {
        let relay_c  = relay.clone();
        let code_c   = code.clone();
        let ports_c  = ports.clone();
        let stats_c  = stats.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                let pool = stats_c.lock().await.clone();
                let s = Status {
                    code: code_c.clone(),
                    relay: relay_c.clone(),
                    ports: ports_c.clone(),
                    pool_size,
                    pool,
                    uptime_s: start.elapsed().as_secs(),
                    pid: std::process::id(),
                };
                if let Ok(json) = serde_json::to_string_pretty(&s) {
                    let _ = std::fs::write(STATUS_PATH, json);
                }
            }
        });
    }

    // Wait for SIGTERM or Ctrl-C
    let mut sigterm = signal(SignalKind::terminate())?;
    tokio::select! {
        _ = sigterm.recv()        => println!("\n[lot-bridge] SIGTERM received, shutting down"),
        _ = tokio::signal::ctrl_c() => println!("\n[lot-bridge] Ctrl-C, shutting down"),
    }

    // Cleanup: unregister + remove tmp files
    let _ = unregister_ports(&relay, &code).await;
    for path in [PID_PATH, CODE_PATH, STATUS_PATH] {
        std::fs::remove_file(path).ok();
    }
    println!("[lot-bridge] done");
    Ok(())
}

// ── Pool manager ──────────────────────────────────────────────────────────────

async fn run_port_pool(
    relay: String,
    code: String,
    port: u16,
    pool_size: usize,
    stats: Arc<Mutex<HashMap<String, PortStats>>>,
) {
    let (done_tx, mut done_rx) = tokio::sync::mpsc::unbounded_channel::<()>();

    // Prime the pool
    for _ in 0..pool_size {
        inc_connected(&stats, port, 1).await;
        spawn_bridge(relay.clone(), code.clone(), port, done_tx.clone(), stats.clone());
    }

    // Replenish one-for-one as bridges finish
    while done_rx.recv().await.is_some() {
        // Brief back-off to avoid hammering the relay when it's erroring
        tokio::time::sleep(Duration::from_millis(500)).await;
        inc_connected(&stats, port, 1).await;
        spawn_bridge(relay.clone(), code.clone(), port, done_tx.clone(), stats.clone());
    }
}

fn spawn_bridge(
    relay: String,
    code: String,
    port: u16,
    done_tx: tokio::sync::mpsc::UnboundedSender<()>,
    stats: Arc<Mutex<HashMap<String, PortStats>>>,
) {
    tokio::spawn(async move {
        if let Err(e) = bridge_task(&relay, &code, port).await {
            // Only log unexpected errors (not normal close / connection refused)
            let msg = e.to_string();
            if !msg.contains("Connection refused")
                && !msg.contains("Connection reset")
                && !msg.contains("broken pipe")
                && !msg.contains("WebSocket")
            {
                eprintln!("[lot-bridge] bridge port {} error: {}", port, e);
            }
        }
        // Decrement connected count
        let mut st = stats.lock().await;
        if let Some(ps) = st.get_mut(&port.to_string()) {
            ps.connected = ps.connected.saturating_sub(1);
        }
        let _ = done_tx.send(());
    });
}

async fn inc_connected(stats: &Arc<Mutex<HashMap<String, PortStats>>>, port: u16, n: u64) {
    let mut st = stats.lock().await;
    if let Some(ps) = st.get_mut(&port.to_string()) {
        ps.connected += 1;
        ps.total_spawned += n;
    }
}

// ── Bridge task (one WS↔TCP splice) ──────────────────────────────────────────

async fn bridge_task(relay: &str, code: &str, port: u16) -> Result<()> {
    // 1. TCP connect to local service (e.g. sshd on 127.0.0.1:22)
    let tcp = StdTcpStream::connect(format!("127.0.0.1:{}", port)).await?;
    let (mut tcp_rx, mut tcp_tx) = tokio::io::split(tcp);

    // 2. WS connect to relay — https://… → wss://…
    let ws_base = relay
        .replacen("https://", "wss://", 1)
        .replacen("http://",  "ws://",  1);
    let ws_url = format!("{}/port/guest?code={}&port={}", ws_base, code, port);

    let (ws, _): (WebSocketStream<MaybeTlsStream<StdTcpStream>>, _) = connect_async(ws_url).await?;
    let (mut ws_tx, mut ws_rx) = ws.split();

    // 3. Splice bidirectionally until either side closes
    let tcp_to_ws = async {
        let mut buf = vec![0u8; 32768];
        loop {
            let n = tcp_rx.read(&mut buf).await?;
            if n == 0 { break; }
            ws_tx.send(Message::Binary(buf[..n].to_vec().into())).await?;
        }
        let _ = ws_tx.close().await;
        Ok::<_, anyhow::Error>(())
    };

    let ws_to_tcp = async {
        while let Some(msg) = ws_rx.next().await {
            match msg? {
                Message::Binary(data) => tcp_tx.write_all(&data).await?,
                Message::Text(text)   => tcp_tx.write_all(text.as_bytes()).await?,
                Message::Close(_)     => break,
                _                     => {}
            }
        }
        Ok::<_, anyhow::Error>(())
    };

    tokio::select! {
        r = tcp_to_ws => r?,
        r = ws_to_tcp => r?,
    }

    Ok(())
}

// ── Relay HTTP calls ──────────────────────────────────────────────────────────

async fn register_ports(relay: &str, ports: &[u16]) -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()?;
    let resp = client
        .post(format!("{}/port/register", relay))
        .json(&serde_json::json!({ "ports": ports }))
        .send()
        .await
        .context("POST /port/register failed")?
        .error_for_status()
        .context("relay returned error status")?;

    let body: RegisterResp = resp.json().await.context("failed to parse register response")?;
    Ok(body.code)
}

async fn unregister_ports(relay: &str, code: &str) -> Result<()> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()?;
    let _ = client
        .post(format!("{}/port/unregister", relay))
        .json(&serde_json::json!({ "code": code }))
        .send()
        .await;
    Ok(())
}
