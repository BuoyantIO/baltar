mod harness;

use harness::{Harness, IDENTITY};
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
