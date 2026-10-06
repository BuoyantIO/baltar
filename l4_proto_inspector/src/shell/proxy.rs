use std::io;
use std::net::SocketAddr;
use std::pin::pin;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};

use super::LogSink;
use crate::core::{Chain, Event, FlowDirection, Mode, Verdict};
use crate::error::InspectorError;

/// Read buffer size per direction per connection.
const BUF_LEN: usize = 16 * 1024;

/// Accepts clients, dials the upstream per client, and copies both ways through a `Chain`.
pub struct Proxy {
    /// Socket clients connect to.
    listener: TcpListener,
    /// `host:port` dialed once per accepted client.
    upstream: String,
    /// Inspector order; each connection gets a fresh `Chain` built from it.
    modes: Vec<Mode>,
    /// Shared event log; cloned into every connection.
    sink: LogSink,
}

/// How the client-to-app direction ended.
#[derive(Debug, PartialEq, Eq)]
enum Flow {
    Eof,
    Closed,
}

/// One accepted client and everything its two copy loops share.
struct Conn {
    id: u64,
    sink: LogSink,
}

impl Proxy {
    /// Binds `listen`; on failure writes `bind {listen}: {os reason}` to stderr and returns `Bind`.
    pub async fn bind(
        listen: &str,
        upstream: String,
        modes: Vec<Mode>,
        sink: LogSink,
    ) -> Result<Self, InspectorError> {
        Ok(Self {
            listener: TcpListener::bind(listen).await.map_err(|e| {
                eprintln!("bind {listen}: {e}");
                InspectorError::Bind
            })?,
            upstream,
            modes,
            sink,
        })
    }

    /// Returns the bound address; on failure writes the OS reason to stderr and returns `Bind`.
    pub fn local_addr(&self) -> Result<SocketAddr, InspectorError> {
        self.listener.local_addr().map_err(|e| {
            eprintln!("local_addr: {e}");
            InspectorError::Bind
        })
    }

    /// Serves clients until accept fails; then writes `accept: {os reason}` to stderr and returns `Accept`.
    pub async fn run(self) -> Result<(), InspectorError> {
        let mut next_id = 0u64;
        loop {
            let (client, peer) = self.listener.accept().await.map_err(|e| {
                eprintln!("accept: {e}");
                InspectorError::Accept
            })?;
            next_id += 1;
            let conn = Conn {
                id: next_id,
                sink: self.sink.clone(),
            };
            let upstream = self.upstream.clone();
            let chain = Chain::new(&self.modes);
            tokio::spawn(async move {
                if let Err(e) = conn.serve(client, &upstream, chain).await {
                    eprintln!("conn {} from {peer}: {e}", conn.id);
                }
            });
        }
    }
}

impl Conn {
    async fn serve(&self, client: TcpStream, upstream: &str, chain: Chain) -> io::Result<()> {
        // Dial the app per client and split both sockets so each direction runs its own loop.
        let upstream = TcpStream::connect(upstream).await?;
        let (client_rd, client_wr) = client.into_split();
        let (up_rd, up_wr) = upstream.into_split();
        let mut request = pin!(self.request(client_rd, up_wr, chain));
        let mut response = pin!(self.response(up_rd, client_wr));

        // A `Close` returns at once so both sockets drop; otherwise wait for the other direction.
        tokio::select! {
            flow = &mut request => {
                if flow? == Flow::Eof {
                    response.await?;
                }
            }
            done = &mut response => {
                done?;
                request.await?;
            }
        }
        Ok(())
    }

    async fn request(
        &self,
        mut rd: OwnedReadHalf,
        mut wr: OwnedWriteHalf,
        mut chain: Chain,
    ) -> io::Result<Flow> {
        let mut buf = vec![0u8; BUF_LEN];
        loop {
            // Run every read, including EOF, through the chain so inspectors can flush or reject.
            let n = rd.read(&mut buf).await?;
            let out = if n == 0 {
                chain.eof()
            } else {
                chain.feed(&buf[..n])
            };

            // Log before acting on the verdict so a `Close` still records why it closed.
            self.sink.emit(self.id, out.events);
            if let Verdict::Close(_) = out.verdict {
                return Ok(Flow::Closed);
            }

            // Forward only what the chain released; on EOF half-close so the app sees end of request.
            wr.write_all(&out.forward).await?;
            if n == 0 {
                wr.shutdown().await?;
                return Ok(Flow::Eof);
            }
        }
    }

    async fn response(&self, mut rd: OwnedReadHalf, mut wr: OwnedWriteHalf) -> io::Result<()> {
        let mut buf = vec![0u8; BUF_LEN];
        loop {
            // App EOF: half-close the client side and finish this direction.
            let n = rd.read(&mut buf).await?;
            if n == 0 {
                wr.shutdown().await?;
                return Ok(());
            }

            // Responses bypass the chain: log the raw chunk and pass it through unchanged.
            self.sink
                .emit(self.id, [Event::chunk(FlowDirection::Response, &buf[..n])]);
            wr.write_all(&buf[..n]).await?;
        }
    }
}
