#!/bin/sh
set -eu
plugin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname "$plugin_dir")
out_dir="$project_dir/dist/plugin"
mkdir -p "$out_dir"
# Supply ZIG=/path/to/zig, or use the locally downloaded official toolchain.
zig_bin=${ZIG:-"$plugin_dir/.tools/zig-aarch64-macos-0.15.2/zig"}
if [ ! -x "$zig_bin" ]; then
  echo 'Zig not found. Set ZIG to an official Zig 0.15.2 executable.' >&2
  exit 1
fi
"$zig_bin" cc -target wasm32-freestanding -mbulk-memory -O2 -std=c11 -nostdlib -fno-builtin \
  -Wl,--no-entry -Wl,--export-memory -Wl,--export=pc_abi_version \
  -Wl,--export=pc_manifest -Wl,--export=pc_alloc -Wl,--export=pc_filter \
  -Wl,--initial-memory=2097152 -Wl,--max-memory=536870912 \
  "$plugin_dir/filmdust.c" -o "$out_dir/film-dust-local.wasm.tmp"
mv "$out_dir/film-dust-local.wasm.tmp" "$out_dir/film-dust-local.wasm"
echo "$out_dir/film-dust-local.wasm"
