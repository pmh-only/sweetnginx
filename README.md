# sweetnginx

nginx container image with some sugars for my homelab server

## Components

| Component | Version |
|-----------|---------|
| nginx | 1.31.5 |
| headers-more-nginx-module | v0.40 |
| ModSecurity | v3.0.16 |
| ModSecurity-nginx connector | v1.0.4 |
| OWASP Core Rule Set | v4.29.0 |
| ECH OpenSSL (defo-project) | 3.9.0-ech |

## Nginx modules

### Built-in (static)

| Module | Description |
|--------|-------------|
| `http_ssl_module` | HTTPS support |
| `http_v2_module` | HTTP/2 |
| `http_v3_module` | HTTP/3 / QUIC |
| `http_addition_module` | Append/prepend response bodies |
| `http_auth_request_module` | Subrequest-based authentication |
| `http_dav_module` | WebDAV |
| `http_flv_module` | FLV streaming |
| `http_gunzip_module` | Decompress gzip responses for clients that don't support it |
| `http_gzip_static_module` | Serve pre-compressed `.gz` files |
| `http_mp4_module` | MP4 streaming with seek support |
| `http_random_index_module` | Random directory index |
| `http_realip_module` | Replace client IP from trusted proxy headers |
| `http_secure_link_module` | Token-protected URLs |
| `http_slice_module` | Byte-range cache slicing |
| `http_stub_status_module` | Basic status page |
| `http_sub_module` | Response body substitution |
| `stream` | TCP/UDP proxy |
| `stream_ssl_module` | TLS for stream proxy |
| `stream_ssl_preread_module` | SNI/ALPN inspection without termination |
| `mail` | Mail proxy |
| `mail_ssl_module` | TLS for mail proxy |
| `threads` | Thread pool support |
| `pcre-jit` | JIT-compiled regex |
| `headers-more-nginx-module` | Arbitrary add/set/clear of request and response headers |

### Dynamic

| Module | Description |
|--------|-------------|
| `ngx_http_modsecurity_module` | ModSecurity WAF ← added by this image |
| `ngx_http_brotli_filter_module` | Dynamic Brotli compression ← added by this image |
| `ngx_http_brotli_static_module` | Serve pre-compressed `.br` files ← added by this image |
| `ngx_http_zstd_filter_module` | Dynamic Zstd compression ← added by this image |
| `ngx_http_zstd_static_module` | Serve pre-compressed `.zst` files ← added by this image |

## ECH (Encrypted Client Hello)

ECH encrypts the TLS ClientHello so the SNI (server name) of the real backend is not visible to on-path observers.  Only the outer `public_name` (e.g. a CDN hostname) is transmitted in plaintext.

See [APPLY_ECH.md](APPLY_ECH.md) for key generation, DNS publishing, verification, and key rotation.

### Implementation notes

ECH is supported natively by nginx 1.29.4 via the `ssl_ech_file` directive, using the defo-project OpenSSL ECH feature branch as the TLS backend.  TLS and QUIC (HTTP/3) server blocks may share a single `server { }` block; nginx applies the ECH store to each SSL_CTX at configuration time.  A patch to defo-project OpenSSL (`patches/openssl-ech-quic-fix.patch`) guards `ossl_ech_early_decrypt` against QUIC packet-format differences, preventing crashes on QUIC connections when the ECH store is active.

## Version updates

A GitHub Actions workflow runs every Monday and opens a pull request if any component has a new version available. On merge to `main`, the image is built for `linux/amd64` and `linux/arm64` and pushed to GHCR.
