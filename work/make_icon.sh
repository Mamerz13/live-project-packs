#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Resources/volt-app-icon.png"
OUT="$ROOT/outputs"
ICONSET="$OUT/LiveProjectPacks.iconset"

mkdir -p "$ICONSET"
sips -z 1024 1024 "$SOURCE" --out "$OUT/LiveProjectPacks-icon.png" >/dev/null

make_icon() {
  local filename="$1"
  local pixels="$2"
  sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
}

make_icon icon_16x16.png 16
make_icon icon_16x16@2x.png 32
make_icon icon_32x32.png 32
make_icon icon_32x32@2x.png 64
make_icon icon_128x128.png 128
make_icon icon_128x128@2x.png 256
make_icon icon_256x256.png 256
make_icon icon_256x256@2x.png 512
make_icon icon_512x512.png 512
make_icon icon_512x512@2x.png 1024

chunk_size() {
  stat -f '%z' "$1"
}

write_be32() {
  printf '%08x' "$1" | xxd -r -p
}

write_chunk() {
  local code="$1"
  local path="$2"
  printf '%s' "$code"
  write_be32 "$(( $(chunk_size "$path") + 8 ))"
  cat "$path"
}

declare -a chunk_specs=(
  "icp4:$ICONSET/icon_16x16.png"
  "icp5:$ICONSET/icon_32x32.png"
  "icp6:$ICONSET/icon_32x32@2x.png"
  "ic07:$ICONSET/icon_128x128.png"
  "ic08:$ICONSET/icon_256x256.png"
  "ic09:$ICONSET/icon_512x512.png"
  "ic10:$ICONSET/icon_512x512@2x.png"
)

payload_size=0
for spec in "${chunk_specs[@]}"; do
  path="${spec#*:}"
  payload_size="$(( payload_size + $(chunk_size "$path") + 8 ))"
done

{
  printf 'icns'
  write_be32 "$(( payload_size + 8 ))"
  for spec in "${chunk_specs[@]}"; do
    write_chunk "${spec%%:*}" "${spec#*:}"
  done
} > "$OUT/LiveProjectPacks.icns"
