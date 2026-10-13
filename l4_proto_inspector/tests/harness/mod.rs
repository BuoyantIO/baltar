use std::net::SocketAddr;
use std::process::Stdio;
use std::time::{Duration, Instant};

use l4_proto_inspector::core::{Event, FlowDirection, Mode, Tlv};
use l4_proto_inspector::shell::{LogSink, Proxy, Record};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::{Child, ChildStderr, Command};
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokio::task::JoinHandle;

/// Linkerd client identity carried in the synthetic PROXY v2 header TLV.
pub const IDENTITY: &str = "client.inspect.serviceaccount.identity.linkerd.cluster.local";
/// Upper bound on how long a round trip may wait for the proxy to close the client stream.
const DEADLINE: Duration = Duration::from_secs(10);

/// Test-only helpers: an echo backend, a proxy in front of it, and synthetic client bytes.
pub struct Harness;

impl Harness {
    /// Starts an echo backend on an ephemeral port that half-closes after echoing everything.
    pub async fn echo_backend() -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((sock, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let (mut rd, mut wr) = sock.into_split();
                    let _ = tokio::io::copy(&mut rd, &mut wr).await;
                    let _ = wr.shutdown().await;
                });
            }
        });
        addr
    }

    /// Starts a proxy with `modes` in front of a fresh echo backend; returns its address and event stream.
    pub async fn proxy(modes: Vec<Mode>) -> (SocketAddr, UnboundedReceiver<Record>) {
        let backend = Self::echo_backend().await;
        let (tx, rx) = mpsc::unbounded_channel();
        let proxy = Proxy::bind(
            "127.0.0.1:0",
            backend.to_string(),
            modes,
            LogSink::new(tx, Instant::now()),
        )
        .await
        .unwrap();
        let addr = proxy.local_addr().unwrap();
        tokio::spawn(proxy.run());
        (addr, rx)
    }

    /// Sends `data`, half-closes, and returns everything the proxy sends back until EOF.
    pub async fn round_trip(addr: SocketAddr, data: Vec<u8>) -> Vec<u8> {
        let sock = TcpStream::connect(addr).await.unwrap();
        let (mut rd, mut wr) = sock.into_split();
        // Write concurrently with reading so large payloads cannot deadlock on full buffers.
        let writer = tokio::spawn(async move {
            // A proxy that closes early may reset the write; the reply is what tests assert on.
            let _ = wr.write_all(&data).await;
            let _ = wr.shutdown().await;
        });
        let mut got = Vec::new();
        tokio::time::timeout(DEADLINE, rd.read_to_end(&mut got))
            .await
            .expect("proxy did not close the client stream")
            .unwrap();
        writer.await.unwrap();
        got
    }

    /// Returns every event emitted so far.
    pub fn drain(rx: &mut UnboundedReceiver<Record>) -> Vec<Event> {
        std::iter::from_fn(|| rx.try_recv().ok())
            .map(|r| r.event)
            .collect()
    }

    /// Builds `len` deterministic bytes that cover every byte value.
    pub fn payload(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 31 + 7) as u8).collect()
    }

    /// Builds a PROXY v2 TCP4 header `10.0.0.1:40000 -> 10.0.0.2:15432` with TLV `0xE0` = `IDENTITY`.
    pub fn pp_header() -> Vec<u8> {
        Self::pp_header_to(15432, IDENTITY)
    }

    /// Builds a PROXY v2 TCP4 header `10.0.0.1:40000 -> 10.0.0.2:<dst_port>` with TLV `0xE0` = `identity`.
    pub fn pp_header_to(dst_port: u16, identity: &str) -> Vec<u8> {
        let mut block = vec![10, 0, 0, 1, 10, 0, 0, 2];
        block.extend_from_slice(&40000u16.to_be_bytes());
        block.extend_from_slice(&dst_port.to_be_bytes());
        block.push(Tlv::IDENTITY);
        block.extend_from_slice(&(identity.len() as u16).to_be_bytes());
        block.extend_from_slice(identity.as_bytes());

        let mut header = b"\r\n\r\n\0\r\nQUIT\n".to_vec();
        header.extend_from_slice(&[0x21, 0x11]);
        header.extend_from_slice(&(block.len() as u16).to_be_bytes());
        header.extend_from_slice(&block);
        header
    }

    /// Sums `Chunk` lengths in direction `dir`.
    pub fn chunk_total(events: &[Event], dir: FlowDirection) -> usize {
        events
            .iter()
            .map(|e| match e {
                Event::Chunk { dir: d, len, .. } if *d == dir => *len,
                _ => 0,
            })
            .sum()
    }
}

