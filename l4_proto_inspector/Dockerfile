# Runs the inspector beside linkerd-proxy in kind; the binary is built on the VM by scripts/app/inspector_1_build_image.sh.
# ubuntu:24.04 matches the VM's glibc 2.39, so no Rust toolchain is needed in the image.
FROM ubuntu:24.04
COPY target/release/l4_proto_inspector /usr/local/bin/l4_proto_inspector
ENTRYPOINT ["/usr/local/bin/l4_proto_inspector"]
