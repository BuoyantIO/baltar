use std::process::ExitCode;
use std::time::Instant;

use clap::Parser;
use l4_proto_inspector::core::Mode;
use l4_proto_inspector::shell::{LogSink, Proxy};
use tokio::sync::mpsc;

/// Command-line flags.
#[derive(Parser)]
#[command(
    name = "l4_proto_inspector",
    version,
    about = "L4 middle proxy that logs what it sees"
)]
struct Cli {
    /// Address to accept clients on, e.g. 0.0.0.0:15432.
    #[arg(long)]
    listen: String,
    /// Address of the app to forward to, e.g. 127.0.0.1:9000.
    #[arg(long)]
    upstream: String,
    /// Inspector to run on client-to-app bytes; repeat to chain them in order.
    #[arg(long = "mode", value_name = "raw|pp", default_value = "raw")]
    modes: Vec<Mode>,
}

#[tokio::main]
async fn main() -> ExitCode {
    let start = Instant::now();
    let cli = Cli::parse();
    let (tx, mut rx) = mpsc::unbounded_channel();

    let proxy = match Proxy::bind(
        &cli.listen,
        cli.upstream,
        cli.modes,
        LogSink::new(tx, start),
    )
    .await
    {
        Ok(p) => p,
        Err(_) => return ExitCode::FAILURE,
    };
    eprintln!("listening on {}", cli.listen);

    tokio::spawn(async move {
        while let Some(record) = rx.recv().await {
            match serde_json::to_string(&record) {
                Ok(line) => println!("{line}"),
                Err(e) => eprintln!("serialize event: {e}"),
            }
        }
    });

    match proxy.run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::FAILURE,
    }
}
