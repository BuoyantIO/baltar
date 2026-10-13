mod harness;

use harness::{Harness, IDENTITY, Inspector};
use l4_proto_inspector::core::{Event, FlowDirection, Mode, Tlv};
use l4_proto_inspector::error::PpError;
use l4_proto_inspector::util::Hex;

/// `raw` forwards 1 MiB byte-exact to the app and back, logging every byte in both directions.
///
/// Setup: `--mode raw` proxy in front of an echo backend; the client sends 1 MiB and half-closes.
/// Catches: dropped, reordered or duplicated bytes in either copy loop, or chunks missing from the log.
#[tokio::test]
async fn raw_round_trips_one_mib() {
    // Send 1 MiB through proxy and echo; the reply crosses both directions of the proxy.
    let (addr, mut rx) = Harness::proxy(vec![Mode::Raw]).await;
    let sent = Harness::payload(1 << 20);
    let got = Harness::round_trip(addr, sent.clone()).await;
    assert!(
        got == sent,
        "reply differs: {} of {} bytes",
        got.len(),
        sent.len()
    );

    // Chunk events account for every byte in each direction and nothing closed the stream.
    let events = Harness::drain(&mut rx);
    assert_eq!(
        Harness::chunk_total(&events, FlowDirection::Request),
        sent.len()
    );
    assert_eq!(
        Harness::chunk_total(&events, FlowDirection::Response),
        sent.len()
    );
    assert!(!events.iter().any(|e| matches!(e, Event::Closed { .. })));
}

/// `pp` then `raw` strips the header, forwards only the payload, and logs identity and full header hex.
///
/// Setup: `--mode pp --mode raw` proxy; the client sends a PROXY v2 header with TLV `0xE0`, then `hello\n`.
/// Catches: header bytes leaking to the app, a lost identity TLV, or a truncated `raw_hex`.
#[tokio::test]
async fn pp_strips_header_and_logs_identity() {
    // Send header plus payload; the echo returns exactly what the app received.
    let (addr, mut rx) = Harness::proxy(vec![Mode::Pp, Mode::Raw]).await;
    let header = Harness::pp_header();
    let payload = b"hello\n".to_vec();
    let got = Harness::round_trip(addr, [header.clone(), payload.clone()].concat()).await;
    assert_eq!(got, payload);

    // The first event is the parsed header with the whole header as hex and the identity as text.
    let events = Harness::drain(&mut rx);
    match &events[0] {
        Event::PpHeader {
            raw_hex,
            src,
            dst,
            tlvs,
            ..
        } => {
            assert_eq!(*raw_hex, Hex::encode(&header));
            assert_eq!(src, "10.0.0.1:40000");
            assert_eq!(dst, "10.0.0.2:15432");
            assert_eq!(*tlvs, vec![Tlv::new(Tlv::IDENTITY, IDENTITY.as_bytes())]);
        }
        other => panic!("expected PpHeader first, got {other:?}"),
    }

    // `raw` saw only the payload, never header bytes.
    assert!(events.contains(&Event::chunk(FlowDirection::Request, &payload)));
    assert_eq!(
        Harness::chunk_total(&events, FlowDirection::Request),
        payload.len()
    );
}

/// `pp` closes a client that sends no PROXY v2 header and logs the reason.
///
/// Setup: `--mode pp --mode raw` proxy; the client sends a plain HTTP request line.
/// Catches: unheadered bytes reaching the app, or a close with no `Closed` event explaining it.
#[tokio::test]
async fn pp_without_header_closes() {
    // Send a request without a header; the proxy must close with no bytes echoed back.
    let (addr, mut rx) = Harness::proxy(vec![Mode::Pp, Mode::Raw]).await;
    let got = Harness::round_trip(addr, b"GET / HTTP/1.0\r\n\r\n".to_vec()).await;
    assert!(got.is_empty(), "app bytes reached the client: {got:?}");

    // The only event is the close, carrying the signature error as its reason.
    let events = Harness::drain(&mut rx);
    assert_eq!(
        events,
        vec![Event::Closed {
            reason: PpError::BadSignature.to_string()
        }]
    );
}