/// Exit code and stderr of one finished inspector binary run.
pub struct RunOutcome {
    /// Process exit code; `None` if a signal ended it.
    pub code: Option<i32>,
    /// Everything the binary wrote to stderr.
    pub stderr: String,
}

/// The real inspector binary running one `--assert pp_test` check, listening on an ephemeral port.
pub struct Inspector {
    /// The spawned binary; killed if the test panics before it exits.
    child: Child,
    /// Address the binary reported in its `listening on` line.
    addr: SocketAddr,
    /// Collects stderr after the `listening on` line until the binary exits.
    rest: JoinHandle<String>,
    /// Stderr lines read before and including `listening on`.
    head: String,
}

impl Inspector {
    /// Prefix of the stderr line that reports the bound address.
    const LISTENING: &str = "listening on ";

    /// Builds a command for the binary under test with `args`, stdout discarded and stderr piped.
    fn command(args: &[&str]) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_l4_proto_inspector"));
        cmd.args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        cmd
    }

    /// Runs the binary with `args` to exit; for setups that must fail before listening.
    pub async fn run_to_exit(args: &[&str]) -> RunOutcome {
        let out = tokio::time::timeout(DEADLINE, Self::command(args).output())
            .await
            .expect("binary did not exit")
            .unwrap();
        RunOutcome {
            code: out.status.code(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }

    /// Spawns `--mode pp --mode raw --assert pp_test --pp-identity IDENTITY` in front of a fresh echo
    /// backend, and waits until it reports its bound address.
    pub async fn start_pp_test() -> Self {
        let upstream = Harness::echo_backend().await.to_string();
        let mut child = Self::command(&[
            "--listen",
            "127.0.0.1:0",
            "--upstream",
            &upstream,
            "--mode",
            "pp",
            "--mode",
            "raw",
            "--assert",
            "pp_test",
            "--pp-identity",
            IDENTITY,
        ])
        .spawn()
        .unwrap();
        let mut lines = BufReader::new(child.stderr.take().unwrap()).lines();

        // Read stderr until the bound address appears; port 0 means only the binary knows it.
        let mut head = String::new();
        let addr = loop {
            let line = tokio::time::timeout(DEADLINE, lines.next_line())
                .await
                .expect("binary did not report its address")
                .unwrap()
                .unwrap_or_else(|| panic!("binary exited before listening; stderr:\n{head}"));
            head.push_str(&line);
            head.push('\n');
            if let Some(addr) = line.strip_prefix(Self::LISTENING) {
                break addr.parse().unwrap();
            }
        };

        // Drain the rest concurrently so a full pipe cannot block the binary.
        let rest = tokio::spawn(Self::read_rest(lines));
        Self {
            child,
            addr,
            rest,
            head,
        }
    }

    /// Reads the remaining stderr lines until EOF.
    async fn read_rest(mut lines: Lines<BufReader<ChildStderr>>) -> String {
        let mut out = String::new();
        while let Ok(Some(line)) = lines.next_line().await {
            out.push_str(&line);
            out.push('\n');
        }
        out
    }

    /// Address the binary listens on.
    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    /// Waits for the binary to exit and returns its exit code and full stderr.
    pub async fn finish(mut self) -> RunOutcome {
        let status = tokio::time::timeout(DEADLINE, self.child.wait())
            .await
            .expect("binary did not exit after its connection closed")
            .unwrap();
        let rest = self.rest.await.unwrap();
        RunOutcome {
            code: status.code(),
            stderr: self.head + &rest,
        }
    }
}
