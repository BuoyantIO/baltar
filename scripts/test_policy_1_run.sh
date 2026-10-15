#!/usr/bin/env bash
# Run from the launchy-dev repo root.
# Usage: ./scripts/test_policy_1_run.sh
#        TEST_FILTER=rejects_duplicate_mtls_authns ./scripts/test_policy_1_run.sh
#        TEST_BINARY=e2e_server_authorization CONTEXT=kind-other ./scripts/test_policy_1_run.sh
#
# Runs one linkerd2 policy test binary once via `just policy-test-run`, with retries off and output uncaptured.
# Exits with the test's status. Needs cargo-nextest: plain `cargo test` rejects `--no-capture` before `--`.
# The recipe word-splits its extra flags, so TEST_FILTER must not contain spaces.
#
# Env vars and defaults:
#   LINKERD2_DIR=../linkerd2                           linkerd2 checkout to run the recipe in
#   CONTEXT=kind-kind                                  kubectl context, passed to the tests as POLICY_TEST_CONTEXT
#   TEST_BINARY=admit_authorization_policy             test binary in linkerd2 policy-test/tests
#   TEST_FILTER=                                       test name filter; empty runs every test in the binary
#   RUST_LOG=trace,kube=debug,hyper=info,h2=info       test tracing filter
set -euo pipefail

# Applies env defaults.
LINKERD2_DIR=${LINKERD2_DIR:-../linkerd2}
CONTEXT=${CONTEXT:-kind-kind}
TEST_BINARY=${TEST_BINARY:-admit_authorization_policy}
TEST_FILTER=${TEST_FILTER:-}
RUST_LOG=${RUST_LOG:-trace,kube=debug,hyper=info,h2=info}

# Builds the recipe flags; an empty filter is left out so nextest runs the whole binary.
flags=(--test "$TEST_BINARY" --no-capture)
if [ -n "$TEST_FILTER" ]; then
  flags+=("$TEST_FILTER")
fi

# Runs the test once; NEXTEST_RETRIES=0 overrides any configured retries so a failure surfaces.
echo "[-] $TEST_BINARY ${TEST_FILTER:-(all)} on $CONTEXT"
cd "$LINKERD2_DIR"
export NEXTEST_RETRIES=0 POLICY_TEST_CONTEXT=$CONTEXT RUST_LOG
exec just policy-test-run "${flags[@]}"