/// The binary exits 0 when the PROXY v2 header carries the expected identity and the bound port.
///
/// Setup: real binary with `--assert pp_test`; the client sends a matching header, `hello\n`, and half-closes.
/// Catches: a correct header judged as failing, a run that never ends, or payload not reaching the app.
#[tokio::test]
async fn assert_right_identity_exits_0() {
    // Send a header aimed at the bound port with the expected identity; the echo proves forwarding.
    let run = Inspector::start_pp_test().await;
    let header = Harness::pp_header_to(run.addr().port(), IDENTITY);
    let got = Harness::round_trip(run.addr(), [header, b"hello\n".to_vec()].concat()).await;
    assert_eq!(got, b"hello\n");

    // The run ends with the connection, passing every field.
    let out = run.finish().await;
    assert_eq!(out.code, Some(0), "stderr:\n{}", out.stderr);
    assert!(
        out.stderr.contains("verdict: PASS"),
        "stderr:\n{}",
        out.stderr
    );
}

/// The binary exits 1 on a wrong identity, and stderr names the field, expected and observed values.
///
/// Setup: real binary expecting `IDENTITY`; the client sends a header whose TLV `0xE0` is `wrong.identity`.
/// Catches: an identity mismatch that passes, or a failure line that hides what differed.
#[tokio::test]
async fn assert_wrong_identity_exits_1() {
    // Send a header that is right in every field except the identity.
    let run = Inspector::start_pp_test().await;
    let header = Harness::pp_header_to(run.addr().port(), "wrong.identity");
    Harness::round_trip(run.addr(), [header, b"hello\n".to_vec()].concat()).await;

    // The failing line names the TLV, the expected identity and the one observed.
    let out = run.finish().await;
    assert_eq!(out.code, Some(1), "stderr:\n{}", out.stderr);
    let line =
        format!(r#"FAIL pp_test tlv 0xe0: expected "{IDENTITY}", observed "wrong.identity""#);
    assert!(out.stderr.contains(&line), "stderr:\n{}", out.stderr);
}

/// The binary exits 1 when the client sends no PROXY v2 header at all.
///
/// Setup: real binary with `--assert pp_test`; the client sends a plain HTTP request line.
/// Catches: a proxy that omits the header being judged as passing.
#[tokio::test]
async fn assert_missing_header_exits_1() {
    // Send unheadered bytes; `pp` closes the connection, which ends the run.
    let run = Inspector::start_pp_test().await;
    Harness::round_trip(run.addr(), b"GET / HTTP/1.0\r\n\r\n".to_vec()).await;

    // The failure names the missing header.
    let out = run.finish().await;
    assert_eq!(out.code, Some(1), "stderr:\n{}", out.stderr);
    assert!(
        out.stderr.contains("FAIL pp_test pp header"),
        "stderr:\n{}",
        out.stderr
    );
}

/// The binary exits 2 for an unknown assertion name, before listening.
///
/// Setup: real binary with `--assert nope`.
/// Catches: a typo in `--assert` running unchecked or reported as a test failure (1) instead of a setup error.
#[tokio::test]
async fn assert_unknown_name_exits_2() {
    // Run to exit; no client is needed since setup must fail first.
    let out = Inspector::run_to_exit(&[
        "--listen",
        "127.0.0.1:0",
        "--upstream",
        "127.0.0.1:9",
        "--mode",
        "pp",
        "--assert",
        "nope",
    ])
    .await;
    assert_eq!(out.code, Some(2), "stderr:\n{}", out.stderr);
    assert!(
        !out.stderr.contains("listening on"),
        "stderr:\n{}",
        out.stderr
    );
}

/// The binary exits 2 when `pp_test` is asked for without `--mode pp`.
///
/// Setup: real binary with `--assert pp_test --pp-identity` and only the default `raw` mode.
/// Catches: a run that can never see a header starting anyway and failing as if the proxy were wrong.
#[tokio::test]
async fn assert_pp_test_without_pp_mode_exits_2() {
    // Run to exit; the plan check must reject the flags before binding.
    let out = Inspector::run_to_exit(&[
        "--listen",
        "127.0.0.1:0",
        "--upstream",
        "127.0.0.1:9",
        "--assert",
        "pp_test",
        "--pp-identity",
        IDENTITY,
    ])
    .await;
    assert_eq!(out.code, Some(2), "stderr:\n{}", out.stderr);
    assert!(
        out.stderr.contains("--assert pp_test needs --mode pp"),
        "stderr:\n{}",
        out.stderr
    );
}
