use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::pin::pin;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};

use super::LogSink;
use crate::core::assert::{AssertPlan, Assertions, Report};
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
    /// The client half-closed and the chain let the stream through.
    Eof,
    /// The chain or an assertion closed the connection.
    Closed,
}

/// One accepted client and everything its two copy loops share.
struct Conn {
    /// Connection id, starting at 1 in accept order.
    id: u64,
    /// Where this connection's events go.
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
            // Plain runs check nothing, so a failure only ends this one connection.
            tokio::spawn(async move {
                let mut asserts = Assertions::new(Vec::new());
                let _ = conn
                    .serve(client, peer, &upstream, chain, &mut asserts)
                    .await;
            });
        }
    }

    /// Checks exactly one client with `plan`'s plugins and returns their report.
    ///
    /// The run ends when that connection closes or `stop` resolves; later clients are closed at once,
    /// since the verdict covers only the first. A stop before any client yields a failing report.
    /// Returns `Dial` if the app is unreachable: that is a setup error, not an assertion failure.
    pub async fn run_once(
        self,
        plan: &AssertPlan,
        stop: impl Future<Output = ()>,
    ) -> Result<Report, InspectorError> {
        // Plugins compare against the bound port, which differs from `--listen` for port 0.
        let mut asserts = plan.build_assertions(self.local_addr()?.port());
        let mut stop = pin!(stop);

        // Wait for the one client; a stop first means nothing was checked.
        let (client, peer) = tokio::select! {
            accepted = self.listener.accept() => accepted.map_err(|e| {
                eprintln!("accept: {e}");
                InspectorError::Accept
            })?,
            () = &mut stop => return Ok(plan.report_no_connection()),
        };

        // Serve it while refusing others; a stop drops the copy loops and keeps what was observed.
        let conn = Conn {
            id: 1,
            sink: self.sink.clone(),
        };
        let chain = Chain::new(&self.modes);
        tokio::select! {
            served = conn.serve(client, peer, &self.upstream, chain, &mut asserts) => {
                // An unreachable app is a setup error; a broken copy still ends in a verdict.
                if served == Err(InspectorError::Dial) {
                    return Err(InspectorError::Dial);
                }
            }
            () = &mut stop => {}
            () = self.refuse_rest() => {}
        }
        Ok(asserts.close())
    }

    /// Closes every further client at once; never returns while the listener works.
    async fn refuse_rest(&self) {
        loop {
            match self.listener.accept().await {
                // Dropping the socket closes it; the run's verdict covers only the first client.
                Ok((_, peer)) => eprintln!("refused {peer}: this run checks only its first client"),
                // A broken listener cannot hurt the connection already accepted, so keep it running.
                Err(e) => {
                    eprintln!("accept: {e}");
                    std::future::pending::<()>().await;
                }
            }
        }
    }
}

impl Conn {
    /// Runs one client through `chain` and `asserts` until both directions end or one side closes.
    ///
    /// Writes the OS reason to stderr and returns `Dial` if the app is unreachable, `Relay` if copying fails.
    async fn serve(
        &self,
        client: TcpStream,
        peer: SocketAddr,
        upstream: &str,
        chain: Chain,
        asserts: &mut Assertions,
    ) -> Result<(), InspectorError> {
        // A plugin may refuse the connection before any bytes or dial.
        if let Verdict::Close(reason) = asserts.open() {
            self.sink.emit(self.id, [Event::Closed { reason }]);
            return Ok(());
        }

        // Dial the app per client; failing here means the setup is wrong, not the client.
        let upstream = TcpStream::connect(upstream).await.map_err(|e| {
            eprintln!("conn {} from {peer}: dial {upstream}: {e}", self.id);
            InspectorError::Dial
        })?;
        self.relay(client, upstream, chain, asserts)
            .await
            .map_err(|e| {
                eprintln!("conn {} from {peer}: {e}", self.id);
                InspectorError::Relay
            })
    }

    /// Copies both directions until both end, or until the request side closes.
    async fn relay(
        &self,
        client: TcpStream,
        upstream: TcpStream,
        chain: Chain,
        asserts: &mut Assertions,
    ) -> io::Result<()> {
        // Split both sockets so each direction runs its own loop.
        let (client_rd, client_wr) = client.into_split();
        let (up_rd, up_wr) = upstream.into_split();
        let mut request = pin!(self.request(client_rd, up_wr, chain, asserts));
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

    /// Copies client to app through the chain, feeding its events to the assertions.
    async fn request(
        &self,
        mut rd: OwnedReadHalf,
        mut wr: OwnedWriteHalf,
        mut chain: Chain,
        asserts: &mut Assertions,
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

            // Assertions see every event, including a `Closed`, before the chain's verdict ends the loop.
            let mut checked = asserts.observe(&out.events);
            if n == 0 {
                let at_eof = asserts.eof();
                if checked == Verdict::Continue {
                    checked = at_eof;
                }
            }

            // Log before acting on the verdict so a `Close` still records why it closed.
            self.sink.emit(self.id, out.events);
            if let Verdict::Close(_) = out.verdict {
                return Ok(Flow::Closed);
            }
            // An assertion close has no chain event yet, so log its reason here.
            if let Verdict::Close(reason) = checked {
                self.sink.emit(self.id, [Event::Closed { reason }]);
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

    /// Copies app to client unchanged, logging each chunk.
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
