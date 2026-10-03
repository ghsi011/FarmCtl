#!/usr/bin/env bash
# Build official MicroPython Unix without installing system packages.
set -euo pipefail
target=${1:-"$PWD/.tooling/micropython-unix"}
mkdir -p "$target"
target=$(cd "$target" && pwd)
archive="$target/micropython-1.29.0.tar.xz"
source_hash=d925a7c664e79a2bdf3dfcb285ba5e2237041cc35a0bd4ee573b6c5711efeca0
if [[ ! -f "$archive" ]]; then
  curl --fail --location --max-time 120 \
    https://micropython.org/resources/source/micropython-1.29.0.tar.xz -o "$archive"
fi
printf '%s  %s\n' "$source_hash" "$archive" | sha256sum --check --status
tar -xJf "$archive" -C "$target"
make -C "$target/micropython-1.29.0/mpy-cross" -j2
make -C "$target/micropython-1.29.0/ports/unix" -j2 MICROPY_PY_FFI=0
binary="$target/micropython-1.29.0/ports/unix/build-standard/micropython"
"$binary" --version
sha256sum "$binary"
printf 'Interpreter: %s\n' "$binary"
