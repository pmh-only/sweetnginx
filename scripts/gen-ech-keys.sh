#!/usr/bin/env sh
# Generate an ECH (Encrypted Client Hello) key pair for nginx.
#
# Usage: gen-ech-keys <public_name> [output_dir]
#
#   public_name   Plaintext outer SNI advertised in cleartext
#                 (e.g. "public.example.com")
#   output_dir    Directory to write the key file  [/etc/nginx/ech]
#
# The output PEM file (server.ech.pem) contains both the ECHConfig and the
# private key.  After generating keys:
#
#   1. Mount the output directory into the container at /etc/nginx/ech
#   2. Reload nginx:  nginx -s reload
#   3. Publish the ECHConfigList in DNS via an HTTPS RR "ech=" parameter.
#      Run this script with the same key file to print the base64 value:
#
#        openssl-ech ech -in /etc/nginx/ech/server.ech.pem -text
#
# Keys should be rotated regularly (e.g. weekly).  Generate a new pair,
# update DNS, then reload nginx.  Old keys can be removed once DNS TTL
# has expired.
set -eu

PUBLIC_NAME="${1:?Usage: gen-ech-keys <public_name> [output_dir]}"
OUT_DIR="${2:-/etc/nginx/ech}"

mkdir -p "$OUT_DIR"

openssl-ech ech -public_name "$PUBLIC_NAME" -out "$OUT_DIR/server.ech.pem"

echo "ECH key written to: $OUT_DIR/server.ech.pem"
echo ""
echo "ECHConfigList (for DNS HTTPS RR 'ech=' parameter):"
openssl-ech ech -in "$OUT_DIR/server.ech.pem" -text 2>/dev/null || true
