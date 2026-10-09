#!/bin/bash
# Runs INSIDE the lima VM (Debian 13 arm64, glibc 2.41 — the same as Steam Linux
# Runtime 4): build xrizer, the OpenVR-over-OpenXR runtime, as an aarch64 Linux
# vrclient.so. The source and target dir stay on the VM's own disk; only the
# finished runtime directory is copied to the shared folder.
set -euo pipefail
OUT="$(cd "$(dirname "$0")" && pwd)"
# A fresh VM is still running its own first-boot package setup.
sudo cloud-init status --wait >/dev/null 2>&1 || true
sudo apt-get -o DPkg::Lock::Timeout=600 update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq build-essential git curl pkg-config cmake \
     clang libclang-dev glslang-tools glslc libvulkan-dev libxkbcommon-dev libwayland-dev libx11-dev \
     libxi-dev libgl-dev libegl-dev libasound2-dev >/dev/null
if ! command -v cargo >/dev/null; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null
fi
. "$HOME/.cargo/env"
cd "$HOME"
[ -d xrizer ] || git clone -q https://github.com/Supreeeme/xrizer.git
cd xrizer
# Pinned, because the patch below is written against this source. The tree is
# reset first so a second run starts from the same place as the first.
git fetch -q && git checkout -q -f "${XRIZER_REV:-0989a7fac2d1efb7ea82f5fe1a8ed30c3eeb9596}"
git checkout -q -- .
git rev-parse HEAD > "$OUT/xrizer.rev"
# Real frame timing instead of constants — what lets the game's own automatic
# quality level work. See the script's header.
python3 "$OUT/xrizer-frame-timing.py"
# The game's loading-screen messages, handed to the host instead of dropped.
python3 "$OUT/xrizer-interstitials.py"
cargo xbuild --release 2>&1 | tail -25
rm -rf "$OUT/xrizer"
mkdir -p "$OUT/xrizer/bin/linuxarm64"
cp target/release/libxrizer.so "$OUT/xrizer/bin/linuxarm64/vrclient.so"
ls -la target/release/bin 2>/dev/null || true
ls -la "$OUT/xrizer/bin/linuxarm64"
echo "xrizer $(cat "$OUT/xrizer.rev") built"
