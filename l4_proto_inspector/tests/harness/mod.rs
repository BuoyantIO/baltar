use std::net::SocketAddr;
use std::time::{Duration, Instant};

use l4_proto_inspector::core::{Event, FlowDirection, Mode, Tlv};
use l4_proto_inspector::shell::{LogSink, Proxy, Record};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::{self, UnboundedReceiver};

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
        let mut block = vec![10, 0, 0, 1, 10, 0, 0, 2];
        block.extend_from_slice(&40000u16.to_be_bytes());
        block.extend_from_slice(&15432u16.to_be_bytes());
        block.push(Tlv::IDENTITY);
        block.extend_from_slice(&(IDENTITY.len() as u16).to_be_bytes());
        block.extend_from_slice(IDENTITY.as_bytes());

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
