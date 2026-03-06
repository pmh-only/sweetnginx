# sweetnginx

nginx container image with some sugars for my homelab server

## Components

| Component | Version |
|-----------|---------|
| OpenResty | 1.27.1.2 |
| ModSecurity | v3.0.14 |
| ModSecurity-nginx connector | v1.0.4 |
| OWASP Core Rule Set | v4.24.0 |

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

### Dynamic

| Module | Description |
|--------|-------------|
| `http_geoip_module` | GeoIP-based routing (MaxMind legacy) |
| `http_image_filter_module` | On-the-fly image resizing/cropping |
| `http_xslt_module` | XSLT response transformation |
| `ngx_http_modsecurity_module` | ModSecurity WAF ← added by this image |
| `ngx_http_brotli_filter_module` | Dynamic Brotli compression ← added by this image |
| `ngx_http_brotli_static_module` | Serve pre-compressed `.br` files ← added by this image |
| `ngx_http_zstd_filter_module` | Dynamic Zstd compression ← added by this image |
| `ngx_http_zstd_static_module` | Serve pre-compressed `.zst` files ← added by this image |

### OpenResty additions (static)

| Module | Description |
|--------|-------------|
| `ngx_devel_kit` | Module development kit (NDK) |
| `echo-nginx-module` | `echo`, `echo_exec`, etc. for config scripting |
| `set-misc-nginx-module` | Extra `set_*` directives (MD5, SHA1, base64, escaping…) |
| `headers-more-nginx-module` | Arbitrary add/set/clear of request and response headers |
| `ngx_lua` | Lua scripting via LuaJIT |
| `ngx_lua_upstream` | Upstream manipulation from Lua |
| `ngx_stream_lua` | Lua scripting in stream (TCP/UDP) context |
| `srcache-nginx-module` | Transparent subrequest-based caching |
| `memc-nginx-module` | Memcached upstream with extended commands |
| `redis2-nginx-module` | Redis 2.x upstream |
| `redis-nginx-module` | Redis upstream |
| `form-input-nginx-module` | Parse `application/x-www-form-urlencoded` POST bodies |
| `array-var-nginx-module` | Array variables in nginx config |
| `encrypted-session-nginx-module` | Encrypt/decrypt nginx variables |
| `xss-nginx-module` | Native JSONP/cross-site support |
| `ngx_coolkit` | Small utility directives |

## Version updates

A GitHub Actions workflow runs every Monday and opens a pull request if any component has a new version available. On merge to `main`, the image is built for `linux/amd64` and `linux/arm64` and pushed to GHCR.
