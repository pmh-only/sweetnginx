#!/usr/bin/env sh
set -eu

PUBLIC_NAME="${1:?Usage: gen-ech-keys <public_name> [output_dir]}"
OUT_DIR="${2:-/etc/nginx/ech}"

mkdir -p "$OUT_DIR"

openssl-ech ech -public_name "$PUBLIC_NAME" -out "$OUT_DIR/server.ech.pem"

echo "ECH key written to: $OUT_DIR/server.ech.pem"
echo ""
echo "ECHConfigList (for DNS HTTPS RR 'ech=' parameter):"
openssl-ech ech -in "$OUT_DIR/server.ech.pem"
openssl-ech ech -in "$OUT_DIR/server.ech.pem" -text
