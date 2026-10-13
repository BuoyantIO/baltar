# Builds l4_proto_inspector inside the image, so the same build works on the Mac and the VM; used by scripts/inspector_1_build_image.sh.
# The build stage needs Rust 1.85+ for edition 2024; the runtime shares bookworm's glibc with the build stage.
FROM rust:1-bookworm AS build
WORKDIR /src

# Compiles dependencies against a stub main first, so source edits reuse the cached dependency layer.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs && cargo build --release --locked && rm -rf src

# Compiles the real crate; touch makes cargo rebuild over the stub's fingerprint.
COPY src ./src
RUN touch src/main.rs src/lib.rs && cargo build --release --locked

FROM debian:bookworm-slim
COPY --from=build /src/target/release/l4_proto_inspector /usr/local/bin/l4_proto_inspector
ENTRYPOINT ["/usr/local/bin/l4_proto_inspector"]
